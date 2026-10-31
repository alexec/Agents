// The goal the agent's runtime keeps working towards, at the head of the chat over the plan
// (#2742), as the window's and the Remote's GoalCard: the plan card's place and look (#776),
// one line until it is opened. A stopped goal says why under the line; a budget is a bar in
// the accent. A goal is not a status, so its word is grey and the row keeps its own marks.
import { useSignal } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import { goalBudgetFraction, goalIsStopped, goalProgress, goalStatusWord, goalSummary } from "../model/goal";

export function GoalCard({ agent }: { agent: Agent | undefined }) {
  const open = useSignal(false);
  const goal = agent?.goal;
  if (!goal) return null;
  const progress = goalProgress(goal);
  const fraction = goalBudgetFraction(goal);
  return (
    <div class="plan-strip goal-strip">
      <div class="plan-card">
        <button class={`plan-summary${open.value ? " open" : ""}`} aria-expanded={open.value} aria-label={goalSummary(goal)}
          onClick={() => (open.value = !open.value)}>
          <span class="plan-line">
            <span class="plan-icon" aria-hidden="true">{goal.status === "complete" ? "✓" : "◎"}</span>
            <span class="plan-step">{goal.objective}</span>
            <span class="plan-count">{goalStatusWord(goal)}</span>
            <span class="chevron" aria-hidden="true">{open.value ? "▾" : "▸"}</span>
          </span>
          {goal.reason !== undefined && (goalIsStopped(goal) || open.value) && <span class="goal-reason">{goal.reason}</span>}
          {open.value && progress && <span class="goal-progress">{progress}</span>}
          {fraction !== null && (
            <span class="plan-bar" aria-hidden="true"><span style={{ width: `${fraction * 100}%` }} /></span>
          )}
        </button>
      </div>
    </div>
  );
}
