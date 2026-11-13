// What the agent says it is going to do, at the head of its chat (#341), as the window's and
// the Remote's CurrentPlanStrip: one line, the step being worked and how far along, opened to
// every step. Agent.plans arrives on agent/changed and is always current, so it needs no wire
// of its own; the dropped plan stays where it happened in the transcript, not up here. A card
// on the well with a bar in the accent, not a state colour, so it is not missed (#776).
import { useSignal } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import { planDone, planInForce, planStep, planSummary } from "../model/currentPlan";
import { PlanView } from "./chat/Rows";
import { Icon } from "./Icon";

export function CurrentPlanStrip({ agent }: { agent: Agent | undefined }) {
  const open = useSignal(false);
  const plan = agent && planInForce(agent);
  if (!plan) return null;
  const done = planDone(plan);
  const total = plan.entries.length;
  return (
    <div class="plan-strip">
      <div class="plan-card">
        <button class="plan-summary" aria-expanded={open.value} aria-label={planSummary(plan)}
          onClick={() => (open.value = !open.value)}>
          <span class="plan-line">
            <Icon name="square-check" class="plan-icon" />
            <span class="plan-step">{planStep(plan)}</span>
            <span class="plan-count">{done} of {total}</span>
            <Icon name={open.value ? "chevron-down" : "chevron-right"} class="chevron" />
          </span>
          <span class="plan-bar" aria-hidden="true"><span style={{ width: `${(done / total) * 100}%` }} /></span>
        </button>
        {open.value && <PlanView plan={plan} />}
      </div>
    </div>
  );
}
