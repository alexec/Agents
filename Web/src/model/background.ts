// The words for what an agent left running (057): BackgroundWords (Model/BackgroundWork.swift),
// ported by hand and held to Fixtures/web/background (research R7). The daemon applies every
// update and sends Agent.background whole, so nothing here applies one.
import type { BackgroundItem } from "../protocol/generated";

export function isRunning(item: BackgroundItem): boolean {
  return item.state === "running" || item.state === "paused";
}

function isShell(item: BackgroundItem): boolean {
  return item.kind === "task" && item.taskType === "shell";
}

/** "1 shell, 1 subagent in the background", or null when nothing runs. */
export function backgroundMark(items: readonly BackgroundItem[]): string | null {
  const running = items.filter(isRunning);
  if (!running.length) return null;
  const shells = running.filter(isShell).length;
  const subagents = running.filter((item) => item.kind === "subagent").length;
  const others = running.length - shells - subagents;
  const parts: string[] = [];
  if (shells > 0) parts.push(shells === 1 ? "1 shell" : `${shells} shells`);
  if (subagents > 0) parts.push(subagents === 1 ? "1 subagent" : `${subagents} subagents`);
  if (others > 0) parts.push(others === 1 ? "1 task" : `${others} tasks`);
  return parts.join(", ") + " in the background";
}

/** What kind of thing it is, in a word. */
export function backgroundNoun(item: BackgroundItem): string {
  if (item.kind === "subagent") return "Subagent";
  switch (item.taskType) {
    case "shell": return "Shell";
    case "workflow": return "Workflow";
    case "monitor": return "Monitor";
    default: return "Task";
  }
}

/** The line the chat keeps when one ends: Subagent “Count files” finished. */
export function backgroundEnding(item: BackgroundItem): string {
  const what = `${backgroundNoun(item)} “${item.name}”`;
  switch (item.state) {
    case "completed": return `${what} finished`;
    case "failed": return `${what} failed`;
    case "stopped": return `${what} stopped`;
    case "disconnected": return `${what} ended with the turn`;
    default: return `${what} is running in the background`;
  }
}

/** How it ended, for a row still listed after it has; null while it runs. */
export function backgroundEnded(item: BackgroundItem): string | null {
  switch (item.state) {
    case "completed": return "Finished";
    case "failed": return "Failed";
    case "stopped": return "Stopped";
    case "disconnected": return "Ended with the turn";
    default: return null;
  }
}

const two = (n: number) => String(n).padStart(2, "0");

/** How long it has run, or ran: "0:37", "12:04", "1:02:10". `now` is a wire date. */
export function backgroundAge(item: BackgroundItem, now: number): string {
  // Int(TimeInterval) truncates toward zero.
  const seconds = Math.max(0, Math.trunc((item.endedAt ?? now) - item.startedAt));
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}
