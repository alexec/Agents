// The Plan section on an epic's Work page (#3268, spec 3265), as the window's WorkPlan: its children
// step by step (forge/plan), each with a mark, the PR and the sessions that work on it (from lineage,
// lineage/walk and lineage/cost) and its cost; a header with the lead, the children done and running,
// and the total cost; and the new-session form that Start lead fills in.
import type {
  AgentState, ForgeAddChildRequest, ForgeBlockedByRequest, ForgeItem, ForgeLead, ForgePlan, ForgePlanChild, ForgePlanStep, ForgeStart,
  LineageCost, LineageCostNode, LineageCostRollup, LineageLink, LineageNode,
} from "../protocol/generated";
import { costWords, spent } from "./value";
import { shortRef } from "./work";

/** A child's mark: closed; a lane runs or a PR is open; a question waits or a check failed; waiting
 * for its step; blocked by an open issue outside the plan. */
export type PlanMark = "✓" | "◐" | "⚠" | "○" | "⊘";
export const markWords: Record<PlanMark, string> = {
  "✓": "Done", "◐": "Working", "⚠": "Needs you", "○": "Waiting", "⊘": "Blocked outside the plan",
};

const holdsRuntime = (s: AgentState) => s === "starting" || s === "running" || s === "waitingOnUser";

/** Whether an issue's page shows a plan: it has sub-issues, or it is labelled epic. */
export const hasPlan = (item: ForgeItem) => item.node.kind === "issue" && ((item.progress?.total ?? 0) > 0 || item.level === "epic");

/** The pull request that works on a child: an open one first, else the newest. */
export function planPR(rollup: LineageCostRollup | undefined): LineageCostNode | undefined {
  const prs = (rollup?.parts ?? []).filter((p) => p.node.kind === "pr");
  const newest = (list: LineageCostNode[]) => list.reduce<LineageCostNode | undefined>((a, b) => !a || b.lastAt > a.lastAt ? b : a, undefined);
  return newest(prs.filter((p) => p.outcome === undefined)) ?? newest(prs);
}

/** The sessions that work on a child, by id, each once: those linked to it (lineage/walk), at once,
 * and those that banked a turn on it or its pull requests (lineage/cost's parts). */
export function planSessions(child: LineageNode, links: readonly LineageLink[], rollup: LineageCostRollup | undefined): string[] {
  const refs: string[] = [];
  for (const l of links) {
    if (l.to.ref === child.ref && l.to.kind === child.kind && l.from.kind === "session") refs.push(l.from.ref);
    if (l.from.ref === child.ref && l.from.kind === child.kind && l.to.kind === "session") refs.push(l.to.ref);
  }
  for (const part of rollup?.parts ?? []) refs.push(...part.sessions ?? []);
  const seen: string[] = [];
  for (const ref of refs) {
    const id = ref.slice("session:".length).toUpperCase();
    if (id && !seen.includes(id)) seen.push(id);
  }
  return seen;
}

/** A child's mark, from its state, its PR and the states of its sessions this page knows. */
export function planMark(child: ForgePlanChild, pr: LineageCostNode | undefined, states: AgentState[]): PlanMark {
  if (child.item.state === "closed") return "✓";
  const open = pr !== undefined && pr.outcome === undefined;
  if (states.includes("waitingOnUser") || (open && (pr.failedChecks ?? 0) > 0)) return "⚠";
  if (states.some(holdsRuntime) || open) return "◐";
  if ((child.blockedOutside ?? []).length > 0) return "⊘";
  return "○";
}

/** What works on a child: "● lane running · PR #3266 open"; undefined with nothing. */
export function planWorkWords(pr: LineageCostNode | undefined, states: AgentState[]): string | undefined {
  const parts: string[] = [];
  if (states.includes("waitingOnUser")) parts.push("● lane needs you");
  else if (states.some(holdsRuntime)) parts.push("● lane running");
  if (pr) {
    let words = `PR ${shortRef(pr.node.ref)} ${pr.outcome ?? "open"}`;
    const failed = pr.failedChecks ?? 0;
    if (pr.outcome === undefined && failed > 0) words += failed === 1 ? " · 1 failed check" : ` · ${failed} failed checks`;
    parts.push(words);
  }
  return parts.length === 0 ? undefined : parts.join(" · ");
}

/** The open issues outside the plan that block a child: "blocked by #17"; undefined with none. */
export const blockedWords = (child: ForgePlanChild) => child.item.state !== "closed" && (child.blockedOutside ?? []).length > 0
  ? `blocked by ${child.blockedOutside!.map((n) => shortRef(n.ref)).join(", ")}` : undefined;

