// The Plan section on an epic's Work page (#3268, spec 3265), as the window's WorkPlan: its children
// step by step (forge/plan), each with a mark, the PR and the sessions that work on it (from lineage,
// lineage/walk and lineage/cost) and its cost; a header with the lead, the children done and running,
// and the total cost; and the new-session form that Start lead fills in. A standing epic's plan
// (#3662) is its query's open issues in one list, with no end.
import type {
  AgentState, ForgeAddChildRequest, ForgeBlockedByRequest, ForgeItem, ForgePlan, ForgePlanChild, ForgePlanStep, ForgeStanding, ForgeStart,
  LineageCost, LineageCostNode, LineageCostRollup, LineageEstimate, LineageLink, LineageNode,
} from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { money } from "./limits";
import { timeWords } from "./time";
import { costWords, spent } from "./value";
import { shortAge, shortRef } from "./work";

/** A child's mark: closed; a lane runs or a PR is open; a question waits or a check failed; waiting
 * for its step; blocked by an open issue outside the plan. In the Work look (#4418) it is a glyph in
 * colour before line 2's words; the state icon says open or closed. */
export type PlanMark = "done" | "working" | "attention" | "waiting" | "blocked";
export const markWords: Record<PlanMark, string> = {
  done: "Done", working: "Working", attention: "Needs you", waiting: "Waiting", blocked: "Blocked outside the plan",
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
  if (child.item.state === "closed") return "done";
  const open = pr !== undefined && pr.outcome === undefined;
  if (states.includes("waitingOnUser") || (open && (pr.failedChecks ?? 0) > 0)) return "attention";
  if (states.some(holdsRuntime) || open) return "working";
  if ((child.blockedOutside ?? []).length > 0) return "blocked";
  return "waiting";
}

/** A child's line 2 after its number (#4418, epic.md note 7), as WorkPlan.lineWords: what works on it, by its mark.
 * "Working · “Work look: epic page”" (the lane's title), "Working · P#4411 open", "Needs you · its lane asks a
 * question", "Needs you · 1 failed check", "Waiting for #4329", "Blocked by #4100, outside the plan", "merged P#4390 ·
 * 6 h ago"; undefined for an open child with nothing on it. */
export function lineWords(child: ForgePlanChild, mark: PlanMark, pr: LineageCostNode | undefined, states: AgentState[],
  lane: string | undefined, plan: ForgePlan, now: number = Date.now()): string | undefined {
  const prRef = pr ? `P${shortRef(pr.node.ref)}` : undefined;
  switch (mark) {
    case "done": {
      if (!pr || !prRef || !pr.outcome) return undefined;
      const age = shortAge(Math.max(0, (now - fromWireDate(pr.lastAt).getTime()) / 1000));
      return `${pr.outcome} ${prRef} · ${age === "now" ? "now" : `${age} ago`}`;
    }
    case "attention": {
      if (states.includes("waitingOnUser")) return "Needs you · its lane asks a question";
      const failed = pr?.failedChecks ?? 0;
      return `Needs you · ${failed === 1 ? "1 failed check" : `${failed} failed checks`}`;
    }
    case "working":
      if (states.some(holdsRuntime) && lane) return `Working · “${lane}”`;
      return prRef ? `Working · ${prRef} open` : "Working";
    case "blocked":
      return blockedWords(child);
    case "waiting": {
      const open = new Set(plan.children.filter((c) => c.item.state !== "closed").map((c) => c.item.node.ref));
      const waits = child.blockedBy.filter((b) => open.has(b.ref));
      return waits.length === 0 ? undefined : `Waiting for ${waits.map((b) => shortRef(b.ref)).join(", ")}`;
    }
  }
}

/** A phone's line 2 (note 15): the words up to their first " · ", without ", outside the plan". */
export function phoneWords(words: string | undefined): string | undefined {
  if (words === undefined) return undefined;
  const head = words.split(" · ")[0] ?? words;
  return head.endsWith(", outside the plan") ? head.slice(0, -", outside the plan".length) : head;
}

/** The open issues outside the plan that block a child: "Blocked by #17, outside the plan"; undefined with none. */
export const blockedWords = (child: ForgePlanChild) => child.item.state !== "closed" && (child.blockedOutside ?? []).length > 0
  ? `Blocked by ${child.blockedOutside!.map((n) => shortRef(n.ref)).join(", ")}, outside the plan` : undefined;

/** Money per currency: "$4.70", "$4.70 + €1.00"; undefined with none. */
function moneyWords(cost: Record<string, number>): string | undefined {
  const priced = Object.entries(cost).filter(([, v]) => v > 0).sort(([a], [b]) => a.localeCompare(b));
  return priced.length === 0 ? undefined : priced.map(([currency, v]) => money(v, currency)).join(" + ");
}

/** An open child's estimate on its row, with no cost yet: "~$0.60", else "~2h 10m"; undefined with no figures. */
export function estimateWords(e: LineageEstimate): string | undefined {
  const cash = moneyWords(Object.fromEntries(Object.entries(e.cost ?? {}).map(([c, r]) => [c, r.median])));
  if (cash) return `~${cash}`;
  return e.workingSeconds ? `~${timeWords(e.workingSeconds.median)}` : undefined;
}

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

/** The header's figures (epic.md note 3): "4 of 9 done · 2 running · $3.09 spent · about $4.70 to go". To go is the
 * open children's estimates added up; it goes with none. */
