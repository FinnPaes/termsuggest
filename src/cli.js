// Debug helper: node src/cli.js "git pu" [cwd]
import { Engine } from "./engine.js";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const engine = new Engine({ specDir: join(root, "specs"), usageFile: join(root, ".cli-usage.json") });
const t = Date.now();
const res = await engine.suggest(process.argv[2] ?? "", process.argv[3] ?? process.cwd());
console.log(`replaceLen=${res.replaceLen} tokenStart=${res.tokenStart} (${Date.now() - t}ms)`);
for (const i of res.items.slice(0, 15)) console.log(`  [${i.kind}] ${JSON.stringify(i.insert)}  ${i.display}  — ${i.desc.slice(0, 60)}`);
process.exit(0);
