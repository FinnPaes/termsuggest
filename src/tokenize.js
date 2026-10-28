// Minimal shell tokenizer: splits a command line into command segments
// (separated by | ; & && || etc.) and those into words, unquoting as it goes.
// The last word of the last segment is the one being typed (may be empty).

const SEPARATORS = new Set(["|", ";", "&", "(", ")", "\n"]);

export function tokenize(line) {
  const segments = [];
  let words = [];
  let cur = null; // { text, start, quote }
  let quote = null;
  let i = 0;

  const startWord = (at) => {
    if (!cur) cur = { text: "", start: at, quote: null };
  };
  const endWord = () => {
    if (cur) words.push(cur);
    cur = null;
  };
  const endSegment = () => {
    endWord();
    segments.push(words);
    words = [];
  };

  while (i < line.length) {
    const c = line[i];
    if (quote === "'") {
      if (c === "'") quote = null;
      else cur.text += c;
      i++;
      continue;
    }
    if (quote === '"') {
      if (c === '"') quote = null;
      else if (c === "\\" && i + 1 < line.length && '"\\$`'.includes(line[i + 1])) {
        cur.text += line[i + 1];
        i++;
      } else cur.text += c;
      i++;
      continue;
    }
    if (c === "\\") {
      startWord(i);
      if (i + 1 < line.length) {
        if (line[i + 1] !== "\n") cur.text += line[i + 1];
        i += 2;
      } else i++;
      continue;
    }
    if (c === "'" || c === '"') {
      startWord(i);
      if (cur.text === "" && cur.start === i) cur.quote = c;
      quote = c;
      i++;
      continue;
    }
    if (c === " " || c === "\t") {
      endWord();
      i++;
      continue;
    }
    if (SEPARATORS.has(c)) {
      endSegment();
      i++;
      continue;
    }
    startWord(i);
    cur.text += c;
    i++;
  }

  // The word under the cursor; empty when the line ends in whitespace.
  const current = cur ?? { text: "", start: line.length, quote: null };
  current.raw = line.slice(current.start);
  current.openQuote = quote;
  return { segments, words, current };
}

const SPECIAL = /[\s'"\\$`!*?#&;|<>()[\]{}~]/g;

// Turns a value back into shell syntax for insertion. Keeps an opening quote
// the user already typed; leaves it open when the value is a directory so the
// user can keep typing the path.
export function shellEscape(value, quote, keepOpen) {
  if (quote === "'") return `'${value.replace(/'/g, "'\\''")}${keepOpen ? "" : "'"}`;
  if (quote === '"') return `"${value.replace(/(["\\$`])/g, "\\$1")}${keepOpen ? "" : '"'}`;
  return value.replace(SPECIAL, (m, off) => (m === "~" && off === 0 ? m : `\\${m}`));
}
