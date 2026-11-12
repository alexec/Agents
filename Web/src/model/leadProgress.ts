// A lead's sidebar row (#3270, spec 3265), as the window's LeadProgress: a session labelled lead
// that works on an epic shows the epic's progress after its title, "Work pages lead · 5/7". The
// epic is the issue the session works on (lineage, from its #<n> label); the figures are its
// plan's children closed of all of them, as the Plan section's header.
import type { Agent, ForgePlan, LineageLink, LineageNode } from "../protocol/generated";
import { sessionIdOf } from "../protocol/ref";

/** The label that makes a session a lead (the lead skill's "Starting a lead"). */
export const leadLabel = "lead";

/** Whether a session is a lead. */
export const isLead = (agent: Agent) => (agent.labels ?? []).some((l) => l.value === leadLabel);

/** The epic a session works on: the newest issue it is linked to by works-on that has not ended. */
export function leadEpic(session: string, links: readonly LineageLink[]): LineageNode | undefined {
  // By the session's id: its ref's topic is its project's, which the page does not know (#4800).
  const mine = session.toLowerCase();
  let best: LineageLink | undefined;
  for (const l of links) {
    if (sessionIdOf(l.from.ref)?.toLowerCase() !== mine || l.rel !== "works-on" || l.to.kind !== "issue" || l.endedAt !== undefined) continue;
    if (!best || l.at > best.at) best = l;
  }
  return best?.to;
}

/** "5/7": the plan's children closed, of all of them. Undefined for a plan with no children. */
export function leadProgressWords(plan: ForgePlan): string | undefined {
  if (plan.children.length === 0) return undefined;
  const done = plan.children.filter((c) => c.item.state === "closed").length;
  return `${done}/${plan.children.length}`;
}

/** What a screen reader hears: "5 of 7 done". */
export function leadProgressSpoken(words: string): string {
  const [done, total] = words.split("/");
  return total === undefined ? words : `${done} of ${total} done`;
}
