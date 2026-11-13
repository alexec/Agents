// The Now card's words (#5033, specs/session-cards/spec.md, family 5), as NowWords and
// LiveTileWords.driving in Shared/UI/Chat/NowCard.swift and LiveTile.swift.
import type { LiveSource, Plan } from "../protocol/generated";

export const nowWorking = "Working";
export const nowShowMore = "Show more";
export const nowShowLess = "Show less";

/** "In the background · 2", the foot's line when only background work is left. */
export function nowBackground(count: number): string {
  return `In the background · ${count}`;
}

/** The plan's one line in the transcript: "Plan · 5 steps", or "Plan, dropped · 5 steps". */
export function nowPlan(plan: Plan): string {
  const steps = plan.entries.length === 1 ? "1 step" : `${plan.entries.length} steps`;
  return plan.state === "withdrawn" ? `Plan, dropped · ${steps}` : `Plan · ${steps}`;
}

/** The Now card's line while the agent drives a source: "Driving the browser". */
export function nowDriving(source: LiveSource): string {
  return source === "screen" ? "Driving the screen" : source === "browser" ? "Driving the browser" : "Driving the simulator";
}
