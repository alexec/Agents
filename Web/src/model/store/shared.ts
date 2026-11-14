// Shared by the slices of the model: what the page holds and what each notification means: AgentsModel (Client/AgentsModel.swift),
// ported by hand for the notifications the web remote hears and held to Fixtures/web/reducer
// (research R7). Nothing here decides anything; the hosts do.
import { pageSize } from "../archivedPage";
import type { Agent, TranscriptEntry, TurnSummary, JSONValue, Request as PersonRequest } from "../../protocol/generated";
import { isPersonsAsk, storedTurn, type ChatTurn } from "../turns";
import { folds } from "../folds";
import { pruneProjectFolders } from "../projects";



/** What this page keeps by folder on a host, kept to the folders it lists (#3750). */
export function pruneFolderKeys(host: string, folders: readonly string[]): void {
  folds.prune(host, folders);
  pruneProjectFolders(globalThis.window?.localStorage, host, folders);
}


/** DaemonAPI.SandboxWillNotStart, a start's refusal when its runtime's sandbox will not start, with its sentence. */
/** What New Machine makes, as its sheet has it (#4634). */
export interface NewMachineDraft { provider: string; name: string; options: Record<string, JSONValue> }
/** The New Machine sheet up (#4634): on a provider (none for the default one), or again on a refused make's choices. */
export interface NewMachineAsk { provider?: string; again?: NewMachineDraft; problem?: string }
export interface SandboxWillNotStart { runtimeID: string; detail: string; offOffered: boolean; message: string }

export function isSandboxRefusal(data: unknown): data is Omit<SandboxWillNotStart, "message"> {
  const d = data as Partial<SandboxWillNotStart> | null | undefined;
  return typeof d?.runtimeID === "string" && typeof d.detail === "string" && typeof d.offOffered === "boolean";
}

/** How many finished turns a chat opens with, as the window's (#90). */
export const openingTurns = 12;

/** How many entries one opened turn asks for, the last of them first (#291). Earlier ones come on ask. */
export const turnPage = 200;
/** How long the pointer stays on a row before its chat is fetched (#4795). */
export const prefetchAfter = 100;
/** The chats fetched before they are opened that are held, and for how long (#4795). */
export const prefetchKept = 8;
export const prefetchFresh = 60_000;

/** The rows before and after `session` in `list` (#4795): the ones opened next. None when it is not in it. */
export function neighbours(session: string, list: readonly string[]): string[] {
  const at = list.indexOf(session);
  if (at < 0) return [];
  return [list[at + 1], list[at - 1]].filter((id): id is string => id !== undefined && id !== session);
}

/** How many opened turns' entries a chat keeps. A turn closed, or past this, is read again when opened. */
export const openTurnsHeld = 8;

/**
 * How much history a chat keeps while the reader is scrolled up (#291). Past this, earlier pages
 * wait until they go back to the end, which lets the front go.
 */
export const historyEntriesCap = 1_600;
export const historyTurnsCap = 200;

/** How many events a host's list keeps as new ones come, and how many paging back brings in (#3650; the window's). */
export const eventsKept = 1_000;
export const eventsPagedMost = 5_000;

/** A page of a finished turn's entries (#291). */
export interface TurnDetailPage {
  entries: TranscriptEntry[];
  /** Where this page starts. Earlier steps of the turn exist when this is past the turn's start. */
  firstIndex: number;
  /** The read failed: said as such, with Try Again, rather than as a turn with nothing in it (#544). */
  failed?: true;
}

/** Puts `id` among the newest `cap` entries of `held`, letting the oldest go (#291). */
export function rememberOpen<T>(held: Readonly<Record<string, T>>, order: readonly string[], id: string, value: T,
                                cap = openTurnsHeld): { held: Record<string, T>; order: string[] } {
  const next: Record<string, T> = { ...held, [id]: value };
  const ids = order.filter((kept) => kept !== id);
  ids.push(id);
  while (ids.length > cap) {
    const drop = ids.shift();
    if (drop !== undefined) delete next[drop];
  }
  return { held: next, order: ids };
}

/** How many entries heard as they happened are kept to lay over a page that arrives late. */
export const heardSincePageLimit = 1_000;

/**
 * How many entries a followed chat keeps, as the window's (AgentsModel.entriesKept): trimmed at
 * the front once a further page has piled up past it, and never below `itemsKept` rows (#170).
 */
export const entriesKept = 600;
export const entriesTrimmedAt = 800;
export const itemsKept = 100;
/** How many finished turns a followed chat keeps above its entries; earlier ones come back as the top is reached. */
export const turnsKept = 100;

