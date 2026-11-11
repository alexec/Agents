// Work ▸ Features (#3269, spec 3265), as the window's WorkFeatures: each feature:<name> label
// (forge/features) with its epic counts, in the groups of FeatureGroup (#4115); opened, its open epics, each with its progress and its
// lead, and its loose issues (the open issues with the label and no parent epic).
import type { Agent, AgentState, ForgeFeature, ForgeItem, ForgePlan, LineageNode } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { shortAge, shortRef } from "./work";

/** A feature's name as a title: work is Work. */
export const featureTitle = (name: string) => name.charAt(0).toUpperCase() + name.slice(1);

/** A feature's counts: "3 epics · 2 open", and "· 4 open issues" when it has open issues that are
 * not epics (#3741). */
export function featureCountWords(f: ForgeFeature): string {
  const epics = `${f.epics} ${f.epics === 1 ? "epic" : "epics"} · ${f.open} open`;
  return f.issues ? `${epics} · ${f.issues} open ${f.issues === 1 ? "issue" : "issues"}` : epics;
}

/** A feature with no open epic and no open issue (#3741). A daemon that does not count the issues
 * says nothing, so none of its features is finished. */
export const isFinished = (f: ForgeFeature) => f.open === 0 && f.issues === 0;

/** The groups of the list, from the top (#4115): each feature is in the first one it matches. Needs
 * you: a session on its work waits for Alex, a pull request waits for Alex's approval, or an issue is
 * labelled alex-todo. In flight: a session that is not archived is labelled with one of its open
 * issues or epics. Idle: open work and no session on it. Finished: no open epic and no open issue (#3741). */
export type FeatureGroup = "needsYou" | "inFlight" | "idle" | "finished";
export const featureGroupOrder: readonly FeatureGroup[] = ["needsYou", "inFlight", "idle", "finished"];

/** A group's head: "Needs you", "Finished"; its count follows it in the tertiary colour (#4418). */
export const groupWords: Record<FeatureGroup, string> = { needsYou: "Needs you", inFlight: "In flight", idle: "Idle", finished: "Finished" };

/** The sessions on a feature's work (#4115), of those this page knows: not archived, and labelled
 * with the short ref of one of its open issues or epics (#3265, or ENG-5), as a lane and a lead label theirs. */
export function featureSessions(feature: ForgeFeature, agents: readonly Agent[]): Agent[] {
  const refs = new Set((feature.refs ?? []).map(shortRef));
  if (refs.size === 0) return [];
  return agents.filter((a) => a.state !== "archived" && (a.labels ?? []).some((l) => refs.has(l.value)));
}

function groupOf(f: ForgeFeature, sessions: readonly Agent[], approvals: ReadonlySet<string>): FeatureGroup {
  if (isFinished(f)) return "finished";
  if ((f.waiting ?? []).length > 0
    || sessions.some((a) => a.state === "waitingOnUser" || (a.labels ?? []).some((l) => approvals.has(l.value)))) return "needsYou";
  return sessions.length === 0 ? "idle" : "inFlight";
}

/** The features in their groups, as the list shows them (#4115): Needs you, In flight and Idle in
 * their order, Idle the least recently updated first, and Finished at the bottom. */
export function featureGroups(features: readonly ForgeFeature[], agents: readonly Agent[] = [], approvals: readonly string[] = []):
  { group: FeatureGroup; features: ForgeFeature[] }[] {
  const waiting = new Set(approvals.map((r) => `P${shortRef(r)}`));
  const by = new Map<FeatureGroup, ForgeFeature[]>();
  for (const f of features) {
    const g = groupOf(f, featureSessions(f, agents), waiting);
    by.set(g, [...by.get(g) ?? [], f]);
  }
  by.get("idle")?.sort((a, b) => (a.updatedAt ?? -Infinity) - (b.updatedAt ?? -Infinity));
  return featureGroupOrder.flatMap((group) => { const list = by.get(group); return list ? [{ group, features: list }] : []; });
}

/** An In flight feature's sessions: "1 session", "3 sessions". */
export const sessionWords = (count: number) => `${count} ${count === 1 ? "session" : "sessions"}`;

/** A feature's bar (epic.md, Features note 2): its epics closed, of all; undefined with no epic. */
export const epicsDone = (f: ForgeFeature) => f.epics > 0 ? Math.max(f.epics - f.open, 0) / f.epics : undefined;

