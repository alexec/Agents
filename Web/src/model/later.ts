// Later on a request to the person (#4236, epic #4232), as the window's NeedRequest.Later
// (Packages/AgentsKit/Sources/AgentsKitCore/Model/NeedRequest.swift): In 1 Hour, 4 Hours, 8 Hours,
// 1 Day and At My Mac (Alex, 2026-11-10: no Pick a Time). A deferred request stays open, and its
// sessions still wait, but it leaves Needs You's rows and counts for its folded Later group until
// it comes back; Bring Back Now does that at once.
import type { Request as PersonRequest, RequestDeferral, RequestsDefer } from "../protocol/generated";
import { fromWireDate, toWireDate } from "../protocol/dates";

export type Later = "hour" | "fourHours" | "eightHours" | "day" | "atMac";

/** In the order the row's menu lists them. */
export const laters: readonly Later[] = ["hour", "fourHours", "eightHours", "day", "atMac"];

/** The words on the row's menu: the window's Later ▸ In 1 Hour, flat, as the page's menus have no submenu. */
export const laterWords: Record<Later, string> = {
  hour: "Later in 1 Hour", fourHours: "Later in 4 Hours", eightHours: "Later in 8 Hours", day: "Later in 1 Day",
  atMac: "Later at My Mac",
};

const laterHours: Record<Later, number | null> = { hour: 1, fourHours: 4, eightHours: 8, day: 24, atMac: null };

/** What `requests/defer` takes for it, from `now`. */
export function deferParams(id: string, later: Later, now = new Date()): RequestsDefer {
  const hours = laterHours[later];
  return hours === null ? { id: id as never, atMac: true }
    : { id: id as never, until: toWireDate(new Date(now.getTime() + hours * 3_600_000)) };
}

export function isDeferred(request: PersonRequest): boolean {
  return request.deferred !== undefined && request.deferred !== null;
}

function sameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/**
 * When it comes back, as its row in Later says it, as `Deferral.back`: "Back at 18:00", "Back tomorrow
 * at 09:00", "Back on Thu, 12 Nov at 09:00", "At my Mac", or a time "or at my Mac".
 */
export function backWords(deferred: RequestDeferral, now = new Date(), locale?: string): string {
  if (deferred.until === undefined) return "At my Mac";
  const until = fromWireDate(deferred.until);
  const time = until.toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit" });
  const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
  const day = sameDay(until, now) ? `at ${time}`
    : sameDay(until, tomorrow) ? `tomorrow at ${time}`
    : `on ${until.toLocaleDateString(locale, { weekday: "short", day: "numeric", month: "short" })} at ${time}`;
  return [`Back ${day}`, deferred.atMac ? "at my Mac" : undefined].filter(Boolean).join(" or ");
}

/** Later's rows in the order they come back: the soonest first, At my Mac alone last, then the oldest asked. */
export function byBack(a: PersonRequest, b: PersonRequest): number {
  const at = (r: PersonRequest) => r.deferred?.until ?? Number.POSITIVE_INFINITY;
  return at(a) - at(b) || a.askedAt - b.askedAt;
}
