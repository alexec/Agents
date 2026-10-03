// A workflow's row under the sessions: Workflow.summary and canFire (Model/Workflow.swift and
// its trigger, schedule and settings words), WorkflowSummary.needsAPerson, and the window's
// status icon (WorkflowRow.swift), ported by hand and held to Fixtures/web/workflows.
//
// An event trigger (042) arrives as `unrecognised` with a dotted name, which Swift reads back as
// an event and describes from its catalogue. The page has no catalogue, so it says the event's
// name and filters instead: "When ci.finished (branch main)".
import type {
  JSONValue, Weekday, Workflow, WorkflowCause, WorkflowLimit, WorkflowOutcome, WorkflowProblem, WorkflowRefusal,
  WorkflowSchedule, WorkflowSettings, WorkflowSummary, WorkflowTriggerStored,
} from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

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

/** WorkflowTrigger.summary, with an event said by its name (see above) and its filters in words. */
export function triggerSummary(trigger: WorkflowTriggerStored,
  runtimeName: (id: string) => string | undefined = () => undefined): string {
  if ("schedule" in trigger) return scheduleSummary(trigger.schedule._0);
  if ("agentFinished" in trigger) return "When an agent finishes";
  if ("agentAskedPermission" in trigger) return "When an agent asks for permission";
  if ("agentAskedForm" in trigger) return "When an agent raises a form";
  if ("agentStopped" in trigger) return "When an agent stops without finishing";
  if ("workflowCompleted" in trigger) {
    const id = trigger.workflowCompleted.id;
    return id ? `When ${id} finishes` : "When any workflow finishes";
  }
  const { name } = trigger.unrecognised;
  if (isEvent(trigger)) {
    const phrases = eventFilters(trigger).map(([k, values]) => filterWords(name, k, values, runtimeName));
    let filters = [...phrases.filter((p) => !p.startsWith("and ")), ...phrases.filter((p) => p.startsWith("and "))].join(", ");
    if (filters.startsWith("and ")) filters = filters.slice(4);
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
  let base = `${supported.map((t) => triggerSummary(t, runtimeName)).join(", and ")}, ${modeWords[w.mode]}`;
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
  if (waitsItsTurn(s)) return { mark: "✋", words: "Over the limit", tinted };
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

// MARK: The workflow page (#98, #100): WorkflowTriggerWords.swift, WorkflowOutcome.swift and the
// window's WorkflowPage, ported by hand.

/** Whose events a kind is: EventCatalogue's scope, and the details it carries (042). */
/** What every agent event carries about its agent (EventCatalogue.context, 073). */
const context = ["labels", "runtime", "started_by"];

const catalogue: Record<string, { scope: "mac" | "project" | "either"; details: string[] }> = {
  "agent.started": { scope: "project", details: ["agent", ...context] },
  "agent.finished": { scope: "project", details: ["agent", "outcome", "afterwards", ...context] },
  "agent.asked_permission": { scope: "project", details: ["agent", ...context] },
  "agent.asked_form": { scope: "project", details: ["agent", ...context] },
  "agent.blocked": { scope: "project", details: ["agent", "waiting_on", ...context] },
  "agent.stopped": { scope: "project", details: ["agent", "by", ...context] },
  "agent.failed": { scope: "project", details: ["agent", "reason", ...context] },
  "agent.parked": { scope: "project", details: ["agent", "outcome", ...context] },
  "agent.archived": { scope: "project", details: ["agent", "by", "outcome", ...context] },
  "agent.retired": { scope: "project", details: ["agent", "because", ...context] },
  "workflow.ran": { scope: "project", details: ["workflow", "agent"] },
  "workflow.completed": { scope: "project", details: ["workflow", "agent", "outcome"] },
  "workflow.refused": { scope: "project", details: ["workflow", "reason"] },
  "branch.moved": { scope: "project", details: ["branch", "from", "to"] },
  "lease.granted": { scope: "mac", details: ["resource", "agent"] },
  "lease.released": { scope: "mac", details: ["resource", "how"] },
  "mac.sleep": { scope: "mac", details: [] },
  "mac.wake": { scope: "mac", details: [] },
  "person.away": { scope: "mac", details: ["why"] },
  "person.back": { scope: "mac", details: ["why"] },
  "cost.limit_reached": { scope: "either", details: ["limit", "agent", ...context] },
  "cost.allowance_out": { scope: "mac", details: ["runtime", "until", "retry_after", "reason"] },
  "cost.allowance_back": { scope: "mac", details: ["runtime", "how"] },
  "server.offline": { scope: "mac", details: ["server"] },
  "server.online": { scope: "mac", details: ["server"] },
};

function isCustom(name: string): boolean {
  return /^custom\.[a-z0-9_]{1,40}$/.test(name);
}

/** `subject.*`'s subject, or null for a single name (EventPattern.wholeSubject). */
function wholeSubject(name: string): string | null {
  return name.endsWith(".*") ? name.slice(0, -2) : null;
}

function kindsIn(subject: string) {
  return Object.entries(catalogue).filter(([name]) => name.startsWith(subject + "."));
}

/** Whether this version can watch for it (WorkflowTrigger.isSupported). */
export function isSupportedTrigger(trigger: WorkflowTriggerStored): boolean {
  return isSupported(trigger);
}

/** One value, or a list of them meaning any of (073); null for anything else. */
function filterValues(value: JSONValue): string[] | null {
  const one = scalar(value);
  if (one !== null) return [one];
  if (!Array.isArray(value) || value.length === 0) return null;
  const all = value.map(scalar);
  return all.every((v) => v !== null) ? (all as string[]) : null;
}

/** An event trigger's filters, each with its values, sorted by key. */
function eventFilters(trigger: WorkflowTriggerStored): [string, string[]][] {
  let found: [string, string[]][] = [];
  if (isEvent(trigger) && "unrecognised" in trigger) {
    found = Object.entries(trigger.unrecognised.keys).flatMap(([k, v]) => {
      const values = filterValues(v);
      return values === null ? [] : [[k, values] as [string, string[]]];
    });
  } else if ("workflowCompleted" in trigger && trigger.workflowCompleted.id) {
    found = [["workflow", [trigger.workflowCompleted.id]]];
  }
  return found.sort(([a], [b]) => (a < b ? -1 : 1));
}

/** WorkflowTrigger.filters as the Triggers section's capsules say them: "outcome: done | nothing_to_do". */
export function triggerFilters(trigger: WorkflowTriggerStored): [string, string][] {
  return eventFilters(trigger).map(([k, values]) => [k, values.join(" | ")]);
}

// The words a summary says a filter in (EventDetail.words, 073 FR-022).

const failedWords: Record<string, string> = {
  max_tokens: "ran out of room", max_turn_requests: "hit its limit", refusal: "refused",
  process_died: "the runtime crashed", daemon_gone: "stopped with the daemon",
  unrecognised: "stopped for a reason we do not know", stopped_by_agent: "stopped by the agent that started it",
  sign_in_refused: "its sign-in was refused", runtime_error: "the runtime reported an error",
  allowance_spent: "its allowance ran out", rate_limited: "rate limited, and still limited after retrying",
  sandbox_failed: "its sandbox could not start",
};
const refusedWords: Record<string, string> = {
  run_in_flight: "a run is still going", chain_too_deep: "its chain was too deep", archived: "it is archived",
  over_limit: "over a workflow limit", unreadable: "its file could not be read",
  trigger_not_supported: "it watches for something this version cannot",
  agent_unavailable: "the agent it would have resumed is gone",
  no_triggering_agent: "nothing triggered it, so there was no agent to resume",
  missed_while_closed: "the app was closed", folder_gone: "the project folder is not there",
  day_limit_reached: "the day's spending limit has been reached", setting_refused: "a setting it names cannot be had",
  awaiting_approval: "it is waiting for your OK",
};
const codeWords: Record<string, Record<string, string>> = {
  "agent.failed reason": failedWords,
  "workflow.refused reason": refusedWords,
  "agent.stopped by": { you: "stopped by you", cost_limit: "at its cost limit", unknown: "with no reason recorded" },
  "agent.archived by": { you: "by you", agent: "by another agent" },
};
const startedByWords: Record<string, string> = { person: "you", workflow: "a workflow", agent: "another agent" };

/** One filter in words, as the Mac's summary says it. */
function filterWords(name: string, key: string, values: string[], runtimeName: (id: string) => string | undefined): string {
  const or = (parts: string[]) => parts.join(" or ");
  const subject = wholeSubject(name);
  if (isCustom(name) || subject === "custom") return `${key} ${or(values)}`;
  const kinds = subject ? kindsIn(subject).map(([n]) => n) : [name];
  if (!kinds.some((n) => catalogue[n]?.details.includes(key))) return `${key} ${or(values)}`;
  if (context.includes(key) || ["outcome", "afterwards"].includes(key)) {
    switch (key) {
      case "labels": return `labelled ${or(values)}`;
      case "runtime": return `on ${or(values.map((id) => runtimeName(id) ?? id))}`;
      case "started_by": return `started by ${or(values.map((v) => startedByWords[v] ?? v))}`;
      case "outcome": return or(values.map((v) => v.replaceAll("_", " ")));
      case "afterwards":
        if (values.includes("park") && values.includes("stay")) return "and parked or not";
        return values[0] === "stay" ? "and not parked" : "and parked";
    }
  }
  const words = Object.assign({}, ...kinds.map((n) => codeWords[`${n} ${key}`] ?? {})) as Record<string, string>;
  if (Object.keys(words).length) return or(values.map((v) => words[v] ?? v));
  return `${key} ${or(values)}`;
}

/** WorkflowTrigger.listensIn. */
export function listensIn(trigger: WorkflowTriggerStored): "mac" | "project" | "either" | null {
  if ("schedule" in trigger) return null;
  if (!("unrecognised" in trigger)) return "project";
  if (!isEvent(trigger)) return null;
  const name = trigger.unrecognised.name;
  if (isCustom(name)) return "project";
  const subject = wholeSubject(name);
  if (subject) {
    if (subject === "custom") return "project";
    const scopes = new Set(kindsIn(subject).map(([, k]) => k.scope));
    return scopes.size === 1 ? [...scopes][0]! : "either";
  }
  return catalogue[name]?.scope ?? null;
}

/** "In work, on this Mac", as the window's scopeLine says it; null for nothing to say. */
export function scopeLine(trigger: WorkflowTriggerStored, project: string, host: string): string | null {
  if ("schedule" in trigger) return `By the clock on ${host}`;
  switch (listensIn(trigger)) {
    case "project": return `In ${project}, on ${host}`;
    case "mac": return `Anywhere on ${host}, so it runs in every project`;
    case "either": return `In ${project}, or anywhere on ${host}`;
    default: return null;
  }
}

/** WorkflowTrigger.resumedAgent: which agent a `triggering` run resumes. */
export function resumedAgent(trigger: WorkflowTriggerStored): string {
  if ("schedule" in trigger) return "A clock has no agent to resume, so this never runs it";
  if ("agentFinished" in trigger) return "Resumes the agent that finished";
  if ("agentAskedPermission" in trigger) return "Resumes the agent that asked";
  if ("agentAskedForm" in trigger) return "Resumes the agent that raised the form";
  if ("agentStopped" in trigger) return "Resumes the agent that stopped";
  if ("workflowCompleted" in trigger) return "Resumes the agent the finished run started";
  if (!isEvent(trigger)) return "Never runs it";
  const name = trigger.unrecognised.name;
  const subject = wholeSubject(name);
  if (isCustom(name) || subject === "custom") return "Resumes the agent that published it";
  const kinds = subject ? kindsIn(subject).map(([, k]) => k) : catalogue[name] ? [catalogue[name]!] : [];
  const carrying = kinds.filter((k) => k.details.includes("agent"));
  if (!carrying.length) return "These events are about no agent, so this never runs it";
  if (carrying.length < kinds.length) return "Resumes the agent it is about, when there is one";
  return "Resumes the agent it is about";
}

/** The symbol beside a trigger, as a glyph (the window's symbol(for:)). */
export function triggerGlyph(trigger: WorkflowTriggerStored): string {
  if ("schedule" in trigger) return "◷";
  if ("workflowCompleted" in trigger) return "⟳";
  if (!("unrecognised" in trigger)) return "●";
  if (!isEvent(trigger)) return "?";
  const subject = trigger.unrecognised.name.split(".")[0];
  return subject === "agent" ? "●" : subject === "workflow" ? "⟳" : subject === "branch" ? "⎇" : subject === "custom" ? "✦" : "⌘";
}

const named = new Intl.RelativeTimeFormat("en", { numeric: "auto" });

/** Foundation's `.relative(presentation: .named)`: "tomorrow", "in 3 days", "2 hours ago". */
export function namedRelative(date: Date, now = new Date()): string {
  const seconds = (date.getTime() - now.getTime()) / 1000;
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ["year", 31_536_000], ["month", 2_592_000], ["week", 604_800], ["day", 86_400], ["hour", 3_600], ["minute", 60],
  ];
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size) return named.format(Math.round(seconds / size), unit);
  }
  return named.format(Math.round(seconds), "second");
}

