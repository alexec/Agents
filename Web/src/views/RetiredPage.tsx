// RetiredAgentPage (051 FR-021, #253): an agent that has been retired, reached only through
// something that names it (a link, a "Started by" mark, a workflow's run). It says who the agent
// was and when it went, and offers nothing to do: there is nothing left to open.
import type { Tombstone } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { BackToList } from "./BackToList";

/** RetirementWords.day: "12 October". */
function day(date: Date): string {
  return `${date.getDate()} ${date.toLocaleDateString("en", { month: "long" })}`;
}

/** RetirementWords.retiredSentence. */
export function retiredSentence(t: Tombstone): string {
  const title = t.title?.trim();
  const on = `${title ? `“${title}”` : "This agent"} was retired on ${day(fromWireDate(t.retiredAt))}`;
  switch (t.retiredBecause) {
    case "age": {
      const days = Math.max(1, Math.round((t.retiredAt - t.archivedAt) / 86_400));
      return `${on}, ${days} ${days === 1 ? "day" : "days"} after it was archived.`;
    }
    case "cap": return `${on}, to keep archived agents within the space they may take.`;
    case "person": return `${on}, when you chose to retire it.`;
  }
}

const when = (wire: number) => fromWireDate(wire as Tombstone["createdAt"]).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });

export function RetiredPage({ tombstone: t }: { tombstone: Tombstone }) {
  const project = decodeURIComponent(t.project.replace(/\/$/, "").split("/").pop() ?? t.project);
  const facts: [string, string][] = [
    ["Project", project], ["Runtime", t.runtimeID], ["Started", when(t.createdAt)],
    ["Archived", when(t.archivedAt)], ["Retired", when(t.retiredAt)],
    ...(t.startedByWorkflow ? [["Workflow", t.startedByWorkflow] as [string, string]] : []),
    ...(t.worktreeName ? [["Worktree", t.worktreeBranch ? `${t.worktreeName} (${t.worktreeBranch})` : t.worktreeName] as [string, string]] : []),
  ];
  return (
    <section class="chat retired-page" aria-label="Retired agent">
      <header class="column-head"><BackToList /><h1>{t.title?.trim() || "An agent"}</h1></header>
      <div class="scroll">
        <div class="retired-body">
          <p class="quiet small">Retired</p>
          <p>{retiredSentence(t)}</p>
          <p class="quiet">Its conversation was deleted. What is left is enough to say who it was.</p>
          <dl class="facts">
            {facts.map(([label, value]) => [<dt key={`${label}-t`} class="quiet">{label}</dt>, <dd key={`${label}-d`}>{value}</dd>])}
          </dl>
        </div>
      </div>
    </section>
  );
}
