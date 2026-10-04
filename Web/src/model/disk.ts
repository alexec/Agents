// A volume low on space (#195, #196), as AgentsKitCore's DiskAlarm.line says it, so the page's
// strip says what the window's and the Remote's say.
import type { DiskAlarm, DiskWorktree } from "../protocol/generated";

const gigabyte = 1_000_000_000;

/** "12.3 GB", "850 MB": DiskSpace.words. */
export function diskWords(bytes: number): string {
  if (bytes >= gigabyte) return `${oneDecimal(bytes / gigabyte)} GB`;
  return `${Math.floor(Math.max(0, bytes) / 1_000_000)} MB`;
}

/**
 * As Swift's "%.1f": toFixed takes an exact tie (a quarter, 12.25) up, printf to the even
 * tenth. Only a whole number of quarters can be an exact tie.
 */
function oneDecimal(x: number): string {
  const quarters = x * 4;
  if (!Number.isInteger(quarters) || quarters % 2 === 0) return x.toFixed(1);
  const tenths = Math.floor(x * 10);
  return ((tenths % 2 === 0 ? tenths : tenths + 1) / 10).toFixed(1);
}

/** Whole percent free, rounded down: DiskReading.freePercent. */
export function freePercent(alarm: DiskAlarm): number {
  const { freeBytes, totalBytes } = alarm.reading;
  return totalBytes > 0 ? Math.floor((freeBytes / totalBytes) * 100) : 0;
}

/** "a 12.3 GB, b over 8.0 GB": DiskSpace.worktreeWords. */
export function worktreeWords(worktrees: readonly DiskWorktree[]): string {
  return worktrees.map((w) => `${w.name} ${w.partial ? "over " : ""}${diskWords(w.bytes)}`).join(", ");
}

/** One line for the strip: DiskAlarm.line. */
export function diskLine(alarm: DiskAlarm): string {
  const free = diskWords(alarm.reading.freeBytes);
  const what = alarm.level === "critical"
    ? `${alarm.reading.volume} is almost full: ${free} free. Agents’ commands will start failing.`
    : `${alarm.reading.volume} is running low: ${free} free (${freePercent(alarm)}%).`;
  if (alarm.worktrees.length === 0) return what;
  return `${what} Largest worktrees: ${worktreeWords(alarm.worktrees.slice(0, 3))}.`;
}
