// The daily summary's control's words (#3351), as Shared/UI/DailySummaryControls.swift and
// AgentsKit's DailySummarySettings.swift say them.
import type { DailySummaryMode } from "../protocol/generated";

export const dailySummaryModes: { mode: DailySummaryMode; label: string }[] = [
  { mode: "off", label: "Off" },
  { mode: "summary", label: "Summary only" },
];

/** Every half hour of the day, as HH:MM: the times the daily summary can run at. */
export const dailySummaryTimes = Array.from({ length: 48 }, (_, i) =>
  `${String(Math.floor(i / 2)).padStart(2, "0")}:${i % 2 ? "30" : "00"}`);

/** The times to offer: every half hour, and the stored time when a hand edit set another. */
export function dailySummaryChoices(at: string): string[] {
  return dailySummaryTimes.includes(at) ? dailySummaryTimes : [...dailySummaryTimes, at].sort();
}

/** A time as a person reads it, such as "8:00 AM", in this browser's locale. */
export function dailySummaryTimeLabel(at: string): string {
  const [h, m] = at.split(":").map(Number);
  if (Number.isNaN(h) || Number.isNaN(m)) return at;
  return new Date(2000, 0, 1, h, m).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

export const dailySummaryHint = "Once a day, an agent writes one short page from every folder: what landed, "
  + "what failed or stopped, what waits on you and what the agents suggest next. "
  + "It runs on weekdays, on the Auto runtime, and only reads.";
