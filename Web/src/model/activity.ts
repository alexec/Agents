// The time in a session row's corner (#341): ActivityWords.short (Model/ActivityWords.swift),
// ported by hand and held to Fixtures/web/activity/short.json.

/** "5m", "3h", "2d": when it last did anything, in the corner of the row. */
export function shortAgo(date: Date, now = new Date()): string {
  const minutes = Math.max(0, Math.floor((now.getTime() - date.getTime()) / 60_000));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}