/** A child's cost, or undefined with nothing spent. */
export const planCostWords = (rollup: LineageCostRollup | undefined) => rollup && spent(rollup.total) ? costWords(rollup.total) : undefined;

/** A step's title: "Step 4 · waits for #3088" while a child of an earlier step is open. */
export function stepTitle(step: ForgePlanStep, plan: ForgePlan): string {
  const open = new Set(plan.children.filter((c) => c.item.state !== "closed").map((c) => c.item.node.ref));
  const waits: LineageNode[] = [];
  for (const child of plan.children) {
    if (child.step !== step.step || child.item.state === "closed") continue;
    for (const b of child.blockedBy) if (open.has(b.ref) && !waits.some((w) => w.ref === b.ref)) waits.push(b);
  }
  return waits.length === 0 ? `Step ${step.step}` : `Step ${step.step} · waits for ${waits.map((w) => shortRef(w.ref)).join(", ")}`;
}

/** The costs added up, per currency. */
export function sumCosts(costs: LineageCost[]): LineageCost {
  const out: LineageCost = { cost: {}, inputTokens: 0, outputTokens: 0, turns: 0, workingSeconds: 0, waitingSeconds: 0 };
  for (const c of costs) {
    for (const [currency, v] of Object.entries(c.cost)) out.cost[currency] = (out.cost[currency] ?? 0) + v;
    out.inputTokens += c.inputTokens;
    out.outputTokens += c.outputTokens;
    out.turns += c.turns;
    out.workingSeconds += c.workingSeconds;
    out.waitingSeconds += c.waitingSeconds;
  }
  return out;
}

/** The header's figures: "5/7 done · 1 running · $41.20". */
export function progressWords(plan: ForgePlan, running: number, rollups: LineageCostRollup[]): string {
  const done = plan.children.filter((c) => c.item.state === "closed").length;
  const parts = [`${done}/${plan.children.length} done`];
  if (running > 0) parts.push(`${running} running`);
  const total = sumCosts(rollups.map((r) => r.total));
  if (spent(total)) parts.push(costWords(total));
  return parts.join(" · ");
}

const leadState: Record<AgentState, string> = {
  starting: "starting", running: "working", waitingOnUser: "needs you", finished: "waiting", stopped: "stopped",
  queued: "queued", archived: "archived",
};

/** The lead in the header: "Lead: “Work pages lead” (working)". */
export const leadWords = (lead: ForgeLead, title: string | undefined) =>
  `Lead: “${title ?? lead.title ?? "A session"}” (${leadState[lead.state]})`;

/** Start lead's form (the lead skill's "Starting a lead"): the issue's own first line, the skill and
 * the epic's address, its labels and lead, and no worktree. */
export function leadStart(start: ForgeStart, url: string | undefined): ForgeStart {
  const first = start.prompt.split("\n", 1)[0] ?? start.prompt;
  const skill = "Lead this epic with the `lead` skill (`.agents/skills/lead/SKILL.md`)";
  return {
    prompt: `${first}\n\n${skill}${url ? `: ${url}` : "."}`,
    labels: [...start.labels, ...start.labels.includes("lead") ? [] : ["lead"]],
  };
}

// Changing the plan (#3271).

/** The levels a new child can have, as Add child's menu offers them; "" is none. */
export const childLevels = ["story", "task", "spike", "bug", ""];

/** Whether Add child's words name an issue that is there, not a new one's title: #12,
 * owner/repo#12, an issue's URL, or a key such as ENG-4. */
export const namesIssue = (words: string) =>
  /^([\w.-]+\/[\w.-]+)?#[0-9]+$|^https?:\/\/\S+$|^[A-Za-z][A-Za-z0-9]{0,9}-[0-9]+$/.test(words.trim());

/** Add child's request: the issue the words name, or a new child with them as its title. */
export function addChildRequest(epic: LineageNode, words: string, level: string): ForgeAddChildRequest {
  const text = words.trim();
  if (namesIssue(text)) return { node: epic, issue: text };
  return { node: epic, title: text, ...level ? { level } : {} };
}

/** The children a child can be blocked by: the plan's others, each with whether it is now. */
export const blockerChoices = (child: ForgePlanChild, plan: ForgePlan) => plan.children
  .filter((c) => c.item.node.ref !== child.item.node.ref)
  .map((c) => ({ child: c, on: child.blockedBy.some((b) => b.ref === c.item.node.ref) }));

/** Blocked by's request: the other child added as a blocker, or taken off. */
export const blockedByRequest = (child: ForgePlanChild, blocker: LineageNode, on: boolean): ForgeBlockedByRequest =>
  on ? { node: child.item.node, add: [blocker] } : { node: child.item.node, remove: [blocker] };