/** When a schedule is next due, or why it is not (the window's nextLine). */
export function nextLine(summary: WorkflowSummary, index: number, now = new Date()): string {
  if (summary.isArchived) return "Archived — no next time";
  if (!isOn(summary)) return "Off — no next time";
  if (summary.workflow.problem) return "Never, until the file is fixed";
  if (summary.awaitingApproval) return "No next time until you approve it";
  if (summary.overLimit) return "Over the limit — no next time";
  const byTrigger = summary.nextFireAtByTrigger ?? [];
  const schedules = summary.workflow.triggers.filter((t) => "schedule" in t).length;
  const due = index < byTrigger.length ? byTrigger[index] : schedules === 1 ? summary.nextFireAt : undefined;
  if (due === undefined || due === null) return "No next time";
  const at = fromWireDate(due);
  return `Next ${namedRelative(at, now)} · ${at.toLocaleString("en", { dateStyle: "medium", timeStyle: "short" })}`;
}

/** WorkflowCause.phrase: what set a run off, after "Last ran 2 hours ago". */
export function causePhrase(cause: WorkflowCause): string {
  if ("byHand" in cause) return "by hand, with Run now";
  const trigger = cause.trigger._0;
  if ("schedule" in trigger) return "on its schedule";
  if (isEvent(trigger) && "unrecognised" in trigger) {
    return "on " + [trigger.unrecognised.name, ...eventFilters(trigger).map(([k, v]) => `${k} ${v.join("|")}`)].join(" ");
  }
  const said = triggerSummary(trigger);
  return said.charAt(0).toLowerCase() + said.slice(1);
}

