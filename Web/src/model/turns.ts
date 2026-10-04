// What the chat draws: TranscriptDisplayBuilder and TranscriptItem (Model/TranscriptDisplay.swift),
// turns and TurnParts (Model/OutcomePage.swift), and a tool call's line, ported by hand and held to
// Fixtures/web/turns (research R7).
import type { AgentState, BackgroundItem, ToolCall, TranscriptEntry, TranscriptEntryKind, TurnSummary } from "../protocol/generated";

export type Item =
  | { kind: "entry"; id: string; entry: TranscriptEntry }
  | { kind: "run"; id: string; calls: ToolCall[] };

type KindName = TranscriptEntryKind extends infer K ? (K extends Record<infer N, unknown> ? N : never) : never;

/** The case of an entry's kind: "agentMessage", "toolCall", … A kind a newer build wrote reads as its own name. */
export function kindOf(entry: TranscriptEntry): KindName {
  return Object.keys(entry.kind)[0] as KindName;
}

/** The kind's fields, when it is `name`. */
export function fields<N extends KindName>(entry: TranscriptEntry, name: N):
  Extract<TranscriptEntryKind, Record<N, unknown>>[N] | undefined {
  return (entry.kind as Record<string, unknown>)[name] as never;
}

const finishTurn = "finish_turn";
const retiredEndOfTurn = ["suggest_next_prompts", "report_outcome"];

function nameOrTitle(call: ToolCall): string {
  return call.name ?? call.title;
}

/** ToolCall.describedAs: what the agent said the call was for. */
export function describedAs(call: ToolCall): string | undefined {
  const input = call.rawInput;
  if (input === null || typeof input !== "object" || Array.isArray(input)) return undefined;
  const text = input["description"];
  if (typeof text !== "string") return undefined;
  const trimmed = text.trim();
  return trimmed ? trimmed : undefined;
}

/** ToolCall.line: the description where the agent wrote one, else the runtime's title. */
export function callLine(call: ToolCall): string {
  const input = call.rawInput;
  if (input !== null && typeof input === "object" && !Array.isArray(input)) {
    const text = input["description"];
    if (typeof text === "string" && text.trim()) return text;
  }
  return call.title;
}

function capitalized(word: string): string {
  // Foundation's `capitalized`: the first letter up, the rest down.
  return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase();
}

function readableToolName(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const words = value.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/[_./-]+/g, " ").split(/\s+/).filter(Boolean);
  return words.length ? words.map(capitalized).join(" ") : undefined;
}

const kindLabels: Record<string, string> = {
  read: "Read file", edit: "Edit file", delete: "Delete file", move: "Move file",
  search: "Search files", execute: "Run command", fetch: "Fetch data",
};

/** ToolCall.turnLine: the one line a tool call is drawn as in a turn. */
export function turnLine(call: ToolCall): string {
  const described = describedAs(call);
  if (described) return described;
  const kind = call.kind?.trim().toLowerCase();
  if (kind) {
    const name = readableToolName(call.name);
    let label = kindLabels[kind];
    if (label === undefined) {
      label = kind === "other" ? name ?? "Used a tool" : name ?? readableToolName(kind) ?? "Used a tool";
    }
    if (name && !label.toLowerCase().includes(name.toLowerCase())) return `${label} (${name})`;
    return label;
  }
  return readableToolName(call.name) ?? "Used a tool";
}

/** Nothing a line could show (ToolCall.saysNothing). */
function saysNothing(call: ToolCall): boolean {
  return (call.title === "" || call.title === "Tool call") && call.name === undefined && call.kind === undefined
    && call.status === undefined && (call.content ?? []).length === 0 && (call.locations ?? []).length === 0
    && call.rawInput === undefined && call.rawOutput === undefined;
}

/** An update is the same call further along, carrying only what changed (TranscriptEntry.merge). */
function merge(update: ToolCall, existing: ToolCall): ToolCall {
  const merged: ToolCall = { ...existing };
  if (update.title !== "" && update.title !== "Tool call") merged.title = update.title;
  if (update.name !== undefined) merged.name = update.name;
  if (update.kind !== undefined) merged.kind = update.kind;
  if (update.status !== undefined) merged.status = update.status;
  if ((update.content ?? []).length) merged.content = [...(existing.content ?? []), ...(update.content ?? [])];
  if ((update.locations ?? []).length) merged.locations = update.locations;
  if (update.rawInput !== undefined) merged.rawInput = update.rawInput;
  if (update.rawOutput !== undefined) merged.rawOutput = update.rawOutput;
  if (update.raw !== undefined) merged.raw = update.raw;
  return merged;
}

