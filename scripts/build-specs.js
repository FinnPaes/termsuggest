// Compiles the Fig completion specs (vendor/fig-autocomplete/src/**/*.ts)
// into self-contained ESM files in ./specs that the daemon can import.
import { build } from "esbuild";
import { readdirSync, statSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const srcDir = join(root, "vendor/fig-autocomplete/src");
const outDir = join(root, "specs");

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (name.endsWith(".ts") && !name.endsWith(".d.ts")) out.push(p);
  }
  return out;
}

const entries = walk(srcDir);
rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

let failed = 0;
// Build in chunks so one broken spec doesn't take the rest down.
for (let i = 0; i < entries.length; i += 50) {
  const chunk = entries.slice(i, i + 50);
  try {
    await build({
      entryPoints: chunk,
      outdir: outDir,
      outbase: srcDir,
      bundle: true,
      format: "esm",
      platform: "node",
      target: "node20",
      logLevel: "silent", minify: true,
      nodePaths: [join(root, "node_modules")],
    });
  } catch {
    for (const entry of chunk) {
      try {
        await build({
          entryPoints: [entry], outdir: outDir, outbase: srcDir, bundle: true,
          format: "esm", platform: "node", target: "node20", logLevel: "silent", minify: true, minify: true,
          nodePaths: [join(root, "node_modules")],
        });
      } catch (e) {
        failed++;
        console.warn(`skip ${relative(srcDir, entry)}: ${e.message.split("\n")[0]}`);
      }
    }
  }
}

// Index of top-level command names, used for first-word suggestions.
const names = entries
  .map((e) => relative(srcDir, e).replace(/\.ts$/, ""))
  .filter((n) => !n.includes("/") && !n.startsWith("_") && n !== "index");
const index = {};
for (const name of names.sort()) {
  try {
    let spec = (await import(pathToFileURL(join(outDir, `${name}.js`)).href)).default;
    if (typeof spec === "function") {
      const res = await spec(undefined);
      spec = res?.versionedSpecPath
        ? (await import(pathToFileURL(join(outDir, `${res.versionedSpecPath}.js`)).href)).default
        : res;
    }
    const desc = spec?.description ?? "";
    index[name] = typeof desc === "string" ? desc.split("\n")[0] : "";
  } catch {
    index[name] = "";
  }
}
writeFileSync(join(outDir, "index.json"), JSON.stringify(index));
console.log(`compiled ${entries.length - failed} specs (${failed} skipped) -> specs/`);