/** The words at a feature's bar: "1 of 2 epics done", "0 of 1 epic done". */
export const epicsDoneWords = (f: ForgeFeature) => `${Math.max(f.epics - f.open, 0)} of ${f.epics} ${f.epics === 1 ? "epic" : "epics"} done`;

/** What waits for the person on a Needs you feature (Features note 2): "P#4405 waits for your approval", "#4290 waits
 * for you", "“Work look: epic page” needs you"; undefined with nothing. */
export function needsWords(f: ForgeFeature, sessions: readonly Agent[], approvals: readonly string[]): string | undefined {
  const waiting = approvals.map((r) => `P${shortRef(r)}`);
  const pr = waiting.find((p) => sessions.some((a) => (a.labels ?? []).some((l) => l.value === p)));
  if (pr) return `${pr} waits for your approval`;
  const ref = f.waiting?.[0];
  if (ref) return `${shortRef(ref)} waits for you`;
  const session = sessions.find((a) => a.state === "waitingOnUser");
  if (session) return session.title ? `“${session.title}” needs you` : "A session needs you";
  return undefined;
}

const union = (a: string[] | undefined, b: string[] | undefined) => !a ? b : !b ? a : [...a, ...b.filter((r) => !a.includes(r))];

/** The features of several machines as one list, by name: the counts of one feature added up. Its
 * issues are unknown when one machine does not count them. */
export function mergeFeatures(lists: readonly (readonly ForgeFeature[])[]): ForgeFeature[] {
  const by = new Map<string, ForgeFeature>();
  for (const f of lists.flat()) {
    const key = f.name.toLowerCase();
    const had = by.get(key);
    if (!had) { by.set(key, { ...f }); continue; }
    had.epics += f.epics;
    had.open += f.open;
    if (had.issues === undefined || f.issues === undefined) delete had.issues;
    else had.issues += f.issues;
    if (had.color === undefined && f.color !== undefined) had.color = f.color;
    const refs = union(had.refs, f.refs);
    if (refs) had.refs = refs;
    const waiting = union(had.waiting, f.waiting);
    if (waiting) had.waiting = waiting;
    if (f.updatedAt !== undefined && (had.updatedAt === undefined || f.updatedAt > had.updatedAt)) had.updatedAt = f.updatedAt;
  }
  return [...by.values()].sort((a, b) => a.name.toLowerCase() < b.name.toLowerCase() ? -1 : a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0);
}

/** An epic: labelled epic, or the parent of sub-issues. */
export const isEpic = (item: ForgeItem) => item.level === "epic" || (item.progress?.total ?? 0) > 0;

/** The open issues with a feature's label, read from forge/issues, as the feature shows them: the
 * epics, and the issues with no parent that are not epics. A child of an epic is in its plan. */
export function openedFeature(items: readonly ForgeItem[]): { epics: ForgeItem[]; loose: ForgeItem[] } {
  const seen = new Set<string>();
  const mine = items.filter((i) => i.node.kind === "issue" && i.state === "open" && !seen.has(i.node.ref) && seen.add(i.node.ref))
    .sort((a, b) => b.updatedAt - a.updatedAt);
  return { epics: mine.filter(isEpic), loose: mine.filter((i) => !isEpic(i) && i.parent === undefined) };
}

/** An epic's progress: "1 of 6", its closed sub-issues of all; "0 of 0" with none yet. */
export const epicProgressWords = (item: ForgeItem) => `${item.progress?.done ?? 0} of ${item.progress?.total ?? 0}`;

const holdsRuntime = (s: AgentState) => s === "starting" || s === "running" || s === "waitingOnUser";

/** The session that leads an epic, of those this page knows: labelled lead and the epic's short ref
 * (#3265, or ENG-5 on Linear), as Start lead labels it; not archived; a live one first, then the newest. */
export function epicLead(epic: LineageNode, agents: readonly Agent[]): Agent | undefined {
  const ref = shortRef(epic.ref);
  let best: Agent | undefined;
  for (const a of agents) {
    const labels = (a.labels ?? []).map((l) => l.value);
    if (a.state === "archived" || !labels.includes("lead") || !labels.includes(ref)) continue;
    const better = !best || (holdsRuntime(a.state) !== holdsRuntime(best.state) ? holdsRuntime(a.state) : a.createdAt > best.createdAt);
    if (better) best = a;
  }
  return best;
}

