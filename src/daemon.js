// Long-running background process the zsh plugin talks to over a unix
// socket, so suggestions don't pay node's startup cost on every keystroke.
//
// Protocol: one request per line, fields separated by \x1f:
//   id \x1f type \x1f cwd \x1f payload      (newlines in payload sent as \x1e)
// types: q = suggest for payload (text left of cursor), r = record executed
// command, d = record directory change, a = alias list, p = ping,
// v = show/hide the overlay window (payload: sel:visible:aRow:aCol:cRow:cCol:cols:lines:cellW:cellH).
// Reply to q: id \x1f replaceLen \x1f tokenStart \x1f overlay(0/1) \x1f n \x1f (insert \x1f display \x1f desc \x1f kind)*n
//
// The overlay app (overlay/TermSuggest.app) connects to the same socket and
// says "overlay"; it then receives JSON lines and can send back
// {"type":"accept","conn":N,"index":i} when the user clicks a suggestion,
// which is forwarded to that shell as: 0 \x1f accept \x1f i
import { createServer, connect } from "node:net";
import { unlinkSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { Engine } from "./engine.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const socketPath = process.argv[2];
if (!socketPath) {
  console.error("usage: daemon.js <socket-path>");
  process.exit(1);
}

const dataDir = process.env.XDG_DATA_HOME
  ? join(process.env.XDG_DATA_HOME, "termsuggest")
  : join(homedir(), ".local/share/termsuggest");

const engine = new Engine({
  specDir: join(root, "specs"),
  usageFile: join(dataDir, "usage.json"),
  showHidden: process.env.TERMSUGGEST_SHOW_HIDDEN === "1",
});

const US = "\x1f";
const clean = (s) =>
  String(s ?? "")
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
    .replace(/[\n\r\t]+/g, " ")
    .replace(/[\x00\x02-\x1f\x7f]/g, "");
// For text the shell draws itself: emoji and other wide/ambiguous glyphs make
// zsh and the terminal disagree about widths, which garbles the line.
const narrow = (s) =>
  s.replace(/[\u{1F000}-\u{1FFFF}\u{2190}-\u{2BFF}\u{FE00}-\u{FE0F}\u{200B}-\u{200F}\u{E000}-\u{F8FF}\u{0300}-\u{036F}]/gu, "").replace(/ {2,}/g, " ").trim();

const shells = new Map(); // conn id -> socket
const overlays = new Set();
let nextConn = 1;
let overlayLaunchedAt = 0;
const overlayApp = join(root, "overlay/TermSuggest.app");

function launchOverlay() {
  if (process.platform !== "darwin" || !existsSync(overlayApp)) return;
  if (Date.now() - overlayLaunchedAt < 15000) return;
  overlayLaunchedAt = Date.now();
  spawn("open", ["-g", "-a", overlayApp, "--args", socketPath], { stdio: "ignore", detached: true }).unref();
}

function toOverlays(msg) {
  const line = JSON.stringify(msg) + "\n";
  for (const o of overlays) if (!o.destroyed) o.write(line);
}

async function handle(line, sock) {
  const [id, type, cwd, ...rest] = line.split(US);
  const payload = rest.join(US).replace(/\x1e/g, "\n");
  switch (type) {
    case "q": {
      const res = await engine.suggest(payload, cwd || homedir());
      sock.lastItems = res.items;
      const useOverlay = overlays.size > 0 ? 1 : 0;
      if (!useOverlay) launchOverlay();
      const fields = [id, res.replaceLen, res.tokenStart, useOverlay, res.items.length];
      for (const it of res.items) fields.push(clean(it.insert), narrow(clean(it.display)), narrow(clean(it.desc)).slice(0, 200), it.kind);
      return fields.join(US);
    }
    case "v": {
      const [sel, vis, aRow, aCol, cRow, cCol, cols, lines, cellW, cellH] = payload.split(":").map(Number);
      const items = sock.lastItems ?? [];
      if (!vis || !items.length) toOverlays({ type: "hide", conn: sock.conn });
      else
        toOverlays({
          type: "show",
          conn: sock.conn,
          sel,
          aRow, aCol, cRow, cCol, cols, lines, cellW, cellH,
          items: items.map((it) => ({ display: clean(it.display), desc: clean(it.desc).slice(0, 300), kind: it.kind })),
        });
      return null;
    }
    case "r":
      await engine.record(payload, cwd || homedir());
      return null;
    case "d":
      engine.recordDir(payload);
      return null;
    case "a":
      engine.setAliases(payload);
      return null;
    case "p":
      return `${id}${US}pong`;
    default:
      return null;
  }
}

function handleOverlay(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg.type === "accept") {
    const shell = shells.get(msg.conn);
    if (shell && !shell.destroyed) shell.write(`0${US}accept${US}${(msg.index | 0) + 1}\n`);
  }
}

const server = createServer((sock) => {
  sock.setEncoding("utf8");
  sock.conn = nextConn++;
  shells.set(sock.conn, sock);
  let buf = "";
  sock.on("data", (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (line === "overlay") {
        shells.delete(sock.conn);
        overlays.add(sock);
        continue;
      }
      if (overlays.has(sock)) {
        handleOverlay(line);
        continue;
      }
      handle(line, sock)
        .then((out) => {
          if (out != null && !sock.destroyed) sock.write(out + "\n");
        })
        .catch((e) => console.error(new Date().toISOString(), e?.stack ?? e));
    }
  });
  const gone = () => {
    if (shells.delete(sock.conn)) toOverlays({ type: "hide", conn: sock.conn });
    overlays.delete(sock);
  };
  sock.on("close", gone);
  sock.on("error", gone);
});

function listen() {
  server.listen(socketPath, () => {
    console.error(`${new Date().toISOString()} termsuggest daemon listening on ${socketPath} (pid ${process.pid})`);
  });
}

// Refuse to start twice; clean up a stale socket left by a crashed daemon.
if (existsSync(socketPath)) {
  const probe = connect(socketPath);
  probe.on("connect", () => {
    console.error("daemon already running");
    process.exit(0);
  });
  probe.on("error", () => {
    try {
      unlinkSync(socketPath);
    } catch {}
    listen();
  });
} else listen();

const shutdown = () => {
  engine.usage.save();
  try {
    unlinkSync(socketPath);
  } catch {}
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("SIGHUP", () => {});
process.on("uncaughtException", (e) => console.error(new Date().toISOString(), e?.stack ?? e));
process.on("unhandledRejection", (e) => console.error(new Date().toISOString(), e?.stack ?? e));
