// What a folder's Archived Sessions and Archived Workflows pages show (#4448, #4451): the day groups,
// the time on a row, the footer and the page's state. The web's copy of AgentsKit's ArchivedPage,
// which the Mac's window and the Remote draw: never "none" until the host has said so (#664), and
// never a capped page passed off as the whole archive.
import type { Agent } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

/** How many archived sessions a page holds at first, and how many more Load more asks for (#170). */
export const pageSize = 50;

/**
 * What the page draws in place of, or over, its rows: placeholder rows while the host is asked; the
 * strip alone when it did not answer and nothing was read; empty; a filter that matched none; or the
 * rows, `stale` when its machine is not answering, so they are what was last read, dimmed under the strip.
 */
export type ArchivedState =
  | { kind: "loading" } | { kind: "hostSilent" } | { kind: "empty" } | { kind: "noMatch" }
  | { kind: "rows"; stale: boolean };

/** `held` is the rows the page holds after its filter; `answered` is undefined while the ask is on its way. */
export function archivedState(held: number, filtering: boolean, answered: boolean | undefined, hostOffline: boolean): ArchivedState {
  if (held > 0) return { kind: "rows", stale: hostOffline || answered === false };
  if (hostOffline || answered === false) return { kind: "hostSilent" };
  if (answered === undefined) return { kind: "loading" };
  return { kind: filtering ? "noMatch" : "empty" };
}

/** The strip over what was last read, and alone when nothing was. */
export const staleStrip = "Its machine isn’t answering. Showing what was last read.";

/**
 * The time for the strip's "Last update" line (#5143): when the rows were last live with their host
 * (the time it, or the link to it, went), else when the page's own ask was last answered.
 */
export function readAt(liveUntil: number | undefined, answeredAt: number | undefined): number | undefined {
  return liveUntil ?? answeredAt;
}
export const loadingMore = "Loading more…";

export const sessionsWords = {
  title: "Archived Sessions",
  filter: "Filter archived sessions",
  emptyTitle: "No Archived Sessions",
  emptyLine: "Sessions you archive in Agents show here.",
  noMatch: "No archived sessions match",
} as const;

export const workflowsWords = {
  title: "Archived Workflows",
  filter: "Filter archived workflows",
  emptyTitle: "No Archived Workflows",
  emptyLine: "Workflows you archive in Agents show here.",
  noMatch: "No archived workflows match",
} as const;

/** "128 archived sessions", the sidebar row's tooltip and the whole footer. */
export function sessionCount(count: number): string {
  return count === 1 ? "1 archived session" : `${count} archived sessions`;
}

export function workflowCount(count: number): string {
  return count === 1 ? "1 archived workflow" : `${count} archived workflows`;
}

/** The footer's words, before Load more: "50 of 128 archived sessions" while the host has more,
 *  "128 archived sessions" with every one held. */
export function footer(shown: number, total: number): string {
  return total > shown ? `${shown} of ${sessionCount(total)}` : sessionCount(shown);
}

/** Whether the footer offers Load more. */
export function hasMore(shown: number, total: number): boolean {
  return total > shown;
}

/** The limit Load more asks the host for: the next page after what is held. */
export function nextLimit(held: number): number {
  return held + pageSize;
}

/** When a session was archived, or its last activity for a record from before archivedAt (#2153). */
export function archivedOrder(agent: Agent): Date {
  return fromWireDate(agent.archivedAt ?? agent.lastActivityAt);
}

/** One day's rows, under its heading. */
export interface ArchivedDay {
  /** The day's start, in ms. */
  id: number;
  title: string;
  isToday: boolean;
  agents: Agent[];
}

function startOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function sameDay(a: Date, b: Date): boolean {
  return startOfDay(a).getTime() === startOfDay(b).getTime();
}

/** The sessions in a day each, by when each was archived. In the order given, newest archived first as
 *  the host lists them (#2153): no re-sort. */
export function days(agents: readonly Agent[], now = new Date()): ArchivedDay[] {
  const out: ArchivedDay[] = [];
  for (const agent of agents) {
    const start = startOfDay(archivedOrder(agent));
    const day = out.find((d) => d.id === start.getTime());
    if (day) day.agents.push(agent);
    else out.push({ id: start.getTime(), title: dayTitle(start, now), isToday: sameDay(start, now), agents: [agent] });
  }
  return out;
}

/** "Today", "Yesterday", then "Friday 7 November", with the year when it is not this year. */
export function dayTitle(date: Date, now = new Date()): string {
  if (sameDay(date, now)) return "Today";
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
  if (sameDay(date, yesterday)) return "Yesterday";
  const weekday = date.toLocaleDateString("en-GB", { weekday: "long" });
  const month = date.toLocaleDateString("en-GB", { month: "long" });
  const year = date.getFullYear() === now.getFullYear() ? "" : ` ${date.getFullYear()}`;
  return `${weekday} ${date.getDate()} ${month}${year}`;
}

/** A row's time, when it was archived: "2 h ago" (or "12 min ago", "now") today, the clock time
 *  ("18:40") on any other day. */
export function archivedTime(date: Date, now = new Date()): string {
  if (sameDay(date, now)) {
    const minutes = Math.max(0, Math.floor((now.getTime() - date.getTime()) / 60_000));
    if (minutes < 1) return "now";
    if (minutes < 60) return `${minutes} min ago`;
    return `${Math.floor(minutes / 60)} h ago`;
  }
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}
