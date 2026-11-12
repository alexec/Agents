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
export function oneDecimal(x: number): string {
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

/** A volume on a machine's page (#3626): "120.3 GB free of 500.0 GB (24%)", DiskSpace.freeWords. */
export function freeWords(alarm: DiskAlarm): string {
  return `${diskWords(alarm.reading.freeBytes)} free of ${diskWords(alarm.reading.totalBytes)} (${freePercent(alarm)}%)`;
}

/** A level as a machine's page says it, beside the volume: DiskSpace.levelWords. */
export function levelWords(level: DiskAlarm["level"]): string {
  return level === "critical" ? "Almost full" : level === "low" ? "Low" : "OK";
}

/** A low disk in the grey line under a machine's row (#3928): "Disk low: 24.7 GB free", DiskSpace.needWords. */
export function needWords(alarm: DiskAlarm): string {
  return `Disk ${levelWords(alarm.level).toLowerCase()}: ${diskWords(alarm.reading.freeBytes)} free`;
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

/** The disk a machine's page shows open (#3743): the worst; of equal levels, the one most of `folders` are on; then the
 * one with least free. DiskSpace.headline. */
export function headline(disks: readonly DiskAlarm[], folders: readonly string[]): DiskAlarm | undefined {
  const rank = { ok: 0, low: 1, critical: 2 } as const;
  const on = new Map<string, number>();
  for (const folder of folders) {
    const mount = mountOf(folder, disks);
    if (mount !== undefined) on.set(mount, (on.get(mount) ?? 0) + 1);
  }
  let best: DiskAlarm | undefined;
  for (const disk of disks) {
    if (!best) { best = disk; continue; }
    const by = rank[disk.level] - rank[best.level]
      || (on.get(disk.reading.mount) ?? 0) - (on.get(best.reading.mount) ?? 0)
      || best.reading.freeBytes - disk.reading.freeBytes;
    if (by > 0) best = disk;
  }
  return best;
}

/** The mount a path is on: the longest of the disks' mounts that holds it. */
function mountOf(path: string, disks: readonly DiskAlarm[]): string | undefined {
  return disks.map((d) => d.reading.mount)
    .filter((m) => m === "/" || path === m || path.startsWith(m.endsWith("/") ? m : `${m}/`))
    .reduce<string | undefined>((a, m) => (a === undefined || m.length > a.length ? m : a), undefined);
}

/** A disk in a machine's summary (#3743): "Disk 48.0 GB free", and its level when it is not OK. DiskSpace.summaryWords. */
export function summaryWords(disk: DiskAlarm): string {
  const free = `Disk ${diskWords(disk.reading.freeBytes)} free`;
  return disk.level === "ok" ? free : `${free} · ${levelWords(disk.level)}`;
}
