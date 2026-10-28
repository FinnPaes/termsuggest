// Remembers which suggestions were used and when, so recently/frequently
// used ones (folders you cd into, branches you push to...) float to the top.
import { readFileSync, writeFileSync, mkdirSync, renameSync } from "node:fs";
import { dirname } from "node:path";

const MAX_ENTRIES = 30000;

export class UsageStore {
  constructor(file) {
    this.file = file;
    this.data = new Map();
    this.timer = null;
    try {
      const raw = JSON.parse(readFileSync(file, "utf8"));
      for (const [k, v] of Object.entries(raw)) this.data.set(k, v);
    } catch {}
  }

  static key(context, value) {
    return `${context}\0${value}`;
  }

  record(context, value, now = Date.now()) {
    const k = UsageStore.key(context, value);
    const e = this.data.get(k) ?? { c: 0, t: 0 };
    e.c += 1;
    e.t = now;
    this.data.delete(k); // re-insert so Map order tracks recency
    this.data.set(k, e);
    this.scheduleSave();
  }

  get(context, value) {
    return this.data.get(UsageStore.key(context, value));
  }

  scheduleSave() {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.save();
    }, 2000);
  }

  save() {
    while (this.data.size > MAX_ENTRIES) this.data.delete(this.data.keys().next().value);
    try {
      mkdirSync(dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      writeFileSync(tmp, JSON.stringify(Object.fromEntries(this.data)));
      renameSync(tmp, this.file);
    } catch {}
  }
}
