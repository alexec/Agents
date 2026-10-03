// What a Dashboard means (074), as AgentsKitCore's DashboardModel says it for the window and the
// Remote. Dates are the wire's: seconds since 2001, so differences are seconds.
import type { DashboardSnapshot, DashboardSummary, TileGood, TileLevel, TileView } from "../protocol/generated";

/** DashboardModel.filesSentence (#127): the tiles and their trends are files in the project. */
export const filesSentence = "Tiles and their trends are files in .agents/dashboard/ in this project, which you may commit";

/** DashboardModel.historyFile (#127): where a number tile's trend is kept. */
export function historyFile(id: string): string {
  return `.agents/dashboard/history/${id}.jsonl`;
}

/** Past its own stale-after time, or never set on this host (FR-024). */
export function isStale(tile: TileView, now: number): boolean {
  if (!tile.tile || tile.setAt === undefined) return true;
  return now - tile.setAt > (tile.tile.stale_after_hours ?? 24) * 3600;
}

/** A stale status says nothing: a green light nobody confirmed stops saying all is well. */
export function shownLevel(tile: TileView, now: number): TileLevel | null {
  const status = tile.tile?.status;
  if (!status) return null;
  return isStale(tile, now) ? "unknown" : status.level;
}

export function ageWords(tile: TileView, now: number): string {
  if (tile.setAt === undefined) return "age unknown";
  const seconds = Math.max(0, now - tile.setAt);
  const hours = Math.floor(seconds / 3600), days = Math.floor(seconds / 86400);
  if (isStale(tile, now)) {
    if (days >= 1) return days === 1 ? "1 day old" : `${days} days old`;
    return hours <= 1 ? "1 hour old" : `${hours} hours old`;
  }
  return agoWords(seconds);
}

/** "just now", "12 min ago", "3 h ago", "2 days ago". */
export function agoWords(seconds: number): string {
  const minutes = Math.floor(seconds / 60), hours = Math.floor(seconds / 3600), days = Math.floor(seconds / 86400);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  if (hours < 24) return `${hours} h ago`;
  return days === 1 ? "1 day ago" : `${days} days ago`;
}

export function keeperNote(tile: TileView): string | null {
  switch (tile.keeper.state) {
    case "archived": return tile.keeper.kind === "workflow" ? "its workflow is archived" : "its agent is archived";
    case "retired": return "its agent is retired";
    default: return null;
  }
}

/** Against the last point at least a day old, or the first when none is. */
export function change(tile: TileView, now: number): number | null {
  const value = tile.tile?.number?.value;
  if (value === undefined || tile.points.length < 2) return null;
  const dayAgo = (tile.setAt ?? now) - 86400;
  const older = tile.points.filter((p) => p.at <= dayAgo);
  const base = older.length ? older[older.length - 1]! : tile.points[0]!;
  return value - base.value;
}

export function isGood(delta: number, good: TileGood | undefined): boolean | null {
  if (!good || delta === 0) return null;
  return (delta > 0) === (good === "up");
}

export function numberWords(value: number): string {
  return value.toLocaleString("en-US", { maximumFractionDigits: Number.isInteger(value) ? 0 : 2 });
}

export function changeWords(delta: number | null): string | null {
  if (delta === null || delta === 0) return null;
  return (delta > 0 ? "▲" : "▼") + numberWords(Math.abs(delta));
}

/** Made order, then id; a tile only a file knows of after those the host made. */
export function ordered(tiles: TileView[]): TileView[] {
  return [...tiles].sort((a, b) => {
    if (a.made !== undefined && b.made !== undefined && a.made !== b.made) return a.made - b.made;
    if (a.made !== undefined && b.made === undefined) return -1;
    if (a.made === undefined && b.made !== undefined) return 1;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
}

export function sections(snapshot: DashboardSnapshot, includeHidden: boolean): { title: string | null; tiles: TileView[] }[] {
  const out: { title: string | null; tiles: TileView[] }[] = [];
  for (const tile of ordered(snapshot.tiles)) {
    if (!includeHidden && tile.tile?.hidden) continue;
    const title = tile.tile?.section ?? null;
    const section = out.find((s) => s.title === title);
    if (section) section.tiles.push(tile);
    else out.push({ title, tiles: [tile] });
  }
  return out;
}

/** Tables and notes take the grid's width. */
export function isWide(tile: TileView): boolean {
  return tile.tile?.type === "table" || tile.tile?.type === "note";
}

/** The row's line: "8 tiles · 1 to watch · Open bugs 4" (the window's DashboardRow.detail). */
export function rowDetail(summary: DashboardSummary | undefined): string {
  if (!summary || summary.tiles === 0) return "No tiles yet";
  const count = summary.tiles === 1 ? "1 tile" : `${summary.tiles} tiles`;
  return summary.line ? `${count} · ${summary.line}` : count;
}

/** The sparkline's points, scaled into a box. */
export function sparkline(tile: TileView, width: number, height: number): string {
  const points = tile.points;
  if (points.length < 2) return "";
  const values = points.map((p) => p.value);
  const low = Math.min(...values), high = Math.max(...values);
  const start = points[0]!.at, span = Math.max(points[points.length - 1]!.at - start, 1);
  return points.map((p) => {
    const x = (width * (p.at - start)) / span;
    const y = high === low ? height / 2 : height - (height * (p.value - low)) / (high - low);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
}