/** An epic's lead on its row: "● lead working", "● lead needs you", "lead stopped"; "—" with none. */
export function leadRowWords(state: AgentState | undefined): string {
  switch (state) {
    case undefined: case "archived": return "—";
    case "waitingOnUser": return "● lead needs you";
    case "starting": case "running": return "● lead working";
    case "finished": return "lead waiting";
    case "stopped": return "lead stopped";
    case "queued": return "lead queued";
  }
}

/** When no feature is on any epic yet (states board, 10): the title, then two lines. */
export const noFeaturesTitle = "No features yet";
export const noFeatures = "A feature is a feature:<name> label on an epic.";
export const noFeaturesLabel = "Label an epic on its forge to see it here.";
export const nothingOpen = "No open epics or issues.";

// Features as a delivery view (#4589, specs/4328-work-look/features-delivery.md): each open epic is a line with where it
// is in its plan, and its children in flight under it. Until work/features (#4586), the epics come from forge/issues,
// their children and steps from forge/plan, and what works on a child from the sessions labelled with it (note 16).

/** A feature in Needs you or In flight starts open; Idle and Finished start folded, except that Idle starts open when no
 * feature is in Needs you or In flight (state 14). */
export const startsOpen = (group: FeatureGroup, groups: readonly FeatureGroup[]) =>
  group === "needsYou" || group === "inFlight" || (group === "idle" && !groups.includes("needsYou") && !groups.includes("inFlight"));

/** The lanes on an issue, of the sessions this page knows: not archived, labelled with its short ref, and not a lead
 * (a lead labels its epic). The newest first. */
export function issueLanes(ref: string, agents: readonly Agent[]): Agent[] {
  const short = shortRef(ref);
  return agents.filter((a) => a.state !== "archived" && (a.labels ?? []).some((l) => l.value === short)
    && !(a.labels ?? []).some((l) => l.value === "lead")).sort((a, b) => b.createdAt - a.createdAt);
}