/** "Last ran 2 hours ago, on its schedule", or that it has not. */
export function lastRanLine(summary: WorkflowSummary, now = new Date()): string {
  if (summary.lastFiredAt === undefined) return "Has not run yet.";
  const when = `Last ran ${namedRelative(fromWireDate(summary.lastFiredAt), now)}`;
  return summary.lastFiredBy ? `${when}, ${causePhrase(summary.lastFiredBy)}` : when;
}

const limitAllowed: Record<WorkflowLimit, number> = { project: 3, total: 10 };

/** WorkflowSummary.waitsItsTurn (#132): waiting behind the three a project may have waiting. */
export function waitsItsTurn(s: WorkflowSummary): boolean {
  return !!s.awaitingApproval && s.overLimit === "project";
}

/** WorkflowSummary.turnedOffSentence (#100). */
export const turnedOffSentence = "Turned off — none of its triggers run it. "
  + "It still counts towards the workflow limits, and Run now still runs it";

/** WorkflowOffReason.sentence (#124): why it is off, or null for the person's own switch. */
export function offReasonSentence(s: WorkflowSummary): string | null {
  switch ((s as { offReason?: string }).offReason) {
    case "file": return "Off: its file says enabled: false. Turn it on when you are ready";
    case "writtenByAgent": return "Off: written by an agent. Turn it on when you are ready";
    case "agent": return "Off: an agent turned it off";
    default: return null;
  }
}

