// Suggestion engine: interprets Fig completion specs against the command line
// that is being typed and produces a ranked list of suggestions.
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { spawn } from "node:child_process";
import { join, resolve, basename } from "node:path";
import { pathToFileURL } from "node:url";
import { tokenize, shellEscape } from "./tokenize.js";
import { UsageStore } from "./usage.js";

const MAX_RESULTS = 60;
const GENERATOR_TIMEOUT = 4000;
const DEFAULT_GENERATOR_TTL = 2000;
const CURSOR_MARK = "\x01";

const arr = (x) => (x == null ? [] : Array.isArray(x) ? x : [x]);
const names = (x) => arr(x?.name).filter((n) => typeof n === "string");

export class Engine {
  constructor({ specDir, usageFile, showHidden = false }) {
    this.specDir = specDir;
    this.usage = new UsageStore(usageFile);
    this.showHidden = showHidden;
    this.specCache = new Map();
    this.genCache = new Map();
    this.genIds = new WeakMap();
    this.aliases = new Map();
    this.pathCommands = null;
    this.pathCommandsAt = 0;
    try {
      this.specIndex = JSON.parse(readFileSync(join(specDir, "index.json"), "utf8"));
    } catch {
      this.specIndex = {};
    }
  }

  // ---------------------------------------------------------------- specs

  async loadSpec(name) {
    if (!name || name.includes("..") || name.startsWith("/")) return null;
    if (this.specCache.has(name)) return this.specCache.get(name);
    const promise = (async () => {
      const file = join(this.specDir, `${name}.js`);
      if (!existsSync(file)) return null;
      try {
        const mod = await import(pathToFileURL(file).href);
        let spec = mod.default;
        if (typeof spec === "function") {
          // Versioned spec (createVersionedSpec): resolves to the newest version file.
          const res = await spec(undefined);
          if (res?.versionedSpecPath) return this.loadSpec(res.versionedSpecPath);
          spec = res;
        }
        return spec && typeof spec === "object" ? spec : null;
      } catch {
        return null;
      }
    })();
    this.specCache.set(name, promise);
    return promise;
  }

  async resolveLoadSpec(loadSpec, token, cwd) {
    let ls = loadSpec;
    if (typeof ls === "function") {
      try {
        ls = await ls(token, this.executor(cwd));
      } catch {
        return null;
      }
    }
    ls = arr(ls)[0];
    if (typeof ls === "string") return this.loadSpec(ls);
    if (ls && typeof ls === "object") {
      if (ls.name && !ls.subcommands && !ls.options && !ls.args && (ls.type === "global" || ls.type === "public")) {
        return this.loadSpec(ls.name);
      }
      return ls;
    }
    return null;
  }

