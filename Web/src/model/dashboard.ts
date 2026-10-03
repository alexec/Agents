// What a Dashboard means (074), as AgentsKitCore's DashboardModel says it for the window and the
// Remote. Dates are the wire's: seconds since 2001, so differences are seconds.
import type {
  DashboardOrder, DashboardOrderSection, DashboardSnapshot, DashboardSummary, DashboardUpdate, TileGood, TileLevel, TileView,
  WireDate,
} from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

/** DashboardModel.filesSentence (#127): the tiles and their trends are files in the project. */
export const filesSentence = "Tiles and their trends are files in .agents/dashboard/ in this project, which you may commit";

/** DashboardModel.historyFile (#127): where a number tile's trend is kept. */
export function historyFile(id: string): string {
  return `.agents/dashboard/history/${id}.jsonl`;
}

/** Past its own stale-after time, or never set on this host (FR-024). */
export function isStale(tile: TileView, now: number): boolean {
  if (!tile.tile) return true;
  // A page's value is its file, live: never stale (#159).
  if (tile.tile.type === "page") return false;
  if (tile.setAt === undefined) return true;
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

/** The tiles by section: as the order puts them (#147), then the ones it doesn't list in their
 *  files' sections, in made order. DashboardModel.sections. */
export function sections(snapshot: DashboardSnapshot, includeHidden: boolean): { title: string | null; tiles: TileView[] }[] {
  const shown = ordered(snapshot.tiles).filter((t) => includeHidden || !t.tile?.hidden);
  const byID = new Map(shown.map((t) => [t.id, t]));
  const out: { title: string | null; tiles: TileView[] }[] = [];
  const placed = new Set<string>();
  const add = (tile: TileView, title: string | null) => {
    const section = out.find((s) => s.title === title);
    if (section) section.tiles.push(tile);
    else out.push({ title, tiles: [tile] });
  };
  for (const section of cleaned(snapshot.order ?? { sections: [] }).sections) {
    for (const id of section.tiles) {
      const tile = byID.get(id);
      if (!tile || placed.has(id)) continue;
      placed.add(id);
      add(tile, section.title ?? null);
    }
  }
  for (const tile of shown) if (!placed.has(tile.id)) add(tile, tile.tile?.section ?? null);
  return out;
}

/** DashboardOrder.cleaned: each tile once, each heading once, no empty sections. */
export function cleaned(order: DashboardOrder, known?: Set<string>): DashboardOrder {
  const seen = new Set<string>();
  const out: DashboardOrderSection[] = [];
  for (const section of order.sections) {
    const title = section.title || undefined;
    const tiles = section.tiles.filter((id) => (!known || known.has(id)) && !seen.has(id) && (seen.add(id), true));
    const same = out.find((s) => (s.title ?? null) === (title ?? null));
    if (same) same.tiles.push(...tiles);
    else out.push(title === undefined ? { tiles } : { title, tiles });
  }
  return { sections: out.filter((s) => s.tiles.length > 0) };
}

/** The whole order as shown, hidden tiles included: what a drop or a Move item edits and sends. */
export function arrangement(snapshot: DashboardSnapshot): DashboardOrder {
  return { sections: sections(snapshot, true).map((s) => (s.title === null ? { tiles: s.tiles.map((t) => t.id) }
    : { title: s.title, tiles: s.tiles.map((t) => t.id) })) };
}

/** `ids` into `section`, before `before` or at its end. DashboardOrder.moving. */
export function moving(order: DashboardOrder, ids: string[], section: string | null, before?: string): DashboardOrder {
  const sections = order.sections.map((s) => ({ ...s, tiles: s.tiles.filter((id) => !ids.includes(id)) }));
  let target = sections.find((s) => (s.title ?? null) === section);
  if (!target) {
    target = section === null ? { tiles: [] } : { title: section, tiles: [] };
    sections.push(target);
  }
  const at = before !== undefined ? target.tiles.indexOf(before) : -1;
  target.tiles.splice(at < 0 ? target.tiles.length : at, 0, ...ids);
  return cleaned({ sections });
}

/** `ids` just after `after`, in its section. */
export function movingAfter(order: DashboardOrder, ids: string[], after: string): DashboardOrder {
  const section = order.sections.find((s) => s.tiles.includes(after));
  if (!section) return order;
  const rest = section.tiles.filter((id) => !ids.includes(id));
  return moving(order, ids, section.title ?? null, rest[rest.indexOf(after) + 1]);
}

/** The section headed `title` before the one headed `before`, or last when `before` is undefined. */
export function movingSection(order: DashboardOrder, title: string | null, before: string | null | undefined): DashboardOrder {
  const sections = [...order.sections];
  const from = sections.findIndex((s) => (s.title ?? null) === title);
  if (from < 0) return order;
  const [section] = sections.splice(from, 1);
  const at = before === undefined ? -1 : sections.findIndex((s) => (s.title ?? null) === before);
  sections.splice(at < 0 ? sections.length : at, 0, section!);
  return { sections };
}

/** Move Up (-1) or Move Down (+1) among the tiles shown; null at either end of the section. */
export function stepping(snapshot: DashboardSnapshot, id: string, step: number, includeHidden: boolean): DashboardOrder | null {
  const next = neighbour(sections(snapshot, includeHidden), id, step);
  if (next === null) return null;
  const order = arrangement(snapshot);
  if (step > 0) return movingAfter(order, [id], next);
  return moving(order, [id], order.sections.find((s) => s.tiles.includes(next))?.title ?? null, next);
}

export function neighbour(shown: { title: string | null; tiles: TileView[] }[], id: string, step: number): string | null {
  for (const section of shown) {
    const at = section.tiles.findIndex((t) => t.id === id);
    if (at >= 0) return section.tiles[at + step]?.id ?? null;
  }
  return null;
}

/** Tables and notes take the grid's width. */
export function isWide(tile: TileView): boolean {
  return tile.tile?.type === "table" || tile.tile?.type === "note" || tile.tile?.type === "page";
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

/** DashboardUpdate.cooldown (#146): Update now waits this long after the last start. */
export const updateCooldown = 5 * 60;

/** DashboardUpdate.readyAt: when Update now may start another, while that is still to come. */
export function updateReadyAt(update: DashboardUpdate, now: number): number | null {
  if (update.lastStartedAt === undefined) return null;
  const end = update.lastStartedAt + updateCooldown;
  return end > now ? end : null;
}

/** DashboardUpdate.canPress. */
export function canUpdate(update: DashboardUpdate, now: number): boolean {
  return !update.isRunning && update.blocked === undefined && updateReadyAt(update, now) === null;
}

function clock(at: number): string {
  return fromWireDate(at as WireDate).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
}

/** DashboardUpdate.line: what is going, why it can't, or how the last one went, in 24-hour times. */
export function updateLine(update: DashboardUpdate, now: number): string | null {
  if (update.isRunning) return `${update.name} is running`;
  if (update.blocked !== undefined) return `Update now can't start: ${update.blocked}`;
  if (update.lastStartedAt === undefined) return null;
  const sameDay = fromWireDate(update.lastStartedAt).toDateString() === fromWireDate(now as WireDate).toDateString();
  const when = sameDay ? clock(update.lastStartedAt)
    : fromWireDate(update.lastStartedAt).toLocaleDateString("en-GB", { day: "numeric", month: "short" }) + " " + clock(update.lastStartedAt);
  if (update.lastFailed) return `The last update, ${when}, did not finish`;
  const ready = updateReadyAt(update, now);
  return ready === null ? `Last update ${when}` : `Last update ${when}; again from ${clock(ready)}`;
}
