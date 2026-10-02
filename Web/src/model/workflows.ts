// A workflow's row under the sessions: Workflow.summary and canFire (Model/Workflow.swift and
// its trigger, schedule and settings words), WorkflowSummary.needsAPerson, and the window's
// status icon (WorkflowRow.swift), ported by hand and held to Fixtures/web/workflows.
//
// An event trigger (042) arrives as `unrecognised` with a dotted name, which Swift reads back as
// an event and describes from its catalogue. The page has no catalogue, so it says the event's
// name and filters instead: "When ci.finished (branch main)".
import type {
  JSONValue, Weekday, Workflow, WorkflowProblem, WorkflowRefusal, WorkflowSchedule, WorkflowSettings, WorkflowSummary,
  WorkflowTriggerStored,
} from "../protocol/generated";

/** `RuntimeCatalog.builtIn[0]`: left unsaid in a row. */
export const defaultRuntime = "claude";

const allWeekdays: Weekday[] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const workweek: Weekday[] = ["mon", "tue", "wed", "thu", "fri"];

function sameSet<T>(a: readonly T[], b: readonly T[]): boolean {
  return a.length === b.length && b.every((x) => a.includes(x));
}

function clock(hour: number, minute: number): string {
  const suffix = hour < 12 ? "am" : "pm";
  const twelve = hour % 12 === 0 ? 12 : hour % 12;
  return minute === 0 ? `${twelve}${suffix}` : `${twelve}:${String(minute).padStart(2, "0")}${suffix}`;
}

/** WorkflowSchedule.summary. */
export function scheduleSummary(s: WorkflowSchedule): string {
  const when = sameSet(s.minutes, [0, 30]) ? "on the hour and half hour" : sameSet(s.minutes, [30]) ? "on the half hour" : "on the hour";
  let days: string;
  if (sameSet(s.days, allWeekdays)) days = "Every day";
  else if (sameSet(s.days, workweek)) days = "Every weekday";
  else days = allWeekdays.filter((d) => s.days.includes(d)).map((d) => d.charAt(0).toUpperCase() + d.slice(1)).join(", ");
  const [from, to] = s.hours;
  if (from === 0 && to === 23) return `${days} ${when}`;
  if (from === to && s.minutes.length === 1) return `${days} at ${clock(from, s.minutes[0]!)}`;
  const end = s.endMinute === 30 && s.minutes.includes(30) ? 30 : 0;
  return `${days} ${when} between ${clock(from, s.startMinute)} and ${clock(to, end)}`;
}

function isSupported(trigger: WorkflowTriggerStored): boolean {
  return !("unrecognised" in trigger) || isEvent(trigger);
}

/** An event trigger, as the wire carries it: `unrecognised` with a dotted name (042 FR-025). */
function isEvent(trigger: WorkflowTriggerStored): boolean {
  return "unrecognised" in trigger && trigger.unrecognised.name.includes(".");
}

function scalar(value: JSONValue): string | null {
  return typeof value === "string" || typeof value === "number" || typeof value === "boolean" ? String(value) : null;
}

/** WorkflowTrigger.summary, with an event said by its name (see above). */
export function triggerSummary(trigger: WorkflowTriggerStored): string {
  if ("schedule" in trigger) return scheduleSummary(trigger.schedule._0);
  if ("agentFinished" in trigger) return "When an agent finishes";
  if ("agentAskedPermission" in trigger) return "When an agent asks for permission";
  if ("agentAskedForm" in trigger) return "When an agent raises a form";
  if ("agentStopped" in trigger) return "When an agent stops without finishing";
  if ("workflowCompleted" in trigger) {
    const id = trigger.workflowCompleted.id;
    return id ? `When ${id} finishes` : "When any workflow finishes";
  }
  const { name, keys } = trigger.unrecognised;
  if (isEvent(trigger)) {
    const filters = Object.entries(keys).map(([k, v]) => [k, scalar(v)] as const).filter(([, v]) => v !== null)
      .sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, v]) => `${k} ${v}`).join(", ");
    return filters ? `When ${name} (${filters})` : `When ${name}`;
  }
  return `Waits for "${name}", which this version does not know about yet`;
}

function problemMessage(problem: WorkflowProblem): string {
  if ("unreadable" in problem) return problem.unreadable._0;
  if ("triggerNotSupported" in problem) return `Waits for "${problem.triggerNotSupported._0}", which this version does not know about yet`;
  return `Runs "${problem.unsupportedMode._0}", which this version does not know about yet`;
}

const modeWords = { new: "in a new agent", standing: "in its own standing agent", triggering: "in the agent that triggered it" };

function boolean(text: string): boolean | null {
  const lower = text.toLowerCase();
  if (lower === "true" || lower === "yes" || lower === "on") return true;
  if (lower === "false" || lower === "no" || lower === "off") return false;
  return null;
}

