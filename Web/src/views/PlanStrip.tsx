// What the agent says it is going to do, at the head of its chat (#341), as the window's and
// the Remote's CurrentPlanStrip: one line, the step being worked and how far along, opened to
// every step. Agent.plans arrives on agent/changed and is always current, so it needs no wire
// of its own; the dropped plan stays where it happened in the transcript, not up here.
import { useSignal } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import { planInForce, planSummary } from "../model/currentPlan";
import { PlanView } from "./chat/Rows";

export function CurrentPlanStrip({ agent }: { agent: Agent | undefined }) {
  const open = useSignal(false);
  const plan = agent && planInForce(agent);
  if (!plan) return null;
  return (
    <div class="plan-strip">
      <button class="plan-summary" aria-expanded={open.value} onClick={() => (open.value = !open.value)}>
        <span class="chevron" aria-hidden="true">{open.value ? "▾" : "▸"}</span>{planSummary(plan)}
      </button>
      {open.value && <PlanView plan={plan} />}
    </div>
  );
}