const startingPrefix = "Starting ";
const startingSuffix = "…";
export const pickedBackUp = "Picked the conversation back up.";
const stoppedWithDaemon = "This agent was working when the daemon stopped, so it stopped too.";

/** RuntimeNote.isPassing. */
function noteIsPassing(text: string): boolean {
  if (text === pickedBackUp || text === stoppedWithDaemon) return true;
  return text.startsWith(startingPrefix) && text.endsWith(startingSuffix)
    && [...text].length > [...startingPrefix].length + [...startingSuffix].length;
}

/** TranscriptEntry.isPassing: about a moment rather than what happened. */
function entryIsPassing(entry: TranscriptEntry): boolean {
  const state = fields(entry, "stateChanged");
  if (state) return state._0 === "starting" || state._0 === "running" || (state._0 === "stopped" && state.reason === "daemonGone");
  const note = fields(entry, "runtimeNote");
  return note ? noteIsPassing(note._0) : false;
}

const knownKinds = new Set(["userMessage", "agentMessage", "agentThought", "toolCall", "toolCallUpdate", "planUpdated",
  "usageRecorded", "servedRequest", "elicitationAsked", "elicitationAnswered", "compaction", "notice", "permissionAsked",
  "permissionAnswered", "optionChanged", "stateChanged", "background", "workReported", "runtimeNote", "poolSwitch",
  "sandboxFailure", "handoff", "settingsChanged"]);

function isDrawn(item: Item): boolean {
  return item.kind === "run" || knownKinds.has(kindOf(item.entry));
}

export function isPassing(item: Item): boolean {
  return item.kind === "entry" && entryIsPassing(item.entry);
}

/** Chunks of one message joined (TranscriptEntry.join). */
function join(entry: TranscriptEntry, previous: TranscriptEntry | undefined): TranscriptEntry | undefined {
  if (!previous) return undefined;
  const first = fields(previous, "agentMessage");
  const next = fields(entry, "agentMessage");
  if (first && next && first.messageID === next.messageID) {
    return { ...previous, kind: { agentMessage: { ...first, text: first.text + next.text,
      blocks: [...(first.blocks ?? []), ...(next.blocks ?? [])] } } };
  }
  const thought = fields(previous, "agentThought");
  const more = fields(entry, "agentThought");
  if (thought && more && thought.messageID === more.messageID) {
    return { ...previous, kind: { agentThought: { ...thought, text: thought.text + more.text } } };
  }
  return undefined;
}

function isRunning(item: BackgroundItem): boolean {
  return item.state === "running" || item.state === "paused";
}

/** The page as the chat draws it, kept up as entries arrive (TranscriptDisplayBuilder). */
export class DisplayBuilder {
  private drawn: Item[] = [];
  private run: ToolCall[] = [];
  private runID: string | undefined;
  private suppressed = new Set<string>();
  private closedRunAt = new Map<string, number>();
  private last: TranscriptEntry | undefined;

  constructor(readonly subagent?: string) {}

  add(entry: TranscriptEntry): void {
    if (entry.subagentID !== this.subagent) return;
    // A stub for an entry too big to send (#203) holds its place and draws nothing.
    if ("oversized" in entry.kind) return;
    const joined = join(entry, this.last);
    if (joined) {
      this.last = joined;
      if (this.drawn.length) this.drawn[this.drawn.length - 1] = { kind: "entry", id: joined.id, entry: joined };
      return;
    }
    this.last = entry;
    const kind = kindOf(entry);
    if (kind === "toolCall" || kind === "toolCallUpdate") {
      const call = (fields(entry, "toolCall") ?? fields(entry, "toolCallUpdate"))!._0;
      const name = nameOrTitle(call);
      if (name.endsWith(finishTurn) || retiredEndOfTurn.some((retired) => name.endsWith(retired))) {
        if (call.toolCallID !== undefined) this.suppressed.add(call.toolCallID);
        return;
      }
      const id = call.toolCallID;
      if (id !== undefined && this.suppressed.has(id)) return;
      const existing = id === undefined ? -1 : this.run.findIndex((c) => c.toolCallID === id);
      if (existing >= 0) {
        this.run[existing] = merge(call, this.run[existing]!);
      } else if (kind === "toolCallUpdate" && id !== undefined && this.mergeIntoClosedRun(call, id)) {
        return;
      } else if (kind === "toolCallUpdate" && saysNothing(call)) {
        return;
      } else {
        this.run.push(call);
      }
      if (this.runID === undefined) this.runID = entry.id;
      return;
    }
    const background = fields(entry, "background");
    if (background && isRunning(background._0) && background._0.kind === "task" && background._0.toolCallID !== undefined) return;
    if (kind === "optionChanged") return;
    const served = fields(entry, "servedRequest");
    if (served && "readFile" in served._0.kind && "served" in served._0.outcome) return;
    const state = fields(entry, "stateChanged");
    if ((state && state._0 === "finished") || kind === "usageRecorded") {
      this.closeRun();
      while (this.drawn.length && isPassing(this.drawn[this.drawn.length - 1]!)) this.drawn.pop();
      return;
    }
    this.closeRun();
    this.drawn.push({ kind: "entry", id: entry.id, entry });
  }

