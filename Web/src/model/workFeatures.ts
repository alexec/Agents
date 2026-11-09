// Work ▸ Features (#3269, spec 3265), as the window's WorkFeatures: each feature:<name> label
// (forge/features) with its epic counts, in the groups of FeatureGroup (#4115); opened, its open epics, each with its progress and its
// lead, and its loose issues (the open issues with the label and no parent epic).
import type { Agent, AgentState, ForgeFeature, ForgeItem, LineageNode } from "../protocol/generated";
import { shortRef } from "./work";

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

/** A group's head: "Needs you", "Finished (7)". */
export function groupWords(group: FeatureGroup, count: number): string {
  switch (group) {
    case "needsYou": return "Needs you";
    case "inFlight": return "In flight";
    case "idle": return "Idle";
    case "finished": return finishedWords(count);
  }
}

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

/** The Finished group's head: "Finished (7)". */
export const finishedWords = (count: number) => `Finished (${count})`;

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

/** An epic's progress: "1/6", its closed sub-issues of all; "0/0" with none yet. */
export const epicProgressWords = (item: ForgeItem) => `${item.progress?.done ?? 0}/${item.progress?.total ?? 0}`;

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

/** An epic's lead on its row: "● lead running", "● lead needs you", "lead stopped"; "—" with none. */
export function leadRowWords(state: AgentState | undefined): string {
  switch (state) {
    case undefined: case "archived": return "—";
    case "waitingOnUser": return "● lead needs you";
    case "starting": case "running": return "● lead running";
    case "finished": return "lead waiting";
    case "stopped": return "lead stopped";
    case "queued": return "lead queued";
  }
}

export const noFeatures = "No features yet. A feature is a feature:<name> label on an epic.";
export const nothingOpen = "No open epics or issues.";