/** WorkflowSummary.switchesSentence (#125): the switch is a line in the workflow's file. */
export function switchesSentence(s: WorkflowSummary): string {
  return `Enabled and Archive are saved in .agents/workflows/${s.workflow.workflowID}.md, a file in this project you may commit`;
}

/** The instance WorkflowSummary.turnedOffSentence: led by why, when there is a why. */
export function turnedOffSentenceFor(s: WorkflowSummary): string {
  const why = offReasonSentence(s);
  if (!why) return turnedOffSentence;
  return `${why}. None of its triggers run it until it is turned on. `
    + "It still counts towards the workflow limits, and Run now still runs it";
}

function limitSentence(limit: WorkflowLimit): string {
  return limit === "project" ? `This project already has ${limitAllowed.project} workflows waiting for approval`
    : `${limitAllowed.total} workflows are already running, across every project`;
}

function limitRemedy(limit: WorkflowLimit): string {
  return limit === "project" ? `Approve or remove one of the ${limitAllowed.project} workflows waiting for approval first`
    : "Archive one, in any project, to let it run";
}

/** WorkflowRefusal.message. */
export function refusalMessage(refusal: WorkflowRefusal): string {
  if ("chainTooDeep" in refusal) return `this chain is already ${refusal.chainTooDeep.depth} deep`;
  if ("runInFlight" in refusal) return "a run is still going";
  if ("archived" in refusal) return "it is archived";
  if ("disabled" in refusal) return "it is turned off";
  if ("overLimit" in refusal) {
    return refusal.overLimit._0 === "project" ? `this project already has ${limitAllowed.project} workflows waiting for approval`
      : `${limitAllowed.total} workflows are already running, across every project`;
  }
  if ("unreadable" in refusal) return refusal.unreadable._0;
  if ("triggerNotSupported" in refusal) return `"${refusal.triggerNotSupported.name}" is not something this version can watch for`;
  if ("agentUnavailable" in refusal) return "the agent it would have resumed is gone";
  if ("noTriggeringAgent" in refusal) return "nothing triggered it, so there was no agent to resume";
  if ("missedWhileClosed" in refusal) return "the app was closed";
  if ("folderGone" in refusal) return "the project folder is not there";
  if ("dayLimitReached" in refusal) return "the day's spending limit has been reached";
  if ("settingRefused" in refusal) return refusal.settingRefused.detail;
  return "it is waiting for your OK";
}

