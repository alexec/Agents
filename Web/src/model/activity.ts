// The time in a session row's corner (#341) and the line at a quiet chat's foot (#1564):
// ActivityWords (Model/ActivityWords.swift), ported by hand and held to Fixtures/web/activity/.

/** "5m", "3h", "2d": when it last did anything, in the corner of the row. */
export function shortAgo(date: Date, now = new Date()): string {
  const minutes = Math.max(0, Math.floor((now.getTime() - date.getTime()) / 60_000));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

const quietMinutes = 5;
export const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** One format per time zone ("" for the reader's), made once (#1850). */
const partFormats = new Map<string, Intl.DateTimeFormat>();

/** The year, month, day, hour and minute of `date` where the reader is (or in `timeZone`). */
export function parts(date: Date, timeZone?: string): { year: number; month: number; day: number; hour: number; minute: number } {
  const made: Record<string, number> = {};
  let format = partFormats.get(timeZone ?? "");
  if (!format) {
    format = new Intl.DateTimeFormat("en-GB", {
      timeZone, year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", hourCycle: "h23",
    });
    partFormats.set(timeZone ?? "", format);
  }
  for (const part of format.formatToParts(date)) {
    if (part.type !== "literal") made[part.type] = Number(part.value);
  }
  return { year: made.year!, month: made.month!, day: made.day!, hour: made.hour!, minute: made.minute! };
}

/** Whole minutes as a time ago, in the largest unit: "5 minutes ago", "1 hour ago", "3 days ago". */
function ago(minutes: number): string {
  const hours = Math.floor(minutes / 60);
  const [count, unit] = hours < 1 ? [minutes, "minute"] : hours < 24 ? [hours, "hour"] : [Math.floor(hours / 24), "day"];
  return count === 1 ? `1 ${unit} ago` : `${count} ${unit}s ago`;
}

/**
 * How long a chat has been quiet and how old it is, at the foot of its transcript (#1564): "Last
 * activity 12 minutes ago · started 3 hours ago". Null under five minutes. ActivityWords.quiet,
 * held to Fixtures/web/activity/quiet.json.
 */
export function quietLine(date: Date, startedAt: Date, now = new Date()): string | null {
  const minutes = Math.floor((now.getTime() - date.getTime()) / 60_000);
  if (minutes < quietMinutes) return null;
  // Never younger than its quiet: a host's clock can put the start a little late.
  const age = Math.max(minutes, Math.floor((now.getTime() - startedAt.getTime()) / 60_000));
  return `Last activity ${ago(minutes)} · started ${ago(age)}`;
}
