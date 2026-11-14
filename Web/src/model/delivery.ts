// Reports ▸ Planning's Delivery row (#4555, epic #4551): a card a figure, from reports/value's delivery: the four
// DORA keys, DORA 2025's rework rate, flow efficiency, the approval wait and CI time to green, each over the 4 weeks
// to now with its weekly series and DORA 2024's band where one exists. The figures are a scope's, never a person's.
import type { LineageDelivery, LineageDeliveryFigure } from "../protocol/generated";
import { timeWords } from "./time";

type Unit = "seconds" | "share" | "perWeek";

export interface DeliveryCard {
  key: string;
  title: string;
  /** The 4-week figure in words, "—" when it is made from none. */
  value: string;
  /** What it is made from, and the second figure the card carries (p90, the share that waited). */
  detail: string;
  /** "Elite", "High", "Medium" or "Low"; absent for a figure DORA has no band for, or none. */
  band?: string | undefined;
  /** The weeks' values, oldest first; null for a week made from none. */
  weeks: (number | null)[];
}

/** timeWords up to 2 days, then days and hours: "51h 5m" reads as "2d 3h". */
export function spanWords(seconds: number): string {
  const hours = Math.round(seconds / 3600);
  if (hours < 48) return timeWords(seconds);
  const rest = hours % 24;
  return rest === 0 ? `${hours / 24}d` : `${Math.floor(hours / 24)}d ${rest}h`;
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

function words(v: number | undefined, unit: Unit): string {
  if (v === undefined) return "—";
  if (unit === "seconds") return spanWords(v);
  if (unit === "share") return `${Math.round(v * 100)}%`;
  const n = Math.round(v * 10) / 10;
  return `${n} a week`;
}

const bandWords: Record<string, string> = { elite: "Elite", high: "High", medium: "Medium", low: "Low" };

function card(key: string, title: string, f: LineageDeliveryFigure, unit: Unit, made: (n: number) => string, extra?: string): DeliveryCard {
  const parts = [made(f.count)];
  if (f.p90 !== undefined && unit === "seconds") parts.push(`p90 ${spanWords(f.p90)}`);
  if (extra) parts.push(extra);
  const band = f.band ? bandWords[f.band] ?? f.band : undefined;
  return { key, title, value: words(f.value, unit), detail: parts.join(" · "), band,
    weeks: f.weeks.map((w) => w.value ?? null) };
}

const prs = (n: number) => plural(n, "PR", "PRs");
const issues = (n: number) => plural(n, "issue", "issues");

/** A card a figure, in the order of the row: the four DORA keys, then rework, flow, the approval wait and CI. */
export function deliveryCards(d: LineageDelivery): DeliveryCard[] {
  const shareWaited = d.approvalShare.value === undefined ? undefined : `${Math.round(d.approvalShare.value * 100)}% of PRs waited`;
  const rounds = d.failedRounds.value === undefined ? undefined
    : `${Math.round(d.failedRounds.value * 10) / 10} failed ${d.failedRounds.value === 1 ? "round" : "rounds"} a PR`;
  return [
    card("leadTime", "Lead time for changes", d.leadTime, "seconds", (n) => `median of ${issues(n)}`),
    card("deploymentFrequency", "Deployment frequency", d.deploymentFrequency, "perWeek", (n) => plural(n, "release", "releases")),
    card("changeFailureRate", "Change failure rate", d.changeFailureRate, "share", (n) => `of ${plural(n, "merged PR", "merged PRs")}`),
    card("recoveryTime", "Failed deployment recovery", d.recoveryTime, "seconds", (n) => `median of ${plural(n, "recovery", "recoveries")}`),
    card("reworkRate", "Rework rate", d.reworkRate, "share", (n) => `of ${prs(n)}`),
    card("flowEfficiency", "Flow efficiency", d.flowEfficiency, "share", (n) => `median of ${issues(n)}`),
    card("approvalWait", "Approval wait", d.approvalWait, "seconds", (n) => `median of ${prs(n)}`, shareWaited),
    card("ciTimeToGreen", "CI time to green", d.ciTimeToGreen, "seconds", (n) => `median of ${prs(n)}`, rounds),
  ];
}

/** "alexec/agents" for github:repo:#alexec/agents, "eng" for linear:repo:#eng; an old form as it is. */
export function repoTitle(repo: string): string {
  const hash = repo.indexOf("#");
  return hash >= 0 ? repo.slice(hash + 1) : repo.replace(/^[a-z][a-z0-9-]*:(repo:)?/, "");
}

/** The sparkline's path in a box of width by height: a line through the weeks that have a value, broken at a week
 * with none; a lone point is a short tick. Empty when no week has one. */
export function sparkPath(weeks: readonly (number | null)[], width: number, height: number): string {
  const values = weeks.filter((v): v is number => v !== null);
  if (values.length === 0) return "";
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const step = weeks.length > 1 ? width / (weeks.length - 1) : 0;
  const y = (v: number) => (hi === lo ? height / 2 : height - ((v - lo) / (hi - lo)) * height);
  const round = (n: number) => Math.round(n * 10) / 10;
  let path = "";
  let open = false;
  weeks.forEach((v, i) => {
    if (v === null) { open = false; return; }
    const x = round(i * step);
    const at = round(y(v));
    const lone = !open && (i + 1 >= weeks.length || weeks[i + 1] === null);
    path += `${path ? " " : ""}${open ? "L" : "M"}${x} ${at}`;
    if (lone) path += ` L${round(x + 2 > width ? x - 2 : x + 2)} ${at}`;
    open = true;
  });
  return path;
}

export const deliveryNote = "The last 4 weeks, whatever the range; a line a week. Bands are DORA’s, from teams of people; agents merge many small PRs.";
export const noDelivery = "No pull request merged in the last 4 weeks, so there are no delivery figures yet.";