/** WorkflowOutcome.summary for a refusal. */
function refusedSummary(outcome: Extract<WorkflowOutcome, { refused: unknown }>): string {
  const { _0: refusal, repeats } = outcome.refused;
  const many = repeats > 1;
  if ("missedWhileClosed" in refusal) return many ? `Missed ${repeats} times — ${refusalMessage(refusal)}` : `Missed — ${refusalMessage(refusal)}`;
  return many ? `Did not run ${repeats} times — ${refusalMessage(refusal)}` : `Did not run — ${refusalMessage(refusal)}`;
}

/** What is happening to it, in one line (the window's happening). */
export function happening(summary: WorkflowSummary, now = new Date()): string | null {
  const parts: string[] = [];
  if (summary.isArchived) parts.push("Archived — it will not run until it is restored");
  else if (waitsItsTurn(summary) && summary.overLimit) {
    return `${limitSentence(summary.overLimit)}. ${limitRemedy(summary.overLimit)}`;
  } else if (summary.awaitingApproval) {
    const waiting = (summary.awaitingApproval.isNew ? "New" : "Changed since you approved it") + " — approve it on its page to let it run";
    const why = offReasonSentence(summary);
    return why ? `${waiting} · ${why}` : waiting;
  } else if (!isOn(summary)) parts.push(turnedOffSentenceFor(summary));
  else if (summary.overLimit) parts.push(`${limitSentence(summary.overLimit)}. ${limitRemedy(summary.overLimit)}`);
  else if (summary.nextFireAt !== undefined) parts.push(`Next ${namedRelative(fromWireDate(summary.nextFireAt), now)}`);
  const outcome = summary.lastOutcome;
  if (outcome) {
    if ("ran" in outcome) parts.push(`Ran ${namedRelative(fromWireDate(outcome.ran.at), now)}`);
    else parts.push(refusedSummary(outcome));
  }
  return parts.length ? parts.join(" · ") : null;
}

