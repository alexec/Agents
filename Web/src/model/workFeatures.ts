// Work ▸ Features (#3269, spec 3265), as the window's WorkFeatures: each feature:<name> label
// (forge/features) with its epic counts; opened, its open epics, each with its progress and its
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

/** The features as the list shows them (#3741): those with open work at the top, in their order, and
 * the finished ones in the Finished group at the bottom. */
export const featureGroups = (features: readonly ForgeFeature[]) =>
  ({ active: features.filter((f) => !isFinished(f)), finished: features.filter(isFinished) });

/** The Finished group's head: "Finished (7)". */
export const finishedWords = (count: number) => `Finished (${count})`;

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
