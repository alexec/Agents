// The goal card over the plan's (#2742): Goal.statusWord, isStopped, progressLine,
// budgetFraction and summary (Model/Goal.swift), ported by hand and held to
// Fixtures/web/goal/card.json.
import type { Goal } from "../protocol/generated";

const words: Record<Goal["status"], string> = {
  active: "Active", paused: "Paused", blocked: "Blocked", limited: "Limit reached", complete: "Met",
};

/** Where it stands, in a word or two at the card's end. */
export function goalStatusWord(goal: Goal): string {
  return words[goal.status];
}

/** Stopped short of the goal: the card says why under the line, when the runtime said. */
export function goalIsStopped(goal: Goal): boolean {
  return goal.status === "paused" || goal.status === "blocked" || goal.status === "limited";
}

/** "1,000", as the org policy's token counts are written. */
function count(n: number): string {
  return n.toLocaleString("en-GB");
}

/** "under a minute", "12 min", "1 h 5 min". */
function duration(seconds: number): string {
  const minutes = Math.trunc(seconds / 60);
  if (minutes < 1) return "under a minute";
  if (minutes < 60) return `${minutes} min`;
  const rest = minutes % 60;
  return rest === 0 ? `${Math.trunc(minutes / 60)} h` : `${Math.trunc(minutes / 60)} h ${rest} min`;
}

/** How far along, as far as the runtime says: "3 turns · 42 of 1,000 tokens · 12 min". */
export function goalProgress(goal: Goal): string | null {
  const parts: string[] = [];
  if (goal.iterations !== undefined) parts.push(goal.iterations === 1 ? "1 turn" : `${goal.iterations} turns`);
  if (goal.tokenBudget !== undefined) parts.push(`${count(goal.tokensUsed ?? 0)} of ${count(goal.tokenBudget)} tokens`);
  else if (goal.tokensUsed !== undefined && goal.tokensUsed > 0) parts.push(`${count(goal.tokensUsed)} tokens`);
  if (goal.timeUsedSeconds !== undefined && goal.timeUsedSeconds > 0) parts.push(duration(goal.timeUsedSeconds));
  return parts.length ? parts.join(" · ") : null;
}

/** How much of its budget it has used, for the bar; null with no budget. */
export function goalBudgetFraction(goal: Goal): number | null {
  if (goal.tokenBudget === undefined || goal.tokenBudget <= 0) return null;
  return Math.min((goal.tokensUsed ?? 0) / goal.tokenBudget, 1);
}

/** The card read aloud: "Goal: Ship the change. Paused: Waiting on review. 3 turns". */
export function goalSummary(goal: Goal): string {
  let line = `Goal: ${goal.objective}. ${goalStatusWord(goal)}`;
  if (goal.reason !== undefined) line += `: ${goal.reason}`;
  const progress = goalProgress(goal);
  if (progress) line += `. ${progress}`;
  return line;
}
