// The plan strip at the head of the chat (#341): Agent.planInForce and Plan.stripSummary
// (Model/CurrentPlan.swift), ported by hand and held to Fixtures/web/plan/strip.json.
import type { Agent, Plan } from "../protocol/generated";

/** The last plan the agent put forward that it has not dropped, and that has steps. */
export function planInForce(agent: Pick<Agent, "plans">): Plan | null {
  const plans = agent.plans ?? [];
  for (let index = plans.length - 1; index >= 0; index--) {
    const plan = plans[index]!;
    if (plan.state === "current" && plan.entries.length > 0) return plan;
  }
  return null;
}

/** The step being worked, and how far along: "Fix the row — 1 of 3 done". */
export function planSummary(plan: Plan): string {
  const done = plan.entries.filter((entry) => entry.status === "completed").length;
  const progress = `${done} of ${plan.entries.length} done`;
  const doing = plan.entries.find((entry) => entry.status === "in_progress");
  return doing ? `${doing.content} — ${progress}` : `Plan — ${progress}`;
}
