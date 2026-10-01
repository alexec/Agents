// A live page's unit of everything: Passage and PassageMerge (Model/Passage.swift), ported by
// hand and held to Fixtures/web/page (research R7). A passage is a run of source lines between
// blank lines, a fence always whole; the person edits one passage at a time, and what they type
// is merged with what the agent wrote meanwhile by asking one question: did the agent touch my
// lines?

export interface Passage {
  /** The lines, joined with newlines, without the one ending the last. */
  source: string;
  /** First and last line, counted from one. */
  lines: [number, number];
  /** The newlines that followed, kept exactly so a round trip writes back the same file. */
  separator: string;
  isHeading: boolean;
}

function isBlank(line: string): boolean {
  return /^[ \t]*$/.test(line);
}

function leadingSpaces(line: string): number {
  return line.length - line.replace(/^ +/, "").length;
}

/** Up to three spaces of indent, then three or more backticks or tildes. */
function opensFence(line: string): { character: string; length: number } | null {
  const trimmed = line.replace(/^ +/, "");
  if (leadingSpaces(line) > 3) return null;
  const first = trimmed[0];
  if (first !== "`" && first !== "~") return null;
  let run = 0;
  while (trimmed[run] === first) run++;
  if (run < 3) return null;
  if (first === "`" && trimmed.slice(run).includes("`")) return null;
  return { character: first, length: run };
}

function closesFence(line: string, open: { character: string; length: number }): boolean {
  const trimmed = line.replace(/^ +/, "");
  if (leadingSpaces(line) > 3) return false;
  let run = 0;
  while (trimmed[run] === open.character) run++;
  if (run < open.length) return false;
  return /^[ \t]*$/.test(trimmed.slice(run));
}

function isHeading(lines: string[]): boolean {
  const content = lines.slice(lines.findIndex((l) => !isBlank(l)));
  const first = content[0];
  if (first === undefined || lines.every(isBlank)) return false;
  if (first === "---") return false;
  let hashes = 0;
  while (first[hashes] === "#") hashes++;
  if (hashes >= 1 && hashes <= 6 && (first.length === hashes || first[hashes] === " ")) return true;
  const second = content[1];
  if (second === undefined) return false;
  const underline = second.replace(/^ +/, "");
  const mark = underline[0];
  if (mark !== "=" && mark !== "-") return false;
  return [...underline].every((c) => c === mark || c === " ") && underline.includes(mark) && !isBlank(first);
}

/** The document as passages; empty for an empty or all-blank document. */
export function split(text: string): Passage[] {
  if (text === "") return [];
  const lines = text.split("\n");
  const endsWithNewline = text.endsWith("\n");
  const count = endsWithNewline ? lines.length - 1 : lines.length;
  const passages: Passage[] = [];
  let current: string[] = [];
  let start = 1;
  let fence: { character: string; length: number } | null = null;

  const close = (last: number, blankAfter: number, endsDocument: boolean) => {
    const ending = endsDocument && !endsWithNewline ? 0 : 1;
    passages.push({ source: current.join("\n"), lines: [start, last], separator: "\n".repeat(ending + blankAfter),
      isHeading: isHeading(current) });
    current = [];
  };

  let index = 0;
  while (index < count) {
    const line = lines[index]!;
    const number = index + 1;
    if (fence === null && current.length === 0 && isBlank(line) && passages.length === 0) {
      current.push(line);
      index++;
      continue;
    }
    if (fence) {
      current.push(line);
      if (closesFence(line, fence)) fence = null;
      index++;
      continue;
    }
    if (isBlank(line) && current.length > 0 && !current.every(isBlank)) {
      let blank = 0;
      let cursor = index;
      while (cursor < count && isBlank(lines[cursor]!)) { blank++; cursor++; }
      close(number - 1, blank, cursor >= count);
      start = cursor + 1;
      index = cursor;
      continue;
    }
    if (isBlank(line)) {
      current.push(line);
      index++;
      continue;
    }
    if (current.length === 0) start = number;
    const opened = opensFence(line);
    if (opened) fence = opened;
    current.push(line);
    index++;
  }
  if (current.length > 0 && !current.every(isBlank)) close(count, 0, true);
  return passages;
}

/** The document back from its passages: join(split(x)) === x. */
export function join(passages: readonly Passage[]): string {
  return passages.map((p) => p.source + p.separator).join("");
}

/** The passage holding a line, counted from one; past the end is the last; nothing is nowhere. */
export function indexContaining(line: number, passages: readonly Passage[]): number | null {
  if (line < 1 || passages.length === 0) return null;
  const exact = passages.findIndex((p) => line >= p.lines[0] && line <= p.lines[1]);
  if (exact >= 0) return exact;
  for (let i = passages.length - 1; i >= 0; i--) if (passages[i]!.lines[1] < line) return i;
  return 0;
}

export type MergeResult =
  | { merged: { text: string; passageIndex: number } }
  | { collided: { text: string; passageIndex: number; theirs: string } };

/** PassageMerge.apply: the person's edit of `mine` (a passage of `base`) into `theirs`. */
export function merge(base: string, theirs: string, mine: Passage, edited: string): MergeResult {
  const theirPassages = split(theirs);
  const candidates = theirPassages.map((_, i) => i).filter((i) => theirPassages[i]!.source === mine.source);
  if (candidates.length) {
    const distance = (i: number) => Math.abs(theirPassages[i]!.lines[0] - mine.lines[0]);
    const index = candidates.reduce((best, i) => (distance(i) < distance(best) ? i : best));
    const merged = theirPassages.map((p) => ({ ...p }));
    merged[index]!.source = edited;
    return { merged: { text: join(merged), passageIndex: index } };
  }
  if (!theirPassages.length) return { collided: { text: edited, passageIndex: 0, theirs: "" } };
  const index = indexContaining(mine.lines[0], theirPassages) ?? theirPassages.length - 1;
  const merged = theirPassages.map((p) => ({ ...p }));
  const replaced = merged[index]!;
  const basePassages = split(base);
  if (basePassages.some((p) => p.source === replaced.source && p.lines[0] > mine.lines[0])) {
    merged.splice(index, 0, { source: edited, lines: mine.lines, separator: "\n\n", isHeading: false });
    return { collided: { text: join(merged), passageIndex: index, theirs: "" } };
  }
  merged[index] = { ...replaced, source: edited };
  return { collided: { text: join(merged), passageIndex: index, theirs: replaced.source } };
}