// MARK: The page's status card and what it does (#142): WorkflowStatus.swift, ported by hand.

/** One line of the status card: what is true, and whether it wants a person. */
export interface StatusLine {
  glyph: string;
  text: string;
  detail?: string | undefined;
  tint?: "attention" | "failure" | undefined;
  /** The session "Open the agent" goes to, on the line that has one. */
  agentID?: string | undefined;
}

function shortTime(date: Date): string {
  return date.toLocaleTimeString("en", { hour: "numeric", minute: "2-digit" });
}

/** WorkflowSummary.statusLines: what stops it, then what it is doing, then when it next runs. */
export function workflowStatusLines(s: WorkflowSummary, now = new Date()): StatusLine[] {
  const w = s.workflow;
  const lines: StatusLine[] = [];
  if (s.isArchived) {
    lines.push({ glyph: "▣", text: "Archived — it will not run until it is brought back", detail: "Archived workflows count towards neither limit" });
  }
  if (w.problem) {
    const needs = "unreadable" in w.problem;
    lines.push({ glyph: "⚠︎", text: problemMessage(w.problem),
      detail: needs ? "Fix its file to let it run" : "Left alone until this version knows it", tint: needs ? "failure" : undefined });
  }
  if (waitsItsTurn(s) && s.overLimit) {
    lines.push({ glyph: "⧗", text: `Waiting its turn: ${limitSentence(s.overLimit)}`, detail: limitRemedy(s.overLimit), tint: "attention" });
  } else if (s.awaitingApproval) {
    lines.push({ glyph: "✋", text: s.awaitingApproval.isNew ? "New — waiting for your OK" : "Changed since you approved it — waiting for your OK",
      detail: "Read the prompt and settings below, then Approve to let it run", tint: "attention" });
  }
  if (!s.isArchived) lines.push(enabledLine(s));
  if (s.overLimit && !waitsItsTurn(s)) {
    lines.push({ glyph: "⚠︎", text: `Over the limit: ${limitSentence(s.overLimit)}`, detail: limitRemedy(s.overLimit), tint: "attention" });
  }
  if (s.isRunning) {
    const outcome = s.lastOutcome;
    lines.push({ glyph: "▶︎", text: "Running now", agentID: outcome && "ran" in outcome ? outcome.ran.agentID : undefined });
  }
  if (s.cooldownEndsAt !== undefined) {
    lines.push({ glyph: "⧗", text: `Cooling down until ${shortTime(fromWireDate(s.cooldownEndsAt))}`,
      detail: s.holdsAFire ? "A trigger came in meanwhile; it runs once then" : undefined });
  }
  const outcome = s.lastOutcome;
  if (outcome && "refused" in outcome) {
    lines.push({ glyph: "✕", text: refusedSummary(outcome),
      tint: workflowNeedsAPerson(s) && !s.awaitingApproval && !s.overLimit ? "attention" : undefined });
  }
  lines.push(nextRunLine(s, now));
  return lines;
}

