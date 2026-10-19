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
const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** The year, month, day, hour and minute of `date` where the reader is (or in `timeZone`). */
function parts(date: Date, timeZone?: string): { year: number; month: number; day: number; hour: number; minute: number } {
  const made: Record<string, number> = {};
  for (const part of new Intl.DateTimeFormat("en-GB", {
    timeZone, year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", hourCycle: "h23",
  }).formatToParts(date)) {
    if (part.type !== "literal") made[part.type] = Number(part.value);
  }
  return { year: made.year!, month: made.month!, day: made.day!, hour: made.hour!, minute: made.minute! };
}

/**
 * How long a chat has been quiet, at the foot of its transcript (#1564): "Last activity 12 minutes
 * ago · 14:32". Null under five minutes. ActivityWords.quiet, held to Fixtures/web/activity/quiet.json.
 */
export function quietLine(date: Date, now = new Date(), timeZone?: string): string | null {
  const minutes = Math.floor((now.getTime() - date.getTime()) / 60_000);
  if (minutes < quietMinutes) return null;
  const at = parts(date, timeZone);
  const time = `${String(at.hour).padStart(2, "0")}:${String(at.minute).padStart(2, "0")}`;
  const hours = Math.floor(minutes / 60);
  let when: string;
  if (hours < 1) when = `${minutes} minutes ago`;
  else if (hours < 24) when = hours === 1 ? "1 hour ago" : `${hours} hours ago`;
  else {
    const today = parts(now, timeZone);
    const days = Math.round((Date.UTC(today.year, today.month - 1, today.day) - Date.UTC(at.year, at.month - 1, at.day)) / 86_400_000);
    const day = `${at.day} ${months[at.month - 1]}`;
    when = days === 1 ? "yesterday" : at.year === today.year ? day : `${day} ${at.year}`;
  }
  return `Last activity ${when} · ${time}`;
}
