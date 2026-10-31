// PoolWords' runtime name and time words, shared by sandboxWords.ts and continueWhenBack.ts.
/** RuntimeCatalog's names, for a runtime the page may not be told about any more. */
const runtimeNames: Record<string, string> = {
  claude: "Claude", grok: "Grok", copilot: "Copilot", cursor: "Cursor", codex: "Codex",
  antigravity: "Antigravity", opencode: "OpenCode",
};

/** PoolWords.runtimeName: the catalog's name, else the id as written. */
export function runtimeName(id: string): string {
  return runtimeNames[id] ?? id;
}

/** PoolWords.time: "07:00" today, "Tue 07:00" within the week, a date after that. */
export function switchTime(date: Date, now: Date): string {
  const clock = date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  if (date.toDateString() === now.toDateString()) return clock;
  if (date.getTime() - now.getTime() < 6 * 86_400_000) return `${date.toLocaleDateString([], { weekday: "short" })} ${clock}`;
  return date.toLocaleDateString([], { day: "numeric", month: "short" });
}