  private mergeIntoClosedRun(update: ToolCall, id: string): boolean {
    const at = this.closedRunAt.get(id);
    if (at === undefined) return false;
    const item = this.drawn[at];
    if (!item || item.kind !== "run") return false;
    const index = item.calls.findIndex((c) => c.toolCallID === id);
    if (index < 0) return false;
    const calls = [...item.calls];
    calls[index] = merge(update, calls[index]!);
    this.drawn[at] = { kind: "run", id: item.id, calls };
    return true;
  }

  private closeRun(): void {
    if (!this.run.length || this.runID === undefined) return;
    for (const call of this.run) if (call.toolCallID !== undefined) this.closedRunAt.set(call.toolCallID, this.drawn.length);
    this.drawn.push({ kind: "run", id: this.runID, calls: this.run });
    this.run = [];
    this.runID = undefined;
  }

  /** Everything drawn, the open run after it, and passing lines since superseded left out. */
  get items(): Item[] {
    const all = [...this.drawn];
    if (this.run.length && this.runID !== undefined) all.push({ kind: "run", id: this.runID, calls: [...this.run] });
    return withoutSupersededPassingLines(all);
  }
}

function withoutSupersededPassingLines(items: Item[]): Item[] {
  let latest = -1;
  for (let i = items.length - 1; i >= 0; i--) if (isDrawn(items[i]!)) { latest = i; break; }
  if (latest < 0) return items;
  return items.filter((item, offset) => !isPassing(item) || offset === latest);
}

/** TranscriptEntry.display: a page folded from the top. */
export function display(entries: readonly TranscriptEntry[], subagent?: string): Item[] {
  const builder = new DisplayBuilder(subagent);
  for (const entry of entries) builder.add(entry);
  return builder.items;
}

export function isThought(item: Item): boolean {
  return item.kind === "entry" && kindOf(item.entry) === "agentThought";
}

/** Runs with nothing drawn between them are one run, under the first run's id. */
export function joiningAdjacentToolRuns(items: readonly Item[]): Item[] {
  const kept: Item[] = [];
  for (const item of items) {
    const last = kept[kept.length - 1];
    if (item.kind === "run" && last?.kind === "run") {
      kept[kept.length - 1] = { kind: "run", id: last.id, calls: [...last.calls, ...item.calls] };
    } else {
      kept.push(item);
    }
  }
  return kept;
}

export function omittingThoughts(items: readonly Item[]): Item[] {
  return joiningAdjacentToolRuns(items.filter((item) => !isThought(item)));
}

export function isPersonsAsk(item: Item): boolean {
  if (item.kind !== "entry") return false;
  const message = fields(item.entry, "userMessage");
  return message !== undefined && (message.from ?? "person") === "person";
}

function isAgentMessage(item: Item): boolean {
  return item.kind === "entry" && kindOf(item.entry) === "agentMessage";
}

/** How the turn went, or the person's own answer: drawn at every level (069). */
export function isOutcome(item: Item): boolean {
  if (item.kind !== "entry") return false;
  const kind = kindOf(item.entry);
  if (kind === "elicitationAnswered" || kind === "workReported" || kind === "sandboxFailure") return true;
  const state = fields(item.entry, "stateChanged");
  if (state) return state._0 === "stopped";
  const notice = fields(item.entry, "notice");
  return notice ? notice._0.severity === "error" : false;
}

/** Whether a turn draws it at all: a state passed through is not a step; a stop is kept. */
export function isInTurn(item: Item): boolean {
  if (item.kind !== "entry") return true;
  const state = fields(item.entry, "stateChanged");
  return state ? state._0 === "stopped" : true;
}

function isReport(item: Item): boolean {
  return item.kind === "entry" && kindOf(item.entry) === "workReported";
}