export function progressWords(plan: ForgePlan, running: number, rollups: LineageCostRollup[], estimates: readonly LineageEstimate[] = []): string {
  const done = plan.children.filter((c) => c.item.state === "closed").length;
  const parts = [`${done} of ${plan.children.length} done`];
  if (running > 0) parts.push(`${running} running`);
  const total = sumCosts(rollups.map((r) => r.total));
  if (spent(total)) parts.push(`${costWords(total)} spent`);
  const open = new Set(plan.children.filter((c) => c.item.state !== "closed").map((c) => c.item.node.ref));
  const toGo: Record<string, number> = {};
  for (const e of estimates) {
    if (!open.has(e.node.ref)) continue;
    for (const [currency, r] of Object.entries(e.cost ?? {})) toGo[currency] = (toGo[currency] ?? 0) + r.median;
  }
  const cash = moneyWords(toGo);
  if (cash) parts.push(`about ${cash} to go`);
  return parts.join(" · ");
}

/** The shares of the plan's bar (note 3): done (purple), running (green); the rest is grey. */
export function planBar(plan: ForgePlan, running: number): { done: number; running: number } {
  const total = plan.children.length;
  if (total === 0) return { done: 0, running: 0 };
  const done = plan.children.filter((c) => c.item.state === "closed").length;
  return { done: done / total, running: Math.min(running, total - done) / total };
}

/** A step's band at its trailing end (note 5): "3 of 5 done"; a step that is all done adds what it cost, "1 of 1 done ·
 * $0.90". */
export function stepWords(step: ForgePlanStep, plan: ForgePlan, rollups: Readonly<Record<string, LineageCostRollup>>): string {
  const children = plan.children.filter((c) => c.step === step.step);
  const done = children.filter((c) => c.item.state === "closed").length;
  let words = `${done} of ${children.length} done`;
  if (done === children.length) {
    const total = sumCosts(children.flatMap((c) => rollups[c.item.node.ref] ? [rollups[c.item.node.ref]!.total] : []));
    if (spent(total)) words += ` · ${costWords(total)}`;
  }
  return words;
}

/** A step whose children are all closed starts folded (note 5). */
export function startsFolded(step: ForgePlanStep, plan: ForgePlan): boolean {
  const children = plan.children.filter((c) => c.step === step.step);
  return children.length > 0 && children.every((c) => c.item.state === "closed");
}

/** The rows a standing epic shows before "9 more" (note 18). */
export const standingShown = 10;

/** "9 more": the rows of a standing epic's list past the first ten; undefined with none. */
export const moreWords = (count: number) => count > standingShown ? `${count - standingShown} more` : undefined;

/** A child's priority: label, for a standing epic's row (note 18). */
export const priorityLabel = (item: ForgeItem) => item.labels.find((l) => l.name.toLowerCase().startsWith("priority:"));

/** The most issues forge/plan reads for a standing epic's query. */
const standingLimit = 100;

/** A standing epic's header figures (#3662, note 17), with no end: "14 open · 1 running · $6.40 spent". The daemon
 * reads at most 100 issues, so 100 is "100+ open"; a query with an error counts none. */
export function standingWords(plan: ForgePlan, running: number, rollups: LineageCostRollup[]): string {
  const parts: string[] = [];
  const open = plan.children.filter((c) => c.item.state !== "closed").length;
  if (!plan.standing?.error) parts.push(open >= standingLimit ? `${standingLimit}+ open` : `${open} open`);
  if (running > 0) parts.push(`${running} running`);
  const total = sumCosts(rollups.map((r) => r.total));
  if (spent(total)) parts.push(`${costWords(total)} spent`);
  return parts.join(" · ");
}

/** A standing epic's query in words (#3662): "Open issues labelled bug · no milestone · 1 lane at a time". */
export function queryWords(standing: ForgeStanding): string {
  let first = "Open issues";
  if (standing.labels.length > 0) first += ` labelled ${standing.labels.join(" and ")}`;
  if (standing.any.length > 0) first += `${standing.labels.length > 0 ? ", and " : " labelled "}${standing.any.join(" or ")}`;
  const parts = [first];
  if (standing.not.length > 0) parts.push(`not ${standing.not.join(" or ")}`);
  const milestone = standing.milestone ?? "";
  if (milestone.toLowerCase() === "none") parts.push("no milestone");
  else if (milestone.toLowerCase() === "any") parts.push("in a milestone");
  else if (milestone) parts.push(`milestone “${milestone}”`);
  if (standing.parent === "none") parts.push("no parent");
  parts.push(standing.lanes === 1 ? "1 lane at a time" : `${standing.lanes} lanes at a time`);
  return parts.join(" · ");
}

/** A standing epic's query after its labels, which show as chips (note 17): "· no milestone · 1 lane at a time",
 * "· or polish, competitor · not wontfix · 2 lanes at a time". */
export function queryRestWords(standing: ForgeStanding): string {
  const parts: string[] = [];
  if (standing.any.length > 0) parts.push(`${standing.labels.length > 0 ? "and " : ""}${standing.any.join(" or ")}`);
  // The words after the first part, the labels' (not, milestone, parent and lanes), as queryWords says them.
  parts.push(...queryWords(standing).split(" · ").slice(1));
  return parts.map((p) => `· ${p}`).join(" ");
}

const leadState: Record<AgentState, string> = {
  starting: "starting", running: "working", waitingOnUser: "needs you", finished: "waiting", stopped: "stopped",
  queued: "queued", archived: "archived",
};

/** The lead's state in words (note 4): working, needs you, waiting, stopped. */
export const leadWords = (state: AgentState) => leadState[state];

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