/** The most folders a settling burst keeps by name before it is "many", as the host's own limit. */
export const filesNamedAtMost = 64;
/** How long a burst has to be quiet before the panes or a page read again (#170, #291). */
export const quietSettle = 250;
export const filesSettle = quietSettle;

/** How many archived sessions the Archived Sessions page lists at first: as many as it shows (#170). */
export const archivedPage = pageSize;

/** The most a search brings back from each host, a page at a time (#165, #193). */
export const searchShown = 200;

export type ByHost<T> = Record<string, T[]>;

/**
 * A record as heard, keeping the lists already held for it where it came without them: a lean
 * list or a lean `agent/changed` must not empty the open session's menus (Agent.keepingLists).
 * One marked `listsLeftOut` keeps them all (#203); one that isn't is the whole truth, an emptied
 * plan included, unless all three are empty, which is a host from before #203 leaving them out.
 */
export function keepingLists(listed: Agent, held: Agent | undefined): Agent {
  if (!held) return listed;
  const leftOut = listed.listsLeftOut
    || (!listed.advertisedOptions.length && !listed.availableCommands.length && !listed.plans?.length);
  if (!leftOut) return listed;
  const { plans: _plans, listsLeftOut: _leftOut, ...rest } = listed;
  return {
    ...rest,
    advertisedOptions: held.advertisedOptions,
    availableCommands: held.availableCommands,
    ...(held.plans ? { plans: held.plans } : {}),
    ...(listed.listsLeftOut && held.listsLeftOut ? { listsLeftOut: true } : {}),
  };
}

export function newestFirst(agents: Agent[]): Agent[] {
  return agents.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
}

export function sameAgents(a: readonly Agent[], b: readonly Agent[]): boolean {
  return a.length === b.length && a.every((agent, index) => agent === b[index]);
}

/** Keep stable row order while replacing each repeated id with its latest copy. */
export function keepingLatestByID<T extends { id: string }>(items: readonly T[]): T[] {
  const positions = new Map<string, number>();
  const unique: T[] = [];
  for (const item of items) {
    const position = positions.get(item.id);
    if (position === undefined) {
      positions.set(item.id, unique.length);
      unique.push(item);
    } else unique[position] = item;
  }
  return unique;
}

/** A stored turn as the chat draws it, made once per summary held. */
export const storedTurns = new WeakMap<TurnSummary, ChatTurn>();
export function storedTurnOf(summary: TurnSummary): ChatTurn {
  let turn = storedTurns.get(summary);
  if (!turn) storedTurns.set(summary, turn = storedTurn(summary));
  return turn;
}

/** A usage figure whose read a page dates (#5144): Cost, the charts, Time, Velocity and the Multiplier. */
export type UsageRead = "cost" | "usage" | "time" | "velocity" | "multiplier";


/** Something a person asked of a whole agent, on its way to its host (#87; AgentAct.swift). */
export type AgentAct = "agents/stop" | "agents/archive" | "agents/unarchive" | "agents/startNow"
  | { sendNow: string };

/** What the pending mark says it is doing, before "telling your Mac" (AgentAct.doing). */
export function actDoing(act: AgentAct): string {
  if (typeof act !== "string") return "Sending";
  return { "agents/stop": "Stopping", "agents/archive": "Archiving", "agents/unarchive": "Unarchiving", "agents/startNow": "Starting" }[act];
}

/** Telling.words: "Archiving — telling your Mac", or "telling your Mac" beside a button that says what. */
export function tellingWords(doing: string | null, recipient: string): string {
  return doing ? `${doing} — telling ${recipient}` : `telling ${recipient}`;
}

/** Said when an edit came too late (#1552), as QueuedPrompt.sentBeforeEdit says it. */
export const sentBeforeEdit = "That prompt was sent before your change. Your words are in the prompt bar.";

/** A runtime on a machine, to sign in (#5203). */
export interface RuntimeSignInTarget { host: string; runtimeID: string; runtimeName: string; machine: string }


/** Whether an entry starts a turn as the person's prompt does (#3249). */
export function isAskEntry(entry: TranscriptEntry): boolean {
  return isPersonsAsk({ kind: "entry", id: entry.id, entry });
}

/** Oldest asked first. */
export function byAsked(a: PersonRequest, b: PersonRequest): number {
  return a.askedAt < b.askedAt ? -1 : a.askedAt > b.askedAt ? 1 : 0;
}