export interface ChatTurn {
  id: string;
  ask?: Item;
  items: Item[];
  /** A stored turn's outcome and step count, drawn before its entries are in hand. */
  storedOutcome?: Item[];
  storedStepCount?: number;
  range?: { start: number; end: number };
}

/** The page cut into turns, one at each thing the person typed. */
export function turns(items: readonly Item[]): ChatTurn[] {
  const result: ChatTurn[] = [];
  let current: Item[] = [];
  const close = () => {
    const first = current[0];
    if (!first) return;
    const ask = isPersonsAsk(first) ? first : undefined;
    result.push({ id: first.id, ...(ask ? { ask } : {}), items: current.slice(ask ? 1 : 0) });
  };
  for (const item of items) {
    if (isPersonsAsk(item)) {
      close();
      current = [item];
    } else {
      current.push(item);
    }
  }
  close();
  return result;
}

function entryItem(entry: TranscriptEntry): Item {
  return { kind: "entry", id: entry.id, entry };
}

/** ChatTurn(summary): a stored turn, drawn from its outcome until opened. */
export function storedTurn(summary: TurnSummary): ChatTurn {
  const outcome = summary.outcome ?? summary.concise ?? (summary.last ? [summary.last] : []);
  return {
    id: summary.id,
    ...(summary.ask ? { ask: entryItem(summary.ask) } : {}),
    items: [],
    storedOutcome: outcome.map(entryItem),
    ...(summary.steps !== undefined ? { storedStepCount: summary.steps } : {}),
    range: { start: summary.start, end: summary.end },
  };
}

/**
 * `next`, with each turn that has not changed since `previous` the very object it was, so a
 * chat redraws only the turn an entry landed in (#170). A turn is unchanged when its ask and
 * every one of its items are the same objects: the fold keeps an item as it was until it grows.
 */
export function keepingTurns(next: readonly ChatTurn[], previous: readonly ChatTurn[]): ChatTurn[] {
  if (!previous.length) return [...next];
  const held = new Map(previous.map((turn) => [turn.id, turn]));
  return next.map((turn) => {
    const was = held.get(turn.id);
    return was && was.ask === turn.ask && sameItems(was.items, turn.items) ? was : turn;
  });
}

function sameItems(a: readonly Item[], b: readonly Item[]): boolean {
  return a.length === b.length && a.every((item, index) => item === b[index]);
}

export function isSummaryOnly(turn: ChatTurn): boolean {
  return turn.items.length === 0 && turn.range !== undefined;
}

/** What a turn draws of its items: passing lines only while it is live. */
export function drawnInTurn(items: readonly Item[], isLive: boolean): Item[] {
  return items.filter((item) => isInTurn(item) && (isLive || !isPassing(item)));
}

function reply(items: readonly Item[], isLive: boolean): number[] {
  const run: number[] = [];
  for (let index = items.length - 1; index >= 0; index--) {
    if (isAgentMessage(items[index]!)) run.unshift(index);
    else if (!isOutcome(items[index]!)) break;
  }
  if (run.length || isLive) return run;
  for (let index = items.length - 1; index >= 0; index--) if (isAgentMessage(items[index]!)) return [index];
  return [];
}

export interface TurnParts {
  /** The answers, the reply and how it went, the report last. */
  outcome: Item[];
  /** Step lines behind the control; thinking is not counted. */
  stepCount: number;
  /** The latest step, while the turn runs and has said nothing after it. */
  live?: Item;
}

/** TurnParts(items, isLive:). */
export function turnParts(items: readonly Item[], isLive: boolean): TurnParts {
  const shown = drawnInTurn(items, isLive).filter((item) => !isThought(item));
  const replied = new Set(reply(shown, isLive));
  const outcome: Item[] = [];
  const reports: Item[] = [];
  let steps = 0;
  shown.forEach((item, index) => {
    if (isReport(item)) reports.push(item);
    else if (replied.has(index) || isOutcome(item)) outcome.push(item);
    else if (item.kind === "run") steps += item.calls.length;
    else steps += 1;
  });
  let live: Item | undefined;
  if (isLive && replied.size === 0) {
    for (let i = shown.length - 1; i >= 0; i--) if (!isOutcome(shown[i]!)) { live = shown[i]; break; }
  }
  return { outcome: [...outcome, ...reports], stepCount: steps, ...(live ? { live } : {}) };
}

/** Whether the conversation's last turn is still going. */
export function isWorking(state: AgentState): boolean {
  return state === "running" || state === "starting" || state === "waitingOnUser";
}