  // Applies loadSpec / generateSpec of a subcommand so its children are known.
  async expandNode(node, tokens, cwd) {
    let out = node;
    if (node.loadSpec) {
      const loaded = await this.resolveLoadSpec(node.loadSpec, tokens[tokens.length - 1], cwd);
      if (loaded) {
        out = {
          ...loaded,
          name: node.name,
          description: node.description ?? loaded.description,
          options: [...arr(node.options), ...arr(loaded.options)],
          loadSpec: undefined,
        };
      }
    }
    if (typeof out.generateSpec === "function") {
      const key = `spec:${this.genId(out.generateSpec)}:${cwd}`;
      const generated = await this.cached(key, 10000, () => out.generateSpec(tokens, this.executor(cwd)));
      if (generated) {
        out = {
          ...out,
          generateSpec: undefined,
          subcommands: [...arr(out.subcommands), ...arr(generated.subcommands)],
          options: [...arr(out.options), ...arr(generated.options)],
          args: out.args ?? generated.args,
        };
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- shell

  executor(cwd) {
    return async (input) => {
      if (typeof input === "string") {
        const r = await run("/bin/bash", ["-c", input], cwd);
        return r.stdout.replace(/\n$/, "");
      }
      const r = await run(input.command, input.args ?? [], input.cwd ?? cwd, input.env);
      return r;
    };
  }

  genId(obj) {
    let id = this.genIds.get(obj);
    if (!id) {
      id = this.genIds.size + 1 + Math.random().toString(36).slice(2, 6);
      this.genIds.set(obj, id);
    }
    return id;
  }

  async cached(key, ttl, fn) {
    const hit = this.genCache.get(key);
    const now = Date.now();
    if (hit && now - hit.at < ttl) return hit.value;
    const value = Promise.resolve()
      .then(fn)
      .catch(() => null);
    this.genCache.set(key, { at: now, value });
    if (this.genCache.size > 500) {
      for (const [k, v] of this.genCache) if (now - v.at > 60000) this.genCache.delete(k);
    }
    return value;
  }

  setAliases(text) {
    this.aliases.clear();
    for (const line of text.split("\n")) {
      const m = line.match(/^(?:alias\s+)?([^=\s]+)=(.*)$/);
      if (!m) continue;
      const { segments, words, current } = tokenize(m[2]);
      // Only simple aliases (no pipes / chains) are expanded.
      if (segments.length) continue;
      const parts = [...words.map((w) => w.text), current.text].filter(Boolean);
      if (parts.length) this.aliases.set(m[1], parts);
    }
  }

  // --------------------------------------------------------------- parsing

  // Walks the completed tokens of one command through its spec and returns
  // where the user is: which (sub)command, which arg is expected, etc.
  // `onToken` is used when recording executed commands for ranking.
  async analyze(tokens, cwd, onToken) {
    tokens = [...tokens];
    while (tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[0])) tokens.shift();
    if (tokens.length === 0) return { mode: "command" };

    const seen = new Set();
    while (this.aliases.has(tokens[0]) && !seen.has(tokens[0])) {
      seen.add(tokens[0]);
      tokens.splice(0, 1, ...this.aliases.get(tokens[0]));
    }

    const cmd = basename(tokens[0]);
    onToken?.("", cmd);
    const spec = await this.loadSpec(cmd);
    if (!spec) return { mode: "nospec", path: [cmd], allTokens: tokens };

    let node = await this.expandNode(spec, tokens.slice(0, 1), cwd);
    const path = [cmd];
    let persistent = arr(node.options).filter((o) => o.isPersistent);
    let argIdx = 0;
    let pending = null; // { option, idx }
    let doubleDash = false;
    const used = new Set();
    const posixFlags = !node.parserDirectives?.flagsArePosixNoncompliant;

    const optionsOf = () => [...arr(node.options), ...persistent.filter((p) => !arr(node.options).includes(p))];
    const findOption = (name) => optionsOf().find((o) => names(o).includes(name));

    for (let i = 1; i < tokens.length; i++) {
      const t = tokens[i];
      const ctx = path.join(" ");

      if (pending) {
        const a = arr(pending.option.args)[pending.idx];
        const skip = a?.isOptional && t.startsWith("-");
        if (!skip) {
          onToken?.(ctx, t, true);
          if (!a?.isVariadic) pending.idx++;
          if (pending.idx >= arr(pending.option.args).length) pending = null;
          continue;
        }
        pending = null;
      }

      if (!doubleDash && t === "--") {
        doubleDash = true;
        continue;
      }

      if (!doubleDash && t.length > 1 && t.startsWith("-")) {
        let opt = findOption(t);
        let inlineValue = false;
        if (!opt && t.includes("=")) {
          opt = findOption(t.slice(0, t.indexOf("=")));
          inlineValue = !!opt;
        }
        if (!opt && posixFlags && /^-[^-]{2,}$/.test(t)) {
          // Chained short flags: -abc
          for (const ch of t.slice(1)) {
            const o = findOption(`-${ch}`);
            if (o) {
              names(o).forEach((n) => used.add(n));
              opt = o;
            }
          }
          inlineValue = opt && t.slice(-1) !== names(opt).find((n) => n.length === 2)?.[1];
        }
        if (opt) {
          names(opt).forEach((n) => used.add(n));
          onToken?.(ctx, names(opt)[0]);
          if (arr(opt.args).length && !inlineValue) pending = { option: opt, idx: 0 };
        }
        continue;
      }

      if (argIdx === 0) {
        const sub = arr(node.subcommands).find((s) => names(s).includes(t));
        if (sub) {
          onToken?.(ctx, names(sub)[0]);
          node = await this.expandNode(sub, tokens.slice(0, i + 1), cwd);
          path.push(names(sub)[0]);
          persistent = [...persistent, ...arr(node.options).filter((o) => o.isPersistent)];
          continue;
        }
      }

      const a = arr(node.args)[argIdx];
      if (a?.isCommand) return this.analyze(tokens.slice(i), cwd, onToken);
      if (a?.loadSpec) {
        const loaded = await this.resolveLoadSpec(a.loadSpec, t, cwd);
        if (loaded) {
          node = await this.expandNode(loaded, tokens.slice(0, i + 1), cwd);
          path.push(t);
          argIdx = 0;
          continue;
        }
      }
      onToken?.(ctx, t, true);
      if (a && !a.isVariadic) argIdx++;
    }

    return { mode: "spec", node, path, persistent, argIdx, pending, used, doubleDash, allTokens: tokens, optionsOf };
  }

  // ------------------------------------------------------------ suggesting

  async suggest(line, cwd) {
    const { words, current } = tokenize(line);
    const query = current.text;
    const tokens = words.map((w) => w.text);
    const ctx = await this.analyze(tokens, cwd);
    const genTokens = [...(ctx.allTokens ?? tokens), query];
    let cands = [];

    if (ctx.mode === "command") {
      if (!query) return empty(current, line);
      if (query.includes("/")) cands = this.fileCandidates(cwd, query, false, "", "file");
      else cands = this.commandCandidates(query);
    } else if (ctx.mode === "nospec") {
      cands = this.fileCandidates(cwd, query, false, ctx.path.join(" "));
    } else {
      cands = await this.specCandidates(ctx, query, cwd, genTokens);
    }

    const items = this.rank(cands, query).slice(0, MAX_RESULTS);
    if (items.length === 1 && items[0].value === query && items[0].kind !== "folder") return empty(current, line);

    return {
      ...empty(current, line),
      items: items.map((c) => ({
        insert: this.insertText(c, current),
        display: c.display,
        desc: c.desc,
        kind: c.kind,
      })),
    };
  }

  async specCandidates(ctx, query, cwd, genTokens) {
    const { node, path } = ctx;
    const pathKey = path.join(" ");
    const out = [];

    if (ctx.pending) {
      const a = arr(ctx.pending.option.args)[ctx.pending.idx];
      out.push(...(await this.argCandidates(a, query, cwd, genTokens, pathKey)));
      if (!a?.isOptional) return out;
    }

    if (!ctx.doubleDash && query.startsWith("-")) {
      const eq = query.indexOf("=");
      if (eq > 0) {
        const opt = ctx.optionsOf().find((o) => names(o).includes(query.slice(0, eq)));
        if (opt && arr(opt.args).length) {
          const sub = await this.argCandidates(arr(opt.args)[0], query.slice(eq + 1), cwd, genTokens, pathKey);
          return sub.map((c) => ({ ...c, keep: query.slice(0, eq + 1) + c.keep }));
        }
      }
      return this.optionCandidates(ctx, pathKey);
    }

    if (ctx.argIdx === 0) {
      for (const s of arr(node.subcommands)) {
        if (s.hidden) continue;
        out.push(this.cand(s, "subcommand", pathKey));
      }
    }
    const a = arr(node.args)[ctx.argIdx];
    if (a) out.push(...(await this.argCandidates(a, query, cwd, genTokens, pathKey)));
    if (out.length === 0 && !ctx.doubleDash && !query) return this.optionCandidates(ctx, pathKey);
    return out;
  }

  optionCandidates(ctx, pathKey) {
    const out = [];
    for (const o of ctx.optionsOf()) {
      if (o.hidden || o.deprecated) continue;
      const ns = names(o);
      if (!o.isRepeatable && ns.some((n) => ctx.used.has(n))) continue;
      if (arr(o.exclusiveOn).some((n) => ctx.used.has(n))) continue;
      const c = this.cand(o, "option", pathKey);
      c.display = ns.join(", ");
      if (o.requiresEquals || o.requiresSeparator) c.noSpace = c.sep = typeof o.requiresSeparator === "string" ? o.requiresSeparator : "=";
      out.push(c);
    }
    return out;
  }

  cand(obj, kind, pathKey) {
    const ns = typeof obj === "string" ? [obj] : names(obj);
    return {
      names: ns,
      display: obj.displayName ?? ns[0],
      desc: obj.description ?? "",
      insertValue: obj.insertValue,
      priority: obj.priority ?? 50,
      kind,
      keep: "",
      usageCtx: pathKey,
    };
  }

  async argCandidates(a, query, cwd, genTokens, pathKey) {
    if (!a) return [];
    const out = [];
    if (a.isCommand) return this.commandCandidates(query);

    for (const s of arr(a.suggestions)) {
      if (s?.hidden) continue;
      out.push({ ...this.cand(s, s?.type === "folder" || s?.type === "file" ? s.type : "arg", pathKey), filter: a.filterStrategy });
    }

    for (const tpl of arr(a.template)) {
      out.push(...this.fileCandidates(cwd, query, tpl === "folders", pathKey));
    }

    for (const g of arr(a.generators)) {
      const results = await this.runGenerator(g, query, cwd, genTokens, pathKey);
      for (const c of results) {
        c.filter = c.filter ?? a.filterStrategy;
        out.push(c);
      }
    }
    return out;
  }

  async runGenerator(g, query, cwd, genTokens, pathKey) {
    let term = query;
    if (typeof g.getQueryTerm === "string") term = query.slice(query.lastIndexOf(g.getQueryTerm) + 1);
    else if (typeof g.getQueryTerm === "function") {
      try {
        term = g.getQueryTerm(query) ?? query;
      } catch {}
    }
    const keep = query.slice(0, query.length - term.length);

    if (g.template) {
      let files = [];
      for (const tpl of arr(g.template)) files.push(...this.fileCandidates(cwd, query, tpl === "folders", pathKey));
      if (typeof g.filterTemplateSuggestions === "function") {
        try {
          const kept = new Set(
            g.filterTemplateSuggestions(files.map((f) => ({ name: f.names[0], type: f.kind, context: { templateType: f.kind === "folder" ? "folders" : "filepaths" } }))).map((s) => s.name)
          );
          files = files.filter((f) => kept.has(f.names[0]));
        } catch {}
      }
      return files;
    }

    const ttl = g.cache?.ttl ?? DEFAULT_GENERATOR_TTL;
    const key = `gen:${this.genId(g)}:${cwd}:${genTokens.slice(0, -1).join("\0")}:${keep}`;
    const results = await this.cached(key, ttl, () =>
      withTimeout(this.generate(g, cwd, genTokens, query), GENERATOR_TIMEOUT)
    );

    return arr(results)
      .filter((s) => s && (typeof s === "string" || !s.hidden))
      .map((s) => {
        const kind = s.type === "folder" || s.type === "file" ? s.type : "arg";
        const c = this.cand(s, kind, pathKey);
        c.keep = keep;
        if (kind === "file" || kind === "folder") c.absPath = resolve(expandHome(cwd, keep), c.names[0]);
        return c;
      })
      .filter((c) => c.names.length && c.names[0] !== "");
  }

  async generate(g, cwd, tokens, query) {
    const exec = this.executor(cwd);
    if (typeof g.custom === "function") {
      const context = {
        currentWorkingDirectory: cwd,
        currentProcess: "zsh",
        sshPrefix: "",
        searchTerm: query,
        environmentVariables: { ...process.env, PWD: cwd },
        isDangerous: false,
      };
      return g.custom(tokens, exec, context);
    }
    if (!g.script) return [];
    let script = typeof g.script === "function" ? g.script(tokens) : g.script;
    let stdout;
    if (typeof script === "string") stdout = await exec(script);
    else if (Array.isArray(script)) stdout = (await run(script[0], script.slice(1), cwd)).stdout;
    else stdout = (await exec(script)).stdout;
    stdout = stdout.replace(/\s+$/, "");
    if (typeof g.postProcess === "function") return g.postProcess(stdout, tokens);
    return stdout
      .split(g.splitOn ?? "\n")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((name) => ({ name }));
  }

  fileCandidates(cwd, query, foldersOnly, pathKey, kindOverride) {
    const slash = query.lastIndexOf("/");
    const keep = query.slice(0, slash + 1);
    const term = query.slice(slash + 1);
    const dir = keep ? expandHome(cwd, keep) : cwd;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return [];
    }
    const out = [];
    for (const e of entries) {
      if (e.name === ".DS_Store") continue;
      let isDir = e.isDirectory();
      if (e.isSymbolicLink()) {
        try {
          isDir = statSync(join(dir, e.name)).isDirectory();
        } catch {}
      }
      if (foldersOnly && !isDir) continue;
      const name = isDir ? `${e.name}/` : e.name;
      out.push({
        names: [name],
        display: name,
        desc: "",
        priority: 50,
        kind: kindOverride && !isDir ? kindOverride : isDir ? "folder" : "file",
        keep,
        usageCtx: pathKey,
        absPath: join(dir, e.name),
      });
    }
    return out;
  }

  commandCandidates(query) {
    const out = [];
    const seen = new Set();
    const add = (name, desc, priority) => {
      if (seen.has(name)) return;
      seen.add(name);
      out.push({ names: [name], display: name, desc, priority, kind: "command", keep: "", usageCtx: "" });
    };
    for (const [name, parts] of this.aliases) add(name, `alias: ${parts.join(" ")}`, 50);
    for (const [name, desc] of Object.entries(this.specIndex)) add(name, desc, 50);
    if (query) for (const name of this.getPathCommands()) add(name, "", 40);
    return out;
  }

  getPathCommands() {
    if (this.pathCommands && Date.now() - this.pathCommandsAt < 60000) return this.pathCommands;
    const set = new Set();
    for (const dir of (process.env.PATH ?? "").split(":")) {
      try {
        for (const f of readdirSync(dir)) set.add(f);
      } catch {}
    }
    this.pathCommands = [...set];
    this.pathCommandsAt = Date.now();
    return this.pathCommands;
  }

  // ---------------------------------------------------------------- ranking

  rank(cands, query) {
    const scored = [];
    cands.forEach((c, order) => {
      const term = query.slice(c.keep.length);
      if (!query.startsWith(c.keep)) return;
      const hiddenFile = (c.kind === "file" || c.kind === "folder") && c.names[0].startsWith(".");
      if (hiddenFile && !this.showHidden && !term.startsWith(".")) return;

      let best = null;
      for (const n of c.names) {
        const m = matchScore(n, term, c.filter === "fuzzy");
        if (m !== null && (best === null || m < best.m)) best = { m, n };
      }
      if (!best) return;

      const usageValue = c.absPath ? c.absPath.replace(/\/$/, "") : best.n;
      const u = this.usage.get(c.usageCtx, usageValue);
      scored.push({ ...c, match: best.m, value: best.n, used: u?.t ?? 0, count: u?.c ?? 0, order });
    });

    // Fig-like: high (>75) / low (<50) priority stays put; the rest is ordered
    // by how recently it was used.
    const bucket = (c) => (c.priority > 75 ? 2 : c.priority < 50 ? 0 : 1);
    scored.sort(
      (a, b) =>
        a.match - b.match ||
        bucket(b) - bucket(a) ||
        (bucket(a) !== 1 ? b.priority - a.priority : 0) ||
        b.used - a.used ||
        b.priority - a.priority ||
        a.order - b.order
    );

    const seen = new Set();
    return scored.filter((c) => {
      const k = `${c.kind}:${c.keep}${c.value}`;
      if (seen.has(k)) return false;
      seen.add(k);
      c.display = c.display === c.names[0] && c.names.length > 1 && c.kind !== "option" ? c.value : c.display;
      return true;
    });
  }

  insertText(c, current) {
    let value = c.keep + (c.insertValue ?? c.value);
    if (c.sep) value += c.sep;
    const isDir = c.kind === "folder" || value.endsWith("/");
    const quote = current.quote;
    const parts = value.split("{cursor}");
    const escaped = parts.map((p, i) => shellEscape(p, i === 0 ? quote : null, true)).join(CURSOR_MARK);
    let out = escaped;
    if (quote && !isDir && parts.length === 1) out += quote;
    if (!isDir && !c.noSpace && parts.length === 1) out += " ";
    return out;
  }

  // ---------------------------------------------------------------- learning

  async record(line, cwd) {
    const { segments, words, current } = tokenize(line);
    const all = [...segments, [...words, current]];
    for (const seg of all) {
      const toks = seg.map((w) => w.text).filter((t, i, a) => t !== "" || i < a.length - 1);
      if (!toks.length) continue;
      try {
        await this.analyze(toks, cwd, (ctx, value, positional) => {
          this.usage.record(ctx, value);
          if (positional) {
            const abs = resolve(expandHome(cwd, value));
            if (abs !== value && existsSync(abs)) this.usage.record(ctx, abs.replace(/\/$/, ""));
          }
        });
      } catch {}
    }
  }

  recordDir(dir) {
    this.usage.record("cd", dir.replace(/(.)\/$/, "$1"));
  }
}

// Lengths in characters (code points), which is what zsh counts in.
function empty(current, line) {
  return { replaceLen: [...current.raw].length, tokenStart: [...line.slice(0, current.start)].length, items: [] };
}

function expandHome(cwd, p) {
  if (p === "~" || p.startsWith("~/")) return (process.env.HOME ?? "") + p.slice(1);
  return resolve(cwd, p);
}

// Lower is better; null means no match.
function matchScore(name, term, fuzzy) {
  if (!term) return 0;
  const n = name.toLowerCase();
  const t = term.toLowerCase();
  if (name.startsWith(term)) return 0;
  if (n.startsWith(t)) return 1;
  // "fuzzy" specs (like cd) also match in the middle of a name.
  if (fuzzy && n.includes(t)) return 2;
  return null;
}

function run(command, args, cwd, env) {
  return new Promise((done) => {
    let stdout = "";
    let stderr = "";
    let child;
    try {
      child = spawn(command, args, { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
    } catch {
      return done({ stdout: "", stderr: "", status: 1 });
    }
    const timer = setTimeout(() => child.kill("SIGKILL"), GENERATOR_TIMEOUT);
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", () => {});
    child.on("close", (status) => {
      clearTimeout(timer);
      done({ stdout, stderr, status: status ?? 1 });
    });
  });
}

function withTimeout(promise, ms) {
  return Promise.race([promise, new Promise((r) => setTimeout(() => r([]), ms))]);
}
