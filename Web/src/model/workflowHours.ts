// The Hours setting on a workflow's Configuration (#4820), as WorkflowHoursSetting.swift has it:
// what each control writes. Every change is a whole `hours:`, and one that limits nothing (no
// `between:`, no `days:`) is Any time, which takes the key out.
import type { Weekday, WorkflowHours } from "../protocol/generated";
import { hoursSentence as runsSentence } from "./workflows";

/** What Some hours writes first: working hours. */
export const workingHours: WorkflowHours = { between: "09:00-17:00", days: ["mon", "tue", "wed", "thu", "fri"] };

/** The days the control shows, in the order the file's words say them. */
export const shownDays: Weekday[] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/** The times the From and To menus offer: every half hour, as minutes of the day. */
export const halfHours: number[] = Array.from({ length: 48 }, (_, i) => i * 30);

const day = 24 * 60;

/** Minutes of the day as the file writes them: `09:00`, `18:30`. */
export function clockText(minutes: number): string {
  return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
}

/** A day as the control names it: `Mon`. */
export function dayName(d: Weekday): string {
  return d[0]!.toUpperCase() + d.slice(1);
}

/** Whether it limits when the workflow starts; false is Any time. */
export function limits(h: WorkflowHours | undefined): boolean {
  return h?.named !== undefined || h?.between !== undefined || h?.days !== undefined;
}

/** The Hours menu's choices (#4821), as WorkflowHours.Choice: Any time, the project's working hours, outside them, or hours of its own. */
export type HoursChoice = "anyTime" | "working" | "notWorking" | "some";
export const hoursChoiceTitles: Record<HoursChoice, string> = {
  anyTime: "Any time", working: "Working hours", notWorking: "Outside working hours", some: "Some hours",
};

/** What the Hours menu shows. */
export function hoursChoice(h: WorkflowHours | undefined): HoursChoice {
  if (h?.named === "working") return "working";
  if (h?.named === "not-working") return "notWorking";
  return limits(h) ? "some" : "anyTime";
}

/** What a choice writes: Some hours first writes working hours' times, or the project's. */
export function chosenHours(choice: HoursChoice, project?: WorkflowHours): WorkflowHours {
  switch (choice) {
    case "anyTime": return {};
    case "working": return { named: "working" };
    case "notWorking": return { named: "not-working" };
    case "some": {
      if (!project) return workingHours;
      const { named: _named, ...rest } = project;
      return rest;
    }
  }
}

function clock(part: string): number | null {
  const bits = part.trim().split(":");
  if (bits.length < 1 || bits.length > 2 || !/^\d+$/.test(bits[0]!)) return null;
  const hour = Number(bits[0]);
  if (hour > 23) return null;
  if (bits.length === 1) return hour * 60;
  if (bits[1] !== "00" && bits[1] !== "0" && bits[1] !== "30") return null;
  return hour * 60 + Number(bits[1]);
}

/** `between:` as minutes of the day; null is the whole day (or text the daemon refuses). */
export function hoursWindow(h: WorkflowHours): { from: number; to: number } | null {
  if (h.between === undefined) return null;
  const halves = h.between.split("-");
  if (halves.length !== 2) return null;
  const from = clock(halves[0]!), to = clock(halves[1]!);
  return from === null || to === null || from === to ? null : { from, to };
}

/** Whether the day's box is ticked: every day is, with no `days:`. */
export function admits(h: WorkflowHours, d: Weekday): boolean {
  return h.days?.includes(d) ?? true;
}

function withBetween(h: WorkflowHours, between: string | undefined): WorkflowHours {
  const { between: _old, ...rest } = h;
  return between === undefined ? rest : { ...rest, between };
}

/** From set to a time, or to All day with null. From All day, or onto the To time, eight hours. */
export function startingAt(h: WorkflowHours, minute: number | null): WorkflowHours {
  if (minute === null) return withBetween(h, undefined);
  let to = hoursWindow(h)?.to ?? (minute + 8 * 60) % day;
  if (to === minute) to = (minute + 8 * 60) % day;
  return withBetween(h, `${clockText(minute)}-${clockText(to)}`);
}

/** To set to a time; null when there is no From, or it is the From time. */
export function endingAt(h: WorkflowHours, minute: number): WorkflowHours | null {
  const from = hoursWindow(h)?.from;
  if (from === undefined || from === minute) return null;
  return withBetween(h, `${clockText(from)}-${clockText(minute)}`);
}

/** A day's box ticked or not; null when it would leave no day. Every day is no `days:`. */
export function toggling(h: WorkflowHours, d: Weekday): WorkflowHours | null {
  const set = new Set(h.days ?? shownDays);
  if (set.has(d)) set.delete(d); else set.add(d);
  if (set.size === 0) return null;
  const { days: _old, ...rest } = h;
  return set.size === shownDays.length ? rest : { ...rest, days: shownDays.filter((x) => set.has(x)) };
}

/** The time zone menu's choice: undefined is Your time zone. */
export function inZone(h: WorkflowHours, zone: string | undefined): WorkflowHours {
  const { timeZone: _old, ...rest } = h;
  return zone === undefined ? rest : { ...rest, timeZone: zone };
}

/** WorkflowHours.words: `only 18:00-09:00 on Mon, Tue (Europe/London)`; null limits nothing. */
export function hoursWords(h: WorkflowHours | undefined): string | null {
  if (h?.named === "working") return "only in working hours";
  if (h?.named === "not-working") return "only outside working hours";
  if (!h || !limits(h)) return null;
  let out = "only";
  if (h.between !== undefined) out += ` ${h.between}`;
  if (h.days) out += ` on ${shownDays.filter((d) => h.days!.includes(d)).map(dayName).join(", ")}`;
  if (h.timeZone !== undefined) out += ` (${h.timeZone})`;
  return out;
}

/** The sentence beside the control. */
export function hoursSentence(h: WorkflowHours | undefined): string {
  const words = hoursWords(h);
  if (words === null) return "Any time: a trigger starts it at any hour.";
  if (h?.named !== undefined) return `Starts ${words}, as Project Settings sets them. A trigger outside them waits, and starts it once they open.`;
  return `Starts ${words}. A trigger outside them waits, and starts it once they open.`;
}

/** Project Settings ▸ General's Working hours line (#4821), as WorkflowHours.workingSentence. */
export function workingSentence(h: WorkflowHours | undefined): string {
  const words = runsSentence(h ?? workingHours)?.replace("Runs ", "") ?? "all day";
  return `Working hours are ${words}${h === undefined ? " (the default)" : ""}. A workflow with \`hours: working\` `
    + "starts only in them, and one with `hours: not-working` only outside them. Saved in .agents/folder.json.";
}

/** The time zones the menu offers, after Your time zone: the file's own too, when unknown here. */
export function hoursZones(current: string | undefined, known: readonly string[]): string[] {
  return current === undefined || known.includes(current) ? [...known] : [...known, current].sort();
}
