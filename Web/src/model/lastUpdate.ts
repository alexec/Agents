// How fresh a page's data is (#5139, #5141): "Last update 5 min ago", the same words as
// AgentsKitCore's LastUpdate on the Mac window and the Remote. The rule is in
// docs/reference/design-system.md, "How fresh the data is". The time is when this page read
// the data, not the time of the content and not the time a link went down.

type Age = { kind: "justNow" } | { kind: "minutes"; n: number } | { kind: "hours"; n: number } | { kind: "yesterday" } | { kind: "day" };

function ageOf(at: number, now: number): Age {
  // A read a little ahead of this clock (another machine's time) is just now.
  const seconds = Math.max(0, (now - at) / 1000);
  if (seconds < 60) return { kind: "justNow" };
  if (seconds < 3600) return { kind: "minutes", n: Math.floor(seconds / 60) };
  if (seconds < 24 * 3600) return { kind: "hours", n: Math.floor(seconds / 3600) };
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  if (new Date(at).toDateString() === yesterday.toDateString()) return { kind: "yesterday" };
  return { kind: "day" };
}

/** "3 Nov" in the person's own order and time zone, with the year when it is not this one. */
function day(at: number, now: number, locale?: string): string {
  const year = new Date(at).getFullYear() !== new Date(now).getFullYear();
  return new Date(at).toLocaleDateString(locale, { day: "numeric", month: "short", ...(year ? { year: "numeric" } : {}) });
}

/** The age alone: "just now", "5 min ago", "2 h ago", "yesterday", "3 Nov". */
export function lastUpdateAge(at: number, now: number = Date.now(), locale?: string): string {
  const age = ageOf(at, now);
  switch (age.kind) {
    case "justNow": return "just now";
    case "minutes": return `${age.n} min ago`;
    case "hours": return `${age.n} h ago`;
    case "yesterday": return "yesterday";
    case "day": return day(at, now, locale);
  }
}

/** "Last update 5 min ago". */
export function lastUpdateLine(at: number, now: number = Date.now(), locale?: string): string {
  return `Last update ${lastUpdateAge(at, now, locale)}`;
}

/** What a screen reader says: "Last update 5 minutes ago". */
export function lastUpdateSpoken(at: number, now: number = Date.now(), locale?: string): string {
  const age = ageOf(at, now);
  switch (age.kind) {
    case "minutes": return `Last update ${age.n === 1 ? "1 minute" : `${age.n} minutes`} ago`;
    case "hours": return `Last update ${age.n === 1 ? "1 hour" : `${age.n} hours`} ago`;
    default: return lastUpdateLine(at, now, locale);
  }
}

/** When the words can next change: every 10 s for the first minute, then on each minute of the age. */
export function nextChange(at: number, now: number): number {
  const age = now - at;
  if (age < 60_000) return at + (Math.floor(Math.max(age, 0) / 10_000) + 1) * 10_000;
  return at + (Math.floor(age / 60_000) + 1) * 60_000;
}

/**
 * The time of the last read that the page shows (#5141): the last word on the link while it is
 * down, or, before the control plane answered, the oldest machine drawn from this device's copy.
 */
export function pageReadAt(state: { kind: string; heardAt?: number }, copyAt: number | undefined): number | undefined {
  if (state.kind === "down") return state.heardAt ?? copyAt;
  if (state.kind === "connecting" || state.kind === "loading") return copyAt;
  return undefined;
}
