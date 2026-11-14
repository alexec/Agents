// Work ▸ Deploys (#5270, spec 5239-deploy-model board 4): every component in every environment. The columns are the
// environments in tier order (testing, then production), the rows the components, each cell the targets of that
// component there. A copy of AgentsKitCore's WorkDeploys, which the window draws.
import type { DeployComponent, DeployOnTarget, DeployTarget, DeployTargetNow, DeployVersion, EnvironmentTier, WireDate } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export interface DeployColumn { name: string; tier: EnvironmentTier }
export interface DeployRow { id: string; name: string; cells: DeployTargetNow[][] }
export interface DeployGrid { columns: DeployColumn[]; rows: DeployRow[] }

export const deploysTitle = "Deploys";
export const emptyTitle = "No deploys yet";
export const emptyLine = "A deploy shows here once a forge's job deploys, as GitHub's and GitLab's environments record it.";
export const noMachine = "No machine keeps deploys yet. Update Agents on a machine to see them.";
export const noLive = "Nothing live";
export const clickNote = "A click on a cell opens the deploy’s job; on a version, its release’s page.";

/** The order of the columns: the tiers before production, then production; other after staging. */
export function rank(tier: EnvironmentTier): number {
  switch (tier) {
    case "development": return 0;
    case "testing": return 1;
    case "staging": return 2;
    case "production": return 4;
    default: return 3;
  }
}

export const componentName = (c: DeployComponent): string => c.name ? c.name : c.id;

/** What tells a target apart: its component, its environment and its labels. */
export function targetKey(t: DeployTarget): string {
  const labels = Object.entries(t.labels ?? {}).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([k, v]) => `${k}=${v}`).join(",");
  return `${t.component.system}:${t.component.id}@${t.environment.name}/${labels}`;
}

/** The newest time a target says: its newest live deploy's since, or a next deploy's start. */
function newest(t: DeployTargetNow): number {
  const times = [...t.live.map((l) => l.since ?? l.deploy.finished), ...t.next.map((n) => n.deploy.started)]
    .flatMap((x) => x === undefined ? [] : [fromWireDate(x).getTime()]);
  return times.length ? Math.max(...times) : -Infinity;
}

/** Several machines' answers as one: a target two machines keep is the one whose news is newer; the first's on a tie. */
export function mergeTargets(answers: readonly (readonly DeployTargetNow[])[]): DeployTargetNow[] {
  const order: string[] = [];
  const byKey = new Map<string, DeployTargetNow>();
  for (const answer of answers) {
    for (const t of answer) {
      const k = targetKey(t.target);
      const had = byKey.get(k);
      if (!had) { order.push(k); byKey.set(k, t); } else if (newest(t) > newest(had)) byKey.set(k, t);
    }
  }
  return order.map((k) => byKey.get(k)!);
}

export function deployGrid(targets: readonly DeployTargetNow[]): DeployGrid {
  const tiers = new Map<string, EnvironmentTier>();
  for (const t of targets) if (!tiers.has(t.target.environment.name)) tiers.set(t.target.environment.name, t.target.environment.tier);
  const columns = [...tiers].map(([name, tier]) => ({ name, tier }))
    .sort((a, b) => rank(a.tier) - rank(b.tier) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const components = new Map<string, { name: string; targets: DeployTargetNow[] }>();
  for (const t of targets) {
    const id = `${t.target.component.system}:${t.target.component.id}`;
    const c = components.get(id) ?? { name: componentName(t.target.component), targets: [] };
    c.targets.push(t);
    components.set(id, c);
  }
  const rows = [...components].map(([id, c]) => ({
    id, name: c.name,
    cells: columns.map((col) => c.targets.filter((t) => t.target.environment.name === col.name)
      .sort((a, b) => labelsLine(a.target).localeCompare(labelsLine(b.target)))),
  })).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
  return { columns, rows };
}

/** A version as a cell says it: its name, else its commit's first 7, else its first artifact. */
export function versionWords(v: DeployVersion): string {
  if (v.name) return v.name;
  const commit = v.artifacts.find((a) => a.kind === "commit");
  if (commit) return commit.id.slice(0, 7);
  return v.artifacts[0]?.id ?? "?";
}

/** A share of the traffic, shown only when the target splits it: "90 %". */
export function shareWords(share: number | undefined): string | undefined {
  if (share === undefined || share >= 100) return undefined;
  return Number.isInteger(share) ? `${share} %` : `${share.toFixed(1)} %`;
}

/** The target's labels (region, cluster), as one line: "region eu · cluster b"; "" with none. */
export function labelsLine(t: DeployTarget): string {
  return Object.entries(t.labels ?? {}).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([k, v]) => `${k} ${v}`).join(" · ");
}

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "since 8 Nov, 10:51", a wire date in this device's time zone (or UTC, for the tests). */
export function sinceWords(wire: WireDate, utc = false): string {
  const d = fromWireDate(wire);
  const [day, month, h, m] = utc ? [d.getUTCDate(), d.getUTCMonth(), d.getUTCHours(), d.getUTCMinutes()]
    : [d.getDate(), d.getMonth(), d.getHours(), d.getMinutes()];
  return `since ${day} ${months[month]}, ${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/** "next: v0.20.0, waiting". */
export const nextWords = (n: DeployOnTarget): string => `next: ${versionWords(n.deploy.version)}, ${n.deploy.state === "waiting" ? "waiting" : "running"}`;

/** The tier's chip in a column's header: only production has one, as board 4 draws it. */
export const tierChip = (tier: EnvironmentTier): string | undefined => tier === "production" ? "production" : undefined;

/** The job a cell opens: the next deploy's, else the live one's. */
export function jobOf(t: DeployTargetNow): string | undefined {
  return t.next.at(-1)?.deploy.url ?? t.live[0]?.deploy.url;
}

/** What a screen reader says for a cell. */
export function cellLabel(component: string, environment: string, targets: readonly DeployTargetNow[], utc = false): string {
  if (targets.length === 0) return `${component} in ${environment}: none`;
  const parts = targets.map((t) => {
    const words: string[] = [];
    const labels = labelsLine(t.target);
    if (labels) words.push(labels);
    if (t.live.length === 0) words.push(noLive);
    for (const l of t.live) {
      let w = `${versionWords(l.deploy.version)} live`;
      const s = shareWords(l.share);
      if (s) w += ` at ${s}`;
      if (l.since !== undefined) w += ` ${sinceWords(l.since, utc)}`;
      if (l.deploy.rollback) w += ", a rollback";
      words.push(w);
    }
    words.push(...t.next.map(nextWords));
    return words.join(", ");
  });
  return `${component} in ${environment}: ${parts.join("; ")}`;
}