function enabledLine(s: WorkflowSummary): StatusLine {
  const file = `.agents/workflows/${s.workflow.workflowID}.md`;
  if (isOn(s)) {
    return { glyph: "✓", text: s.workflow.enabled === true ? "On — its file says enabled: true" : "On — its file does not say enabled:, so it is on",
      detail: `Enabled writes enabled: false into ${file}` };
  }
  const why = (s as { offReason?: string }).offReason;
  const text = why === "file" ? "Off — its file says enabled: false"
    : why === "writtenByAgent" ? "Off — written by an agent, so it arrived off"
    : why === "agent" ? "Off — an agent turned it off"
    : "Off — turned off here";
  return { glyph: "⏸︎", text, detail: "None of its triggers run it; Run now still does. It still counts towards the workflow limits" };
}

function nextRunLine(s: WorkflowSummary, now: Date): StatusLine {
  const blocked = s.isArchived || !isOn(s) || s.workflow.problem !== undefined || !!s.awaitingApproval || !!s.overLimit;
  if (s.nextFireAt !== undefined && !blocked) {
    const at = fromWireDate(s.nextFireAt);
    return { glyph: "◷", text: `Next run ${namedRelative(at, now)}`, detail: at.toLocaleString("en", { dateStyle: "medium", timeStyle: "short" }) };
  }
  if (!blocked && canFire(s.workflow)) return { glyph: "ϟ", text: "Runs when one of its triggers fires" };
  return { glyph: "◷", text: "No next run", detail: blocked ? "Until what is above changes" : "Nothing it waits for can run it; Run now still does" };
}

/** WorkflowMode.words: who gets the prompt. */
export function agentModeWords(mode: Workflow["mode"]): string {
  return mode === "new" ? "Starts a new agent each run"
    : mode === "standing" ? "Sends each run to its standing agent"
    : "Resumes the agent that triggered it";
}

/** Workflow.labelsNote. */
export function labelsNote(w: Workflow): string {
  if (w.settings.labels.length === 0) return "No labels: each run's agent starts with none.";
  return w.mode === "new" ? "Each run's new agent gets these labels." : "Given to an agent this workflow starts; one it reuses keeps its own.";
}

/** Workflow.unknownLines: each key the version does not know, as one line of what the file says. */
export function unknownLines(w: Workflow): string[] {
  return Object.keys(w.unknownFields ?? {}).sort().map((key) => {
    const value = w.unknownFields[key];
    const text = typeof value === "string" ? value : value === null ? "null" : JSON.stringify(value);
    return `${key}: ${text}`;
  });
}

/** WorkflowSummary.cooldownSentence: how long, when it ends, and whether a fire is held. */
export function cooldownSentence(s: WorkflowSummary): string | null {
  const cooldown = s.workflow.cooldown;
  if (cooldown === undefined) return null;
  const words = cooldownWords(cooldown);
  let sentence = `Cooldown ${words}: at most one run starts in any ${words}`;
  if (s.cooldownEndsAt !== undefined) {
    const end = shortTime(fromWireDate(s.cooldownEndsAt));
    sentence += s.holdsAFire ? `. Cooling down until ${end}, then it runs once for what came in meanwhile` : `. Cooling down until ${end}`;
  } else if (s.holdsAFire) {
    sentence += ". It runs once more for what came in while this run was going";
  }
  return sentence;
}

/** The settings the window's form edits, as name and value, read-only here (#142). */
export function settingRows(w: Workflow, runtimeName: (id: string) => string | undefined): [string, string][] {
  const st = w.settings;
  const runtime = st.runtimeID ?? defaultRuntime;
  const rows: [string, string][] = [
    ["Runtime", (runtimeName(runtime) ?? runtime) + (st.runtimeID ? "" : " (default)")],
    ["Permission mode", st.permissionMode ?? "Runtime default"],
    ["Model", st.model ?? "Runtime default"],
    ["Effort", st.effort ?? "Runtime default"],
  ];
  for (const [id, value] of Object.entries(st.options).sort(([a], [b]) => a.localeCompare(b))) rows.push([id, value]);
  return rows;
}