/** WorkflowSettings.summary: "in plan mode, on Grok, using grok-4, at high effort, with fast". */
export function settingsSummary(s: WorkflowSettings, runtimeName: (id: string) => string | undefined): string | null {
  const clauses: string[] = [];
  if (s.permissionMode !== undefined) clauses.push(`in ${s.permissionMode} mode`);
  if (s.runtimeID !== undefined && s.runtimeID !== defaultRuntime) clauses.push(`on ${runtimeName(s.runtimeID) ?? s.runtimeID}`);
  if (s.model !== undefined) clauses.push(`using ${s.model}`);
  if (s.effort !== undefined) clauses.push(`at ${s.effort} effort`);
  for (const [id, value] of Object.entries(s.options ?? {}).sort(([a], [b]) => (a < b ? -1 : 1))) {
    const flag = boolean(value);
    clauses.push(flag === true ? `with ${id}` : flag === false ? `without ${id}` : `with ${id} ${value}`);
  }
  return clauses.length ? clauses.join(", ") : null;
}

/** WorkflowCooldown.words: "15 minutes", "1 hour 30 minutes", "1 day" (#103). */
export function cooldownWords(seconds: number): string {
  let left = Math.floor(seconds / 60);
  const parts: string[] = [];
  for (const [unit, minutes] of [["day", 24 * 60], ["hour", 60], ["minute", 1]] as const) {
    if (left < minutes) continue;
    const count = Math.floor(left / minutes);
    parts.push(`${count} ${unit}${count === 1 ? "" : "s"}`);
    left %= minutes;
  }
  return parts.join(" ");
}

/** Workflow.summary: what it is, in one line. */
export function workflowSummary(w: Workflow, runtimeName: (id: string) => string | undefined = () => undefined): string {
  if (w.problem) return problemMessage(w.problem);
  const supported = w.triggers.filter(isSupported);
  if (!supported.length) return w.triggers[0] ? triggerSummary(w.triggers[0]) : "Nothing makes this run";
  let base = `${supported.map(triggerSummary).join(", and ")}, ${modeWords[w.mode]}`;
  if (w.cooldown !== undefined) base += `, at most once every ${cooldownWords(w.cooldown)}`;
  if (w.mode === "triggering") return base;
  const settings = settingsSummary(w.settings, runtimeName);
  return settings ? `${base}, ${settings}` : base;
}

/** Workflow.canFire: anything could make it run on its own. */
export function canFire(w: Workflow): boolean {
  return w.problem === undefined && w.triggers.some(isSupported);
}

function refusalNeedsAPerson(refusal: WorkflowRefusal): boolean {
  const key = Object.keys(refusal)[0];
  // `disabled`, a trigger refused by a workflow turned off (#100), is grey like the rest.
  return ["chainTooDeep", "unreadable", "folderGone", "overLimit", "settingRefused", "awaitingApproval"].includes(key ?? "");
}

/** WorkflowSummary.needsAPerson: the one row on the page that earns the colour. */
export function workflowNeedsAPerson(s: WorkflowSummary): boolean {
  if (s.isArchived) return false;
  if (s.awaitingApproval) return true;
  if (s.overLimit) return true;
  if (s.workflow.problem && "unreadable" in s.workflow.problem) return true;
  if (s.lastOutcome && "refused" in s.lastOutcome) return refusalNeedsAPerson(s.lastOutcome.refused._0);
  return false;
}

/**
 * Whether it is on (#100). Read leniently, as Swift reads it: a host from before #100 sends no
 * `isEnabled`, and every workflow it has is on.
 */
export function isOn(s: WorkflowSummary): boolean {
  return (s as { isEnabled?: boolean }).isEnabled !== false;
}

/** The window's WorkflowStatusIcon: what the mark beside the name says. */
export function workflowStatus(s: WorkflowSummary): { mark: string; words: string; tinted: boolean } {
  const tinted = workflowNeedsAPerson(s);
  if (s.isArchived) return { mark: "▣", words: "Archived", tinted };
  if (s.awaitingApproval) return { mark: "✋", words: "Waiting for your OK", tinted };
  if (!isOn(s)) return { mark: "⏸\uFE0E", words: "Turned off", tinted };
  if (s.overLimit) return { mark: "!", words: "Over the limit", tinted };
  if (tinted) return { mark: "!", words: "Needs attention", tinted };
  if (s.isRunning) return { mark: "◌", words: "Running", tinted };
  // A trigger held by its cooldown (#103): it runs once when the cooldown ends.
  if (s.holdsAFire) return { mark: "⧗", words: "Cooling down, then it runs once", tinted };
  if (!canFire(s.workflow)) return { mark: "◌", words: "Not yet supported", tinted };
  return { mark: "◷", words: "Waiting for its trigger", tinted };
}
