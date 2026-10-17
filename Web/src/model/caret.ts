// The agent's caret on a live page (#1236): PageFollower's reveal, tick and complete
// (Model/PageFollower.swift), ported by hand. There is one caret on a page. The passages a write
// changed queue in document order; the caret types each in turn from where it stopped agreeing
// with what was there before, and until its turn a passage shows what it said before the write
// (nothing, for a new one). A new write completes whatever is still on its way rather than race it.

/** Characters typed each tick: 200 a second at `typingTick`, the window's and the Remote's pace. */
export const typingStep = 8;
/** The caret's beat, in milliseconds. */
export const typingTick = 40;

/** A passage being typed, or waiting to be. Counts are in characters (code points), not UTF-16. */
export interface Reveal {
  index: number;
  /** How many characters are drawn now. */
  shown: number;
  /** What the passage said before the write: drawn while it waits its turn. */
  before: string;
}

export interface Caret {
  revealing: Reveal | null;
  pending: Reveal[];
}

export const idle: Caret = { revealing: null, pending: [] };

function characters(text: string): string[] {
  return Array.from(text);
}

/**
 * Queue the changed passages for the caret, in document order, each from the prefix it shares
 * with the passage that was there before. A passage with nothing new to type is left out.
 */
export function reveal(previous: readonly string[], next: readonly string[], changed: readonly number[]): Caret {
  const queue: Reveal[] = [];
  for (const index of [...changed].sort((a, b) => a - b)) {
    const now = next[index];
    if (now === undefined) continue;
    const old = previous[index] ?? "";
    const a = characters(old);
    const b = characters(now);
    let agreed = 0;
    while (agreed < a.length && agreed < b.length && a[agreed] === b[agreed]) agreed++;
    if (agreed >= b.length) continue;
    queue.push({ index, shown: agreed, before: old });
  }
  const [first, ...rest] = queue;
  return first ? { revealing: first, pending: rest } : idle;
}

/** One beat: the caret moves `typingStep` on, and to the next passage when this one is whole. */
export function tick(caret: Caret, sources: readonly string[]): Caret {
  const current = caret.revealing;
  if (!current) return caret;
  const source = sources[current.index];
  if (source === undefined) return next(caret);
  const shown = current.shown + typingStep;
  if (shown >= characters(source).length) return next(caret);
  return { revealing: { ...current, shown }, pending: caret.pending };
}

/** The person opened this passage: it is theirs whole, and the caret goes on to the next. */
export function skip(caret: Caret, index: number): Caret {
  const pending = caret.pending.filter((r) => r.index !== index);
  if (caret.revealing?.index === index) return next({ revealing: null, pending });
  return { revealing: caret.revealing, pending };
}

/** What the passage shows now: as far as typed, what it said before, or all of it. */
export function shown(caret: Caret, index: number, source: string): string {
  if (caret.revealing?.index === index) return characters(source).slice(0, caret.revealing.shown).join("");
  const waiting = caret.pending.find((r) => r.index === index);
  return waiting ? waiting.before : source;
}

function next(caret: Caret): Caret {
  const [first, ...rest] = caret.pending;
  return first ? { revealing: first, pending: rest } : idle;
}
