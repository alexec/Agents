// The page's own timings (#4784), as `performance` marks and measures named `agents:…`, so the
// night's walk (Web/test/walk/budgets.mjs) reads them with `performance.getEntriesByName`. They
// cost a few entries in the page's timeline and send nothing anywhere.

/** Marks `agents:<name>`, and, when `since` names an earlier mark, measures from it to now. */
export function mark(name: string, since?: string): void {
  if (typeof performance === "undefined" || typeof performance.mark !== "function") return;
  performance.mark(`agents:${name}`);
  if (since && performance.getEntriesByName(`agents:${since}`, "mark").length > 0) {
    performance.measure(`agents:${name}`, `agents:${since}`, `agents:${name}`);
  }
}

/** Marks `agents:<name>` once per page load: the first list, not every list after it. */
const marked = new Set<string>();
export function markOnce(name: string, since?: string): void {
  if (marked.has(name)) return;
  marked.add(name);
  mark(name, since);
}