/** A lane's pull request, from its labels (P#45), as a lane labels its own; undefined with none. */
export const lanePR = (a: Agent) => (a.labels ?? []).find((l) => /^P[#!]\d+$/.test(l.value))?.value;

/** A child in flight (note 8): Needs you (the warn glyph, in the attention colour) or Working (a green dot). */
export type FlightMark = "attention" | "working";
export interface InFlight { item: ForgeItem; mark: FlightMark; words: string; pr: string | undefined }

/** Whether an issue waits for the person by its labels: alex-todo or needs-account. */
const waitsForPerson = (item: ForgeItem) => item.labels.some((l) => ["alex-todo", "needs-account"].includes(l.name.toLowerCase()));

/** An open child in flight (note 8), and what works on it: "P#45 waits for your approval", "Needs you · the lane asks a
 * question", "waits for you (alex-todo)", "Working · “Gift card errors”"; undefined for a closed child, or an open one
 * with no lane and nothing for the person. `approvals` are the pull requests that wait for approval, as P#45. */
export function inFlight(item: ForgeItem, agents: readonly Agent[], approvals: ReadonlySet<string>): InFlight | undefined {
  if (item.state === "closed") return undefined;
  const lanes = issueLanes(item.node.ref, agents);
  const prs = lanes.flatMap((a) => { const p = lanePR(a); return p ? [p] : []; });
  const pr = prs.find((p) => approvals.has(p)) ?? prs[0];
  if (pr && approvals.has(pr)) return { item, mark: "attention", words: `${pr} waits for your approval`, pr };
  if (lanes.some((a) => a.state === "waitingOnUser")) return { item, mark: "attention", words: "Needs you · the lane asks a question", pr };
  if (waitsForPerson(item)) {
    const label = item.labels.find((l) => ["alex-todo", "needs-account"].includes(l.name.toLowerCase()))!.name;
    return { item, mark: "attention", words: `waits for you (${label})`, pr };
  }
  const lane = lanes[0];
  if (!lane) return undefined;
  return { item, mark: "working", words: lane.title ? `Working · “${lane.title}”` : "Working", pr };
}

/** The children in flight, in note 8's order: Needs you first, then Working, each the most recently updated first. */
export function flightOrder(list: readonly InFlight[]): InFlight[] {
  return [...list].sort((a, b) => a.mark !== b.mark ? (a.mark === "attention" ? -1 : 1) : b.item.updatedAt - a.item.updatedAt);
}

/** The lines in flight a wide page shows under an epic, and a phone's (notes 8 and 14). */
export const flightShown = 5;
export const flightShownPhone = 2;

/** A bar's counts (notes 4 and 6): done (closed), in flight, of all. */
export interface Delivery { done: number; flight: number; total: number }

/** An epic's counts from its plan: its children closed, in flight, of all. */
export function planDelivery(plan: ForgePlan, flight: number): Delivery {
  return { done: plan.children.filter((c) => c.item.state === "closed").length, flight, total: plan.children.length };
}

/** An epic's counts before its plan is read: its sub-issues closed of all, none in flight (state 13). */
export const progressDelivery = (item: ForgeItem): Delivery => ({ done: item.progress?.done ?? 0, flight: 0, total: item.progress?.total ?? 0 });

/** Counts added up: a feature's, over its open epics and its loose issues (note 4). */
export const addDelivery = (list: readonly Delivery[]): Delivery =>
  list.reduce((a, b) => ({ done: a.done + b.done, flight: a.flight + b.flight, total: a.total + b.total }), { done: 0, flight: 0, total: 0 });

/** A bar's shares (note 4): done (purple), in flight (green); the rest is grey. */
export const deliveryShares = (d: Delivery) => d.total === 0 ? { done: 0, flight: 0 }
  : { done: d.done / d.total, flight: Math.min(d.flight, d.total - d.done) / d.total };

/** The words after a feature's bar: "9 of 21 done". */
export const deliveryWords = (d: Delivery) => `${d.done} of ${d.total} done`;

/** Where an epic is in its plan (note 5): "step 2 of 3", "step 1 of 2 · waits for #10" when its first open step waits
 * on an open issue outside the plan; undefined with no open child. */
export function whereWords(plan: ForgePlan): string | undefined {
  const open = plan.children.filter((c) => c.item.state !== "closed");
  if (open.length === 0 || plan.steps.length === 0) return undefined;
  const step = Math.min(...open.map((c) => c.step));
  const index = plan.steps.findIndex((s) => s.step === step);
  const words = `step ${index < 0 ? step : index + 1} of ${plan.steps.length}`;
  const outside: string[] = [];
  for (const c of open) {
    if (c.step !== step) continue;
    for (const b of c.blockedOutside ?? []) { const r = shortRef(b.ref); if (!outside.includes(r)) outside.push(r); }
  }
  return outside.length === 0 ? words : `${words} · waits for ${outside.join(", ")}`;
}

/** A feature's line 2 (note 3): "2 epics · 4 in flight", the open epics and the children in flight. */
export function featureFlightWords(f: ForgeFeature, flight: number): string {
  const epics = isFinished(f) ? f.epics : f.open;
  return `${epics} ${epics === 1 ? "epic" : "epics"} · ${flight === 0 ? "nothing in flight" : `${flight} in flight`}`;
}

/** The issues of a feature in flight, before its plans are read (note 3): its open issues and epics with a lane, or
 * that wait for the person; the epics' leads do not count. */
export function featureFlight(f: ForgeFeature, agents: readonly Agent[]): number {
  const waiting = new Set(f.waiting ?? []);
  return (f.refs ?? []).filter((r) => waiting.has(r) || issueLanes(r, agents).length > 0).length;
}

/** An Idle feature's age (note 3): "updated 3 d ago"; undefined with no date. */
export function updatedWords(f: ForgeFeature, now: number = Date.now()): string | undefined {
  if (f.updatedAt === undefined) return undefined;
  const age = shortAge(Math.max(0, (now - fromWireDate(f.updatedAt).getTime()) / 1000));
  return age === "now" ? "updated now" : `updated ${age} ago`;
}

/** The rest under an epic, in words (notes 9 and 15): "2 more in flight · 2 more not started · 4 done"; undefined with
 * none. `shown` are the lines in flight drawn above it, so the counts say "more". */
export function restWords(d: Delivery, shown: number): string | undefined {
  const notStarted = Math.max(d.total - d.done - d.flight, 0);
  const more = Math.max(d.flight - shown, 0);
  const parts: string[] = [];
  if (more > 0) parts.push(`${more} more in flight`);
  if (notStarted > 0) parts.push(`${notStarted}${shown > 0 || more > 0 ? " more" : ""} not started`);
  if (d.done > 0) parts.push(`${d.done} done`);
  return parts.length === 0 ? undefined : parts.join(" · ");
}

/** An epic with no child in flight (note 10). */
export const nothingInFlight = "Nothing in flight";
/** The link at the end of the rest's words (note 9). */
export const openEpicWords = "open the epic for the plan";
/** While an epic's plan is read (state 13). */
export const readingWords = "reading…";
