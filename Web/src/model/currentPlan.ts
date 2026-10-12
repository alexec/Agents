// The plan strip at the head of the chat (#341, #776): Agent.planInForce, Plan.stripSummary,
// Plan.stripStep and Plan.stripDone
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

/** The card's own words (#776): the step being worked, or "Plan" between steps. */
export function planStep(plan: Plan): string {
  return plan.entries.find((entry) => entry.status === "in_progress")?.content ?? "Plan";
}

/** How many steps are done, for the count and the bar under it. */
export function planDone(plan: Plan): number {
  return plan.entries.filter((entry) => entry.status === "completed").length;
}
