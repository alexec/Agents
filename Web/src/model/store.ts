// What the page holds and what each notification means: AgentsModel (Client/AgentsModel.swift),
// ported by hand for the notifications the web remote hears and held to Fixtures/web/reducer
// (research R7). Nothing here decides anything; the hosts do.
import { batch, computed, signal, type ReadonlySignal, type Signal } from "@preact/signals";
import type {
  Agent, AgentRemovedNotification, ResumingNotification, Tombstone, ControlHost, ElicitationNotification, ElicitationRequest, EntryNotification,
  PermissionNotification, PermissionRequest, ProjectSummary, TranscriptEntry, TranscriptPage, TurnsPage, TurnSummary,
  WorkflowSummary, Attachment, FilesChangedNotification, ShowFileNotification, WorkflowRemovedNotification, DraftOptionsNotification, JSONValue, Methods, RuntimeAccount, RuntimeStatus,
  StartRequest, UUID, WorktreesListResponse, FileStamp, WriteFailure, CloneNotification, CloneSummary, DirectoryListing, LeaseSnapshot, DiskState, StoreNotes,
  ChatProjectState, CostState, EventsPage, Event as ActivityEvent, ConfigOption, WorkflowSettings,
  PagesChangedNotification, PinsChangedNotification, PinView, ViewPin, ListCursor, ListRequest, FileMentionDTO, SandboxChoice, RuntimeAllowances,
} from "../protocol/generated";
import { Failure } from "../protocol/generated";
import { CallFailed, type Link } from "../wire/link";
import type { FolderGoneAsk } from "./missingFolder";
import { describe, methodNotFound } from "./errors";
import { log } from "../log";
import { folderKey, projectFolder, projectView, type ProjectView } from "./groups";
import { DisplayBuilder, keepingTurns, storedTurn, turns, type ChatTurn, type Item } from "./turns";
import { sortedRuntimes } from "./runtimes";
import { blockLines, openBlock } from "./block";
import { Drafts } from "./drafts";
import { scopeRoot, WatchCounts } from "./fileWatch";
import { workflowRunsOn } from "./workflows";
import { keyKind, takesKey, wantedRuntime } from "./credentials";
import type { Method, Params, Result } from "../protocol/methods";

export { folderKey } from "./groups";

/** DaemonAPI.SandboxWillNotStart, a start's refusal when its runtime's sandbox will not start, with its sentence. */
/** A server asked for a key this browser has none of (043, #344): open until lent or cancelled. */
export interface TokenAsk { host: string; runtimeID: string; answer: (lent: boolean) => void }

export interface SandboxWillNotStart { runtimeID: string; detail: string; offOffered: boolean; message: string }

function isSandboxRefusal(data: unknown): data is Omit<SandboxWillNotStart, "message"> {
  const d = data as Partial<SandboxWillNotStart> | null | undefined;
  return typeof d?.runtimeID === "string" && typeof d.detail === "string" && typeof d.offOffered === "boolean";
}

/** How many finished turns a chat opens with, as the window's (#90). */
const openingTurns = 12;

/** How many entries one opened turn asks for, the last of them first (#291). Earlier ones come on ask. */
export const turnPage = 200;

/** How many opened turns' entries a chat keeps. A turn closed, or past this, is read again when opened. */
export const openTurnsHeld = 8;

/**
 * How much history a chat keeps while the reader is scrolled up (#291). Past this, earlier pages
 * wait until they go back to the end, which lets the front go.
 */
export const historyEntriesCap = 1_600;
export const historyTurnsCap = 200;

/** A page of a finished turn's entries (#291). */
export interface TurnDetailPage {
  entries: TranscriptEntry[];
  /** Where this page starts. Earlier steps of the turn exist when this is past the turn's start. */
  firstIndex: number;
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
const heardSincePageLimit = 1_000;

/**
 * How many entries a followed chat keeps, as the window's (AgentsModel.entriesKept): trimmed at
 * the front once a further page has piled up past it, and never below `itemsKept` rows (#170).
 */
const entriesKept = 600;
const entriesTrimmedAt = 800;
const itemsKept = 100;
/** How many finished turns a followed chat keeps above its entries; earlier ones come back as the top is reached. */
const turnsKept = 100;

/** The most folders a settling burst keeps by name before it is "many", as the host's own limit. */
const filesNamedAtMost = 64;
/** How long a burst has to be quiet before the panes or a page read again (#170, #291). */
export const quietSettle = 250;
const filesSettle = quietSettle;

/** How many archived sessions an open Archived fold lists: as many as it shows (#170). */
export const archivedPage = 50;

/** The most a search brings back from each host, a page at a time (#165, #193). */
export const searchShown = 200;

type ByHost<T> = Record<string, T[]>;

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

function newestFirst(agents: Agent[]): Agent[] {
  return agents.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
}

function sameAgents(a: readonly Agent[], b: readonly Agent[]): boolean {
  return a.length === b.length && a.every((agent, index) => agent === b[index]);
}

/** Keep stable row order while replacing each repeated id with its latest copy. */
function keepingLatestByID<T extends { id: string }>(items: readonly T[]): T[] {
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
const storedTurns = new WeakMap<TurnSummary, ChatTurn>();
function storedTurnOf(summary: TurnSummary): ChatTurn {
  let turn = storedTurns.get(summary);
  if (!turn) storedTurns.set(summary, turn = storedTurn(summary));
  return turn;
}

/**
 * The reducer: what each notification does to what is held. Kept apart from the link so the
 * fixtures can drive it, as `AgentsModel` is driven in Swift.
 */
/** What a host's state says to the person (the window's HostHeading). */
export function hostStateWords(state: string): string {
  switch (state) {
    case "online": return "Online";
    case "connecting": return "Connecting…";
    case "needsUpdate": return "Needs an update";
    case "failed": return "Can't connect";
    default: return "Offline";
  }
}

export class Work {
  readonly hosts = signal<ControlHost[]>([]);
  readonly projects = signal<ByHost<ProjectSummary>>({});
  /** The clones under way on each host (027), drawn where the project will be. */
  readonly clones = signal<ByHost<CloneSummary>>({});
  readonly agents = signal<ByHost<Agent>>({});
  readonly permissions = signal<ByHost<PermissionRequest>>({});
  readonly elicitations = signal<ByHost<ElicitationRequest>>({});

  /** The conversation being read, and only that one. */
  readonly watching = signal<{ host: string; session: string } | null>(null);
  readonly entries = signal<TranscriptEntry[]>([]);
  /** The page as the chat draws it, folded once as each entry lands. */
  readonly items = signal<Item[]>([]);
  /** The finished turns before `entries`, as stored. `entries` start at `openTurnStart`. */
  readonly turns = signal<TurnSummary[]>([]);

  /**
   * The chat's turns, stored then heard, each the same object until something in it changes,
   * so an entry redraws the one turn it landed in (#170).
   */
  readonly chatTurns: ReadonlySignal<ChatTurn[]> = computed(() => {
    this.heardTurns = keepingTurns(turns(this.items.value), this.heardTurns);
    return keepingLatestByID([...this.turns.value.map(storedTurnOf), ...this.heardTurns]);
  });
  private heardTurns: ChatTurn[] = [];

  /**
   * Whether the chat is following the end, as the chat says. The page is trimmed at the front
   * only while it is: rows somebody scrolled up to read are never taken from under them.
   */
  isFollowingEnd = true;
  private nextTrimAt = entriesTrimmedAt;
  readonly firstTurn = signal(0);
  readonly openTurnStart = signal(0);
  readonly firstEntryIndex = signal(0);
  readonly hasMoreBefore = signal(false);
  /**
   * Why the open chat's history did not load, or only its earlier turns (#400), until a page lands
   * or the chat is left. Said in the chat with Try Again, where a failed load used to leave it blank.
   */
  readonly transcriptLoadFailure = signal<{ nothingLoaded: boolean; reason: string } | null>(null);
  /** The latest load of the open chat: an older answer landing after a newer one is dropped (#400). */
  protected transcriptLoads = 0;

  /** The last file an agent asked to be put in front of the person (`agent/showFile`). */
  readonly shownFile = signal<{ host: string; agentID: string; path: string; line?: number | undefined; at: number } | null>(null);
  /** The last folders said to have changed, for a pane watching them (`files/changed`). */
  readonly filesChanged = signal<{ host: string; agentID: string; folders: string[]; many: boolean; at: number } | null>(null);

  /** Each project's pinned pages by `host|folder` (#159), kept by pins/changed. */
  readonly pins = signal<Record<string, PinView[]>>({});
  /** Each project's pinned sessions by `host|folder` (#180), in their order, kept by pins/changed. */
  readonly sessionPins = signal<Record<string, string[]>>({});
  /** Bumped by pages/changed: a page shown may have changed on disk; read it again. */
  readonly pageRevisions = signal<Record<string, number>>({});

  /** Each project's workflows by `host|folder`, listed while that project is open. */
  readonly workflows = signal<Record<string, WorkflowSummary[]>>({});
  /** One project's list, so a change redraws that fold and no other (#291). */
  private workflowSlices = new Map<string, Signal<WorkflowSummary[]>>();
  /** Projects whose workflow list is on screen, and how many views hold it. */
  protected workflowHolds = new Map<string, number>();
  /** Lists a fetch has answered, so a page can tell "loading" from "gone". */
  protected workflowsLoaded = new Set<string>();

  /** One project's workflows: a reader redraws only when this project's list changes. */
  projectWorkflows(host: string, folder: string): WorkflowSummary[] {
    const key = `${host}|${folderKey(folder)}`;
    let slice = this.workflowSlices.get(key);
    if (!slice) {
      slice = signal(this.workflows.peek()[key] ?? []);
      this.workflowSlices.set(key, slice);
    }
    return slice.value;
  }

  /** Whether `loadWorkflows` has answered for this project since it was opened. */
  workflowsKnown(host: string, folder: string): boolean {
    return this.workflowsLoaded.has(`${host}|${folderKey(folder)}`);
  }

  protected writeWorkflows(key: string, list: WorkflowSummary[] | undefined): void {
    if (list === undefined) {
      if (key in this.workflows.peek()) {
        const { [key]: _gone, ...rest } = this.workflows.value;
        this.workflows.value = rest;
      }
    } else {
      this.workflows.value = { ...this.workflows.value, [key]: list };
    }
    const slice = this.workflowSlices.get(key);
    if (slice) slice.value = list ?? [];
  }

  upsertWorkflow(summary: WorkflowSummary, host: string): void {
    const key = `${host}|${folderKey(summary.workflow.folder)}`;
    // A project not on screen keeps no list: the next open asks for the whole of it (#291).
    if (this.workflows.peek()[key] === undefined && !this.workflowHolds.has(key)) return;
    const list = (this.workflows.peek()[key] ?? []).filter((w) => w.workflow.workflowID !== summary.workflow.workflowID);
    this.writeWorkflows(key, [...list, summary]);
  }

  /** The machine id of the host being looked at, when the control plane has said it. */
  private hostMachineID(host: string): string | undefined {
    const id = this.hosts.peek().find((item) => item.id === host)?.machineID;
    return id ? id : undefined;
  }

  /**
   * Keep a workflow this host still runs (#317). A save that pins it to other computers
   * answers with the workflow, and putting that answer back would show a row this host
   * does not run.
   */
  protected placeWorkflow(summary: WorkflowSummary, host: string): void {
    if (workflowRunsOn(summary.workflow.hosts, this.hostMachineID(host))) this.upsertWorkflow(summary, host);
    else this.removeWorkflow(summary.workflow.workflowID, summary.workflow.folder, host);
  }

  private removeWorkflow(workflowID: string, folder: string, host: string): void {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.workflows.peek()[key];
    if (held) this.writeWorkflows(key, held.filter((item) => item.workflow.workflowID !== workflowID));
  }

  /** The latest correction to a new agent's form, for the form holding that draft. */
  readonly draftOptions = signal<DraftOptionsNotification | null>(null);
  /** Each host's resources and who holds them (036, #116): read-only on the page. */
  readonly leases = signal<Record<string, LeaseSnapshot>>({});
  /** Retired agents a link led to, by `host|id`: who they were, for the retired page (051, #253). */
  readonly tombstones = signal<Record<string, Tombstone>>({});
  /** Each host's chats it is bringing back by itself after a restart: Coming back (#251). */
  readonly resuming = signal<Record<string, readonly string[]>>({});
  /** Each host's volumes low on space (#196), replaced whole by each disk/changed, never merged. */
  readonly disk = signal<Record<string, DiskState>>({});
  /** Each host's files it could not read in this run (#205, #223), replaced whole by each store/notesChanged. */
  readonly storeNotes = signal<Record<string, string[]>>({});
  /** The mode last chosen for each runtime, by host (029). */
  readonly rememberedModes = signal<Record<string, Record<string, JSONValue>>>({});

  /**
   * What didn't work, in one sentence, shown until its own OK closes it. Another arriving
   * meanwhile waits its turn rather than replacing it, as the window's alerts do (#101).
   */
  readonly problem = signal<string | null>(null);
  private problemsWaiting: string[] = [];

  say(sentence: string): void {
    if (this.problem.value === null) this.problem.value = sentence;
    else if (this.problem.value !== sentence && !this.problemsWaiting.includes(sentence)) this.problemsWaiting.push(sentence);
  }

  /** The shown problem's OK: the next one waiting, if any. */
  dismissProblem(): void {
    this.problem.value = this.problemsWaiting.shift() ?? null;
  }

  private filesSettling = new Map<string, { folders: Set<string>; many: boolean; timer: ReturnType<typeof setTimeout> }>();
  private pageSettle = new Map<string, ReturnType<typeof setTimeout>>();

  /** Lists and timers keyed by a host, let go with it (#291). */
  protected dropHostRecords(host: string): void {
    const prefix = `${host}|`;
    for (const [key, timer] of this.pageSettle) if (key.startsWith(prefix)) { clearTimeout(timer); this.pageSettle.delete(key); }
    for (const key of [...this.workflowHolds.keys()]) if (key.startsWith(prefix)) this.workflowHolds.delete(key);
    for (const key of [...this.workflowsLoaded]) if (key.startsWith(prefix)) this.workflowsLoaded.delete(key);
    for (const [key, slice] of this.workflowSlices) if (key.startsWith(prefix)) slice.value = [];
    for (const key of [...this.slices.keys()]) if (key.startsWith(prefix)) this.slices.delete(key);
    for (const key of [...this.views.keys()]) if (key.startsWith(prefix)) this.views.delete(key);
    for (const key of [...this.byID.keys()]) if (key.startsWith(prefix)) this.byID.delete(key);
  }
  private display = new DisplayBuilder();
  private entryIDs = new Set<string>();
  /** What was heard while a page is on its way, to lay over it; null when none is (#214). */
  protected heardSincePage: TranscriptEntry[] | null = [];

  /** One notification from one host. Returns false for one this does not know. */
  apply(method: string, params: unknown, host: string): boolean {
    switch (method) {
      case "agent/changed":
        this.upsertAgent(params as Agent, host);
        return true;
      case "project/changed":
        this.upsertProject(params as ProjectSummary, host);
        return true;
      case "clone/changed": {
        // Every window hears it: a clone belongs to the host, not to whoever asked (027).
        const { clone, finished } = params as CloneNotification;
        const list = (this.clones.value[host] ?? []).filter((c) => c.id !== clone.id);
        this.clones.value = { ...this.clones.value, [host]: finished ? list : [...list, clone] };
        return true;
      }
      case "agent/entry":
        this.takeEntry(params as EntryNotification, host);
        return true;
      case "agent/permission": {
        const note = params as PermissionNotification;
        const id = note.requestID ?? note.request?.id;
        let list = (this.permissions.value[host] ?? []).filter((p) =>
          // Every question at once from a daemon that withdraws without an id.
          !(p.agentID === note.agentID && (id === undefined || p.id === id)));
        if (note.request) list = [...list, note.request];
        list.sort((a, b) => a.askedAt - b.askedAt);
        this.permissions.value = { ...this.permissions.value, [host]: list };
        return true;
      }
      case "agent/elicitation": {
        const note = params as ElicitationNotification;
        let list = (this.elicitations.value[host] ?? []).filter((e) => e.id !== note.requestID);
        if (note.request) list = [...list, note.request];
        this.elicitations.value = { ...this.elicitations.value, [host]: list };
        return true;
      }
      case "agents/draftOptions":
        this.draftOptions.value = params as DraftOptionsNotification;
        return true;
      case "workflow/changed":
        this.placeWorkflow(params as WorkflowSummary, host);
        return true;
      case "pins/changed": {
        const note = params as PinsChangedNotification;
        this.pins.value = { ...this.pins.value, [`${host}|${folderKey(note.folder)}`]: note.pins };
        this.sessionPins.value = { ...this.sessionPins.value, [`${host}|${folderKey(note.folder)}`]: note.sessions ?? [] };
        return true;
      }
      case "pages/changed": {
        // A burst of writes: the pages read again once it is quiet, and with the stamp they hold (#291).
        const note = params as PagesChangedNotification;
        const key = `${host}|${folderKey(note.folder)}`;
        clearTimeout(this.pageSettle.get(key));
        this.pageSettle.set(key, setTimeout(() => {
          this.pageSettle.delete(key);
          this.pageRevisions.value = { ...this.pageRevisions.value, [key]: (this.pageRevisions.peek()[key] ?? 0) + 1 };
        }, quietSettle));
        return true;
      }
      case "workflow/removed": {
        const note = params as WorkflowRemovedNotification;
        const key = `${host}|${folderKey(note.folder)}`;
        const held = this.workflows.peek()[key];
        if (held) this.writeWorkflows(key, held.filter((w) => w.workflow.workflowID !== note.workflowID));
        return true;
      }
      case "agent/showFile": {
        const note = params as ShowFileNotification;
        this.shownFile.value = { host, agentID: note.agentID, path: note.file.path, line: note.file.line, at: Date.now() };
        return true;
      }
      case "files/changed": {
        // A build writes hundreds of files in a burst: the panes read again once it settles (#170).
        const note = params as FilesChangedNotification;
        const key = `${host}|${note.agentID}`;
        // Too many to name (#216): the host says `many`, and every pane for the agent reads again.
        const settling = this.filesSettling.get(key);
        const folders = new Set([...(settling?.folders ?? []), ...note.folders]);
        const many = (settling?.many ?? false) || note.many === true || folders.size > filesNamedAtMost;
        clearTimeout(settling?.timer);
        this.filesSettling.set(key, { folders: many ? new Set() : folders, many, timer: setTimeout(() => {
          this.filesSettling.delete(key);
          this.filesChanged.value = { host, agentID: note.agentID, folders: many ? [] : [...folders], many, at: Date.now() };
        }, filesSettle) });
        return true;
      }
      case "storage/writeFailed":
        // Something nobody was waiting on was not kept: a full disk, or a folder refusing
        // writes. Said, as the window and the Remote say it (#88).
        this.say((params as WriteFailure).message);
        return true;
      case "agent/resuming": {
        const note = params as ResumingNotification;
        const held = (this.resuming.value[host] ?? []).filter((id) => id !== note.agentID);
        this.resuming.value = { ...this.resuming.value, [host]: note.isResuming ? [...held, note.agentID] : held };
        return true;
      }
      case "leases/changed":
        this.leases.value = { ...this.leases.value, [host]: params as LeaseSnapshot };
        return true;
      case "disk/changed":
        this.disk.value = { ...this.disk.value, [host]: params as DiskState };
        return true;
      case "store/notesChanged":
        this.storeNotes.value = { ...this.storeNotes.value, [host]: (params as StoreNotes).notes };
        return true;
      case "modes/changed":
        this.rememberedModes.value = { ...this.rememberedModes.value, [host]: params as Record<string, JSONValue> };
        return true;
      case "agent/removed": {
        const { agentID } = params as AgentRemovedNotification;
        const held = this.agents.value[host] ?? [];
        const gone = held.find((a) => a.id === agentID);
        batch(() => {
          if (gone) this.setAgents(host, held.filter((a) => a !== gone), [projectFolder(gone)]);
          this.permissions.value = { ...this.permissions.value,
            [host]: (this.permissions.value[host] ?? []).filter((p) => p.agentID !== agentID) };
          this.elicitations.value = { ...this.elicitations.value,
            [host]: (this.elicitations.value[host] ?? []).filter((e) => e.agentID !== agentID) };
        });
        return true;
      }
      default:
        return false;
    }
  }

  upsertProject(summary: ProjectSummary, host: string): void {
    const list = (this.projects.value[host] ?? [])
      .filter((p) => folderKey(p.project.folder) !== folderKey(summary.project.folder));
    this.projects.value = { ...this.projects.value, [host]: [...list, summary] };
  }

  /**
   * One agent as it is now, put where its activity sorts it. Only its project's list, and the
   * one it left if it moved, are made again (#170).
   */
  upsertAgent(heard: Agent, host: string): void {
    const list = [...(this.agents.value[host] ?? [])];
    const at = list.findIndex((a) => a.id === heard.id);
    // An archived session this page has let go of, or never had, stays out: the live ones and a
    // page of the rest is all it holds (#170, #203).
    if (at < 0 && heard.state === "archived") return;
    const was = at >= 0 ? list.splice(at, 1)[0] : undefined;
    // Lean unless its lists moved and this page shows it (#203).
    const agent = keepingLists(heard, was);
    // Newest first, after any as new: where a stable sort of the list with it last puts it.
    let into = 0;
    while (into < list.length && list[into]!.lastActivityAt >= agent.lastActivityAt) into++;
    list.splice(into, 0, agent);
    this.setAgents(host, list, was ? [projectFolder(was), projectFolder(agent)] : [projectFolder(agent)]);
  }

  /** One host's agents as it just listed them; every other host's are left alone. */
  replaceAgents(listed: Agent[], host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    this.setAgents(host, newestFirst(listed.map((a) => keepingLists(a, held.get(a.id)))));
  }

  /** Archived agents of one project, listed when the fold opens, added beside the live ones. */
  addAgents(listed: Agent[], host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    const incoming = new Set(listed.map((l) => l.id));
    const kept = [...held.values()].filter((a) => !incoming.has(a.id));
    this.setAgents(host, newestFirst([...kept, ...listed.map((a) => keepingLists(a, held.get(a.id)))]),
      listed.map(projectFolder));
  }

  /**
   * One project's archived agents let go, when its Archived fold closes: the page holds the live
   * agents and a page of archived ones per open fold, no more (#170). The open session stays.
   */
  dropArchived(host: string, folder: string): void {
    const key = folderKey(folder);
    const watching = this.watching.value;
    const held = this.agents.value[host] ?? [];
    const kept = held.filter((a) => a.state !== "archived" || projectFolder(a) !== key
      || (watching?.host === host && watching.session === a.id));
    if (kept.length !== held.length) this.setAgents(host, kept, [key]);
  }

  /** Each project's agents by `host|folder`, kept as each change lands: one change redraws one project (#170). */
  private slices = new Map<string, Signal<Agent[]>>();
  private views = new Map<string, ReadonlySignal<ProjectView>>();
  private byID = new Map<string, ReadonlySignal<Agent | undefined>>();

  /**
   * Every write to a host's agents. `touched` names the projects that changed; without it every
   * project of the host is worked out again, and only those whose agents differ are told.
   */
  protected setAgents(host: string, list: Agent[], touched?: readonly string[]): void {
    const prefix = `${host}|`;
    batch(() => {
      this.agents.value = { ...this.agents.value, [host]: list };
      if (touched) {
        for (const folder of new Set(touched)) {
          const slice = this.slices.get(prefix + folder);
          if (slice) slice.value = list.filter((a) => projectFolder(a) === folder);
        }
        return;
      }
      const grouped = new Map<string, Agent[]>();
      for (const agent of list) {
        const folder = projectFolder(agent);
        const group = grouped.get(folder);
        if (group) group.push(agent); else grouped.set(folder, [agent]);
      }
      for (const [name, slice] of this.slices) {
        if (!name.startsWith(prefix)) continue;
        const next = grouped.get(name.slice(prefix.length)) ?? [];
        if (!sameAgents(slice.peek(), next)) slice.value = next;
      }
    });
  }

  private slice(host: string, folder: string): Signal<Agent[]> {
    const name = `${host}|${folder}`;
    let slice = this.slices.get(name);
    if (!slice) {
      slice = signal((this.agents.peek()[host] ?? []).filter((a) => projectFolder(a) === folder));
      this.slices.set(name, slice);
    }
    return slice;
  }

  /** One project's agents, newest first: what reads them is redrawn only when they change. */
  projectAgents(host: string, folder: string): Agent[] {
    return this.slice(host, folderKey(folder)).value;
  }

  /** One project's headings, archived sessions, subtitle and counts, worked out once per change to it. */
  projectView(host: string, folder: string): ProjectView {
    const key = folderKey(folder);
    const name = `${host}|${key}`;
    let view = this.views.get(name);
    if (!view) {
      const slice = this.slice(host, key);
      view = computed(() => projectView(slice.value, key));
      this.views.set(name, view);
    }
    return view.value;
  }

  /** Which conversation's entries are kept. A change clears the page. */
  watch(host: string, session: string): void {
    const now = this.watching.value;
    if (now?.host === host && now.session === session) return;
    batch(() => {
      this.watching.value = { host, session };
      this.clearTranscript();
    });
  }

  unwatch(): void {
    batch(() => {
      this.watching.value = null;
      this.clearTranscript();
    });
  }

  /**
   * Told of an entry too big for its host to send (#203): its stub holds its place, drawing
   * nothing, until the page reads it with `agents/transcript` and hands it to `fillOversized`.
   */
  protected oversized(_host: string, _agentID: string, _entryID: string, _index: number | undefined): void {}

  /** An entry its host sent as a stub, read whole: put where its stub is. */
  fillOversized(entry: TranscriptEntry, host: string, agentID: string): void {
    const watching = this.watching.value;
    if (!watching || watching.host !== host || watching.session !== agentID) return;
    const heard = this.heardSincePage?.findIndex((e) => e.id === entry.id) ?? -1;
    if (heard >= 0) this.heardSincePage![heard] = entry;
    const at = this.entries.value.findIndex((e) => e.id === entry.id);
    if (at < 0) return;
    const entries = [...this.entries.value];
    entries[at] = entry;
    this.refold(entries);
  }

  private takeEntry(note: EntryNotification, host: string): void {
    const watching = this.watching.value;
    if (!watching || watching.host !== host || watching.session !== note.agentID) return;
    if (note.oversized !== undefined) this.oversized(host, note.agentID, note.entry.id, note.index);
    const heard = this.heardSincePage;
    if (heard) {
      const prior = heard.findIndex((entry) => entry.id === note.entry.id);
      if (prior >= 0) heard[prior] = note.entry;
      else heard.push(note.entry);
      if (heard.length > heardSincePageLimit) heard.splice(0, heard.length - heardSincePageLimit);
    }
    // Catch-up can repeat an id with newer contents. Replace the held copy in place.
    const held = this.entries.value.findIndex((entry) => entry.id === note.entry.id);
    if (held >= 0) {
      const entries = [...this.entries.value];
      entries[held] = note.entry;
      this.refold(entries);
      return;
    }
    this.entryIDs.add(note.entry.id);
    this.display.add(note.entry);
    const entries = [...this.entries.value, note.entry];
    batch(() => {
      if (this.isFollowingEnd && entries.length > this.nextTrimAt) return this.trimFront(entries);
      this.entries.value = entries;
      this.items.value = this.display.items;
    });
  }

  /**
   * The oldest entries let go, down to `entriesKept`, while the chat follows the end (the
   * window's trimFront). Cut where a row begins, so every row left is the row it was; what went
   * is only marked as there, and reaching the top pages it back in as any earlier page comes.
   */
  private trimFront(entries: TranscriptEntry[]): void {
    const items = this.display.items;
    const position = new Map<string, number>();
    entries.forEach((entry, index) => { if (!position.has(entry.id)) position.set(entry.id, index); });
    const starts = items.flatMap((item) => position.get(item.id) ?? []);
    const latest = starts.length > itemsKept ? starts[starts.length - itemsKept]! : 0;
    const wanted = starts.find((start) => start >= entries.length - entriesKept) ?? latest;
    const cut = Math.min(wanted, latest);
    if (cut > 0) {
      entries = entries.slice(cut);
      this.firstEntryIndex.value += cut;
      this.hasMoreBefore.value = true;
      this.refold(entries);
    } else {
      this.items.value = items;
    }
    // Few rows can fold thousands of entries, a long turn's tool updates (#214): the oldest go
    // even so. The rows already folded from them stay as drawn, and reaching the top pages them
    // back in, so a row is only ever folded again from all of its entries.
    if (entries.length > entriesTrimmedAt) {
      const drop = entries.length - entriesKept;
      for (let i = 0; i < drop; i++) this.entryIDs.delete(entries[i]!.id);
      entries = entries.slice(drop);
      this.firstEntryIndex.value += drop;
      this.hasMoreBefore.value = true;
    }
    this.entries.value = entries;
    this.nextTrimAt = Math.max(entriesTrimmedAt, entries.length + entriesTrimmedAt - entriesKept);
  }

  /**
   * The chat says whether it follows the end. Back at the end, the finished turns above the
   * entries are let go down to `turnsKept`: a long scroll up holds no more than it read (#170).
   */
  setFollowingEnd(following: boolean): void {
    this.isFollowingEnd = following;
    const held = this.turns.value;
    if (!following || held.length <= turnsKept + openingTurns) return;
    const cut = held.length - turnsKept;
    batch(() => {
      this.turns.value = held.slice(cut);
      this.firstTurn.value += cut;
    });
  }

  /** The finished turns at the end of the conversation, and where the one in progress starts. */
  replaceTurns(page: TurnsPage): void {
    batch(() => {
      this.turns.value = keepingLatestByID(page.turns);
      this.firstTurn.value = page.firstTurn;
      this.openTurnStart.value = page.openStart;
    });
  }

  /** Earlier finished turns, put in front. Past the cap, they wait until the reader is back at the end (#291). */
  prependTurns(page: TurnsPage): void {
    if (this.turns.value.length >= historyTurnsCap) return;
    batch(() => {
      this.turns.value = keepingLatestByID([...page.turns, ...this.turns.value]);
      this.firstTurn.value = page.firstTurn;
    });
  }

  /** The first page of the conversation, with what was heard and is not on it laid after it. */
  replaceTranscript(page: TranscriptPage): void {
    const entries = keepingLatestByID([...page.entries, ...(this.heardSincePage ?? [])]);
    this.heardSincePage = null;
    batch(() => {
      this.firstEntryIndex.value = page.firstIndex;
      this.hasMoreBefore.value = page.firstIndex > this.openTurnStart.value;
      this.transcriptLoadFailure.value = null;
      this.refold(entries);
    });
  }

  /** An earlier page, put in front of what is held. Past the cap, it waits (#291). */
  prepend(page: TranscriptPage): void {
    if (this.entries.value.length >= historyEntriesCap) return;
    const entries = [...page.entries.filter((e) => !this.entryIDs.has(e.id)), ...this.entries.value];
    batch(() => {
      this.firstEntryIndex.value = page.firstIndex;
      this.hasMoreBefore.value = page.firstIndex > this.openTurnStart.value;
      this.refold(entries);
    });
  }

  private clearTranscript(): void {
    // A chat chosen is a page on its way.
    this.heardSincePage = [];
    this.transcriptLoadFailure.value = null;
    this.firstEntryIndex.value = 0;
    this.hasMoreBefore.value = false;
    this.turns.value = [];
    this.firstTurn.value = 0;
    this.openTurnStart.value = 0;
    this.refold([]);
  }

  private refold(entries: TranscriptEntry[]): void {
    this.entryIDs = new Set(entries.map((e) => e.id));
    this.display = new DisplayBuilder();
    for (const entry of entries) this.display.add(entry);
    this.entries.value = entries;
    this.items.value = this.display.items;
    this.nextTrimAt = entriesTrimmedAt;
  }

  /**
   * Whether anything of the conversation comes before what is in hand, and the chat will still
   * take it. At the history cap it waits until the reader is back at the end (#291).
   */
  get hasMoreOfTheConversation(): boolean {
    if (this.hasMoreBefore.value) return this.entries.value.length < historyEntriesCap;
    return this.firstTurn.value > 0 && this.turns.value.length < historyTurnsCap;
  }

  /**
   * Since when each host has not been online, as this page first heard it (#83; the window's
   * macDownSince). Kept while it stays down, dropped once it is back.
   */
  readonly downSince = signal<Record<string, number>>({});

  /** The hosts as listed, with when each one went down noted. */
  takeHosts(hosts: ControlHost[], now = Date.now()): void {
    const since: Record<string, number> = {};
    for (const host of hosts) if (host.state !== "online") since[host.id] = this.downSince.value[host.id] ?? now;
    batch(() => {
      this.hosts.value = hosts;
      this.downSince.value = since;
    });
  }

  /** Whether a host answers: online, or held back for a reason the page says. */
  hostIsOnline(host: string): boolean {
    return this.hosts.value.find((h) => h.id === host)?.state === "online";
  }

  /** One agent: what reads it is redrawn when it changes, not when any agent on its host does (#170). */
  agent(host: string, session: string): Agent | undefined {
    const name = `${host}|${session}`;
    let found = this.byID.get(name);
    if (!found) {
      // A few are read at a time (the open chat, its panes); the rest are let go.
      if (this.byID.size >= 64) this.byID.clear();
      found = computed(() => (this.agents.value[host] ?? []).find((a) => a.id === session));
      this.byID.set(name, found);
    }
    return found.value;
  }

  /**
   * What a blocked agent waits on, as its row says it. Only an agent with an open block reads
   * its host's other agents, for their titles; any other row is not redrawn by them (#170).
   */
  waitsOf(host: string, agent: Agent): string[] {
    return openBlock(agent) ? blockLines(agent, this.agents.value[host] ?? []) : [];
  }

  /** AgentsModel.isComingBack: whether the host is bringing this chat back by itself. */
  isComingBack(host: string, agentID: string): boolean {
    return (this.resuming.value[host] ?? []).includes(agentID);
  }

  permissionsFor(host: string, session: string): PermissionRequest[] {
    return (this.permissions.value[host] ?? []).filter((p) => p.agentID === session);
  }

  elicitationsFor(host: string, session: string): ElicitationRequest[] {
    return (this.elicitations.value[host] ?? []).filter((e) => e.agentID === session);
  }

  /** Every agent the page holds, on every host. */
  allAgents(): Agent[] {
    return Object.values(this.agents.value).flat();
  }
}

/** Something a person asked of a whole agent, on its way to its host (#87; AgentAct.swift). */
export type AgentAct = "agents/stop" | "agents/park" | "agents/unpark" | "agents/archive" | "agents/unarchive"
  | { sendNow: string };

/** What the pending mark says it is doing, before "telling your Mac" (AgentAct.doing). */
export function actDoing(act: AgentAct): string {
  if (typeof act !== "string") return "Sending";
  return { "agents/stop": "Stopping", "agents/park": "Parking", "agents/unpark": "Unparking", "agents/archive": "Archiving",
    "agents/unarchive": "Bringing back" }[act];
}

/** Telling.words: "Parking — telling your Mac", or "telling your Mac" beside a button that says what. */
export function tellingWords(doing: string | null, recipient: string): string {
  return doing ? `${doing} — telling ${recipient}` : `telling ${recipient}`;
}

/** The reducer, fed by the link: everything loaded on each connection, then kept by notifications. */
export class Store extends Work {
  constructor(readonly link: Link) {
    super();
    link.onNotification((method, params, host) => {
      if (method === "control/hostChanged") {
        this.hostChanged(params);
        return;
      }
      if (host) this.apply(method, params, host);
    });
    link.onState((state) => {
      if (state.kind === "open") void this.load();
    });
  }

  /** A workflow's newest runs, including archived sessions, in a growing page. */
  async loadWorkflowRuns(host: string, folder: string, workflowID: string, limit: number): Promise<Agent[]> {
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: false, archivedOnly: false, folder: folder as never,
      startedByWorkflow: workflowID, lean: true, limit,
    }, host).catch(() => null);
    if (!listed) return [];
    this.addAgents(listed, host);
    return listed;
  }

  /**
   * Everything again, on every connection, in the window's order (refreshEverything): agents,
   * then projects, then the cards and the open conversation at once. No cursors on the wire.
   * One at a time: asked again while running, it runs once more after.
   */
  load(): Promise<void> {
    return this.once("*", async () => {
      const hosts = await this.link.call("hosts/list", {});
      this.takeHosts(hosts);
      await Promise.all(this.hosts.value.filter((host) => host.state === "online").map((host) => this.onHost(host.id, async () => {
        // A removal that landed while this waited is not loaded back (#291).
        if (!this.hostIsOnline(host.id)) return;
        await this.loadHost(host.id);
      })));
      const watching = this.watching.value;
      if (watching) await this.loadTranscript(watching.host, watching.session);
    });
  }

  /** One load of a host at a time: `load` and `reloadHost` queue here rather than running together (#291). */
  private hostChain = new Map<string, Promise<void>>();

  private onHost(host: string, work: () => Promise<void>): Promise<void> {
    const prev = this.hostChain.get(host) ?? Promise.resolve();
    const run = prev.then(work, work);
    const done = run.finally(() => {
      if (this.hostChain.get(host) === done) this.hostChain.delete(host);
    });
    this.hostChain.set(host, done);
    return run;
  }

  /** What is running, by host or "*" for everything, and whether it was asked for again meanwhile. */
  private running = new Map<string, { done: Promise<void>; again: boolean }>();

  /** Runs `work` for `key` unless it is running already; then once more when it ends, however often asked. */
  private once(key: string, work: () => Promise<void>): Promise<void> {
    const now = this.running.get(key);
    if (now) {
      now.again = true;
      return now.done;
    }
    const entry = { done: Promise.resolve(), again: false };
    entry.done = (async () => {
      try {
        do {
          entry.again = false;
          await work().catch(() => {});
        } while (entry.again);
      } finally {
        this.running.delete(key);
      }
    })();
    this.running.set(key, entry);
    return entry.done;
  }

  private settling = new Map<string, ReturnType<typeof setTimeout>>();

  /**
   * One host came, went or changed (`control/hostChanged`): the hosts are listed again, and that
   * host's data alone loaded once it is online, a quarter of a second after the last word about
   * it (the control plane says it twice per connect). A control plane naming no host loads all (#170).
   */
  private hostChanged(params: unknown): void {
    const host = (params as { host?: unknown } | null)?.host;
    if (typeof host !== "string") {
      void this.load();
      return;
    }
    clearTimeout(this.settling.get(host));
    this.settling.set(host, setTimeout(() => {
      this.settling.delete(host);
      void this.once(host, () => this.reloadHost(host));
    }, 250));
  }

  private async reloadHost(host: string): Promise<void> {
    const hosts = await this.link.call("hosts/list", {});
    this.takeHosts(hosts);
    await this.onHost(host, async () => {
      const now = this.hosts.value.find((h) => h.id === host);
      if (!now) return this.forgetHost(host);
      if (now.state !== "online") return;
      await this.loadHost(host);
      const watching = this.watching.value;
      if (watching?.host === host) await this.loadTranscript(host, watching.session);
    });
  }

  /** A host removed: what was held of it goes with it, the runtimes included (#291). */
  private forgetHost(host: string): void {
    const prefix = `${host}|`;
    const without = <T,>(held: Record<string, T>) => Object.fromEntries(Object.entries(held).filter(([key]) => key !== host));
    const notOf = <T,>(held: Record<string, T>) => Object.fromEntries(Object.entries(held).filter(([key]) => !key.startsWith(prefix)));
    this.dropHostRecords(host);
    for (const key of [...this.startRequests.keys()]) if (key.startsWith(prefix)) this.startRequests.delete(key);
    batch(() => {
      this.setAgents(host, []);
      this.agents.value = without(this.agents.value);
      this.projects.value = without(this.projects.value);
      this.clones.value = without(this.clones.value);
      this.permissions.value = without(this.permissions.value);
      this.elicitations.value = without(this.elicitations.value);
      this.workflows.value = notOf(this.workflows.value);
      this.pageRevisions.value = notOf(this.pageRevisions.value);
      this.pins.value = notOf(this.pins.value);
      this.sessionPins.value = notOf(this.sessionPins.value);
      this.leases.value = without(this.leases.value);
      this.runtimes.value = without(this.runtimes.value);
      this.accounts.value = without(this.accounts.value);
      this.sandboxDefaults.value = without(this.sandboxDefaults.value);
      this.rememberedModes.value = without(this.rememberedModes.value);
      this.tombstones.value = notOf(this.tombstones.value);
      this.resuming.value = without(this.resuming.value);
      this.events.value = without(this.events.value);
      this.costs.value = without(this.costs.value);
      this.disk.value = without(this.disk.value);
      this.storeNotes.value = without(this.storeNotes.value);
    });
    for (const key of [...this.archivedLoaded]) if (key.startsWith(prefix)) this.archivedLoaded.delete(key);
    this.searched.delete(host);
    if (this.searchNext.value[host]) this.searchNext.value = without(this.searchNext.value);
  }

  private async loadHost(host: string): Promise<void> {
    // Logged by code alone: a host's words never reach the console (FR-033).
    const failed = (_what: string) => (error: unknown) => {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      return null;
    };
    // Lean: the columns read none of the option and command lists, 4 MB of 200 agents (#107).
    // The open session's come with loadWhole.
    const agents = await this.listLive(host).catch(failed("agents/list"));
    if (agents) this.replaceAgents(agents, host);
    // The Archived folds that were open are listed again rather than left empty by the live list,
    // and the workflows on screen asked again: they may have changed meanwhile.
    const prefix = `${host}|`;
    const reopened = [...this.archivedLoaded].filter((key) => key.startsWith(prefix));
    for (const key of reopened) {
      this.archivedLoaded.delete(key);
      void this.loadArchived(host, key.slice(prefix.length));
    }
    // Only what is on screen: a list left behind is not asked for again (#291).
    for (const key of this.workflowHolds.keys()) if (key.startsWith(prefix)) void this.loadWorkflows(host, key.slice(prefix.length));
    // A search on show: the live list just let its archived matches go, so they are asked again.
    if (this.searchWords) {
      this.searched.delete(host);
      const { [host]: _again, ...rest } = this.searchNext.value;
      this.searchNext.value = rest;
      void this.search({ includeArchived: true, archivedCommands: false, archivedOnly: false, lean: true,
        limit: searchShown, query: this.searchWords }, host, this.searchTurn);
    }
    // Archived ones too, as the window lists them: the sidebar folds them under Archived projects
    // (#343), and Spending still counts what they cost.
    const projects = await this.link.call("projects/list", { includeArchived: true }, host).catch(failed("projects/list"));
    if (projects) this.projects.value = { ...this.projects.value, [host]: projects };
    const clones = await this.link.call("projects/clones", {}, host).catch(failed("projects/clones"));
    if (clones) this.clones.value = { ...this.clones.value, [host]: clones };
    void this.loadRuntimes(host);
    void this.link.call("pins/list", {}, host).then((listed) => {
      const held = Object.fromEntries(Object.entries(this.pins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const sessions = Object.fromEntries(Object.entries(this.sessionPins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      for (const project of listed) {
        held[`${host}|${folderKey(project.folder)}`] = project.pins;
        sessions[`${host}|${folderKey(project.folder)}`] = project.sessions ?? [];
      }
      this.pins.value = held;
      this.sessionPins.value = sessions;
    }).catch(failed("pins/list"));
    // A host from before #251 doesn't answer, and nothing is said to be coming back.
    void this.link.call("agents/resuming", {}, host).then((response) => {
      this.resuming.value = { ...this.resuming.value, [host]: response.agentIDs };
    }).catch(failed("agents/resuming"));
    void this.link.call("leases/snapshot", {}, host).then((snapshot) => {
      this.leases.value = { ...this.leases.value, [host]: snapshot };
    }).catch(failed("leases/snapshot"));
    // A host too old to know disk/state says nothing, and no strip is drawn.
    void this.link.call("disk/state", {}, host).then((state) => {
      this.disk.value = { ...this.disk.value, [host]: state };
    }).catch(failed("disk/state"));
    // A host too old to know store/notes says nothing, as one with nothing to say.
    void this.link.call("store/notes", {}, host).then((state) => {
      this.storeNotes.value = { ...this.storeNotes.value, [host]: state.notes };
    }).catch(failed("store/notes"));
    const [permissions, elicitations] = await Promise.all([
      this.link.call("permissions/pending", {}, host).catch(failed("permissions/pending")),
      this.link.call("elicitations/pending", {}, host).catch(failed("elicitations/pending")),
    ]);
    batch(() => {
      if (permissions) this.permissions.value = { ...this.permissions.value,
        [host]: [...permissions].sort((a, b) => a.askedAt - b.askedAt) };
      if (elicitations) this.elicitations.value = { ...this.elicitations.value, [host]: elicitations };
    });
  }

  /**
   * Every live agent on a host, a page at a time: a host answers at most a page (#164).
   * Paged until one comes back short; a page longer than asked is a host from before pages.
   */
  private async listLive(host: string): Promise<Agent[]> {
    const limit = 500;
    const listed: Agent[] = [];
    const seen = new Set<string>();
    let after: ListCursor | undefined;
    for (let page = 0; page < 20; page++) {
      const got = await this.link.call("agents/list",
        { includeArchived: false, archivedCommands: false, archivedOnly: false, lean: true, limit, ...(after ? { after } : {}) }, host);
      for (const agent of got) if (!seen.has(agent.id)) { seen.add(agent.id); listed.push(agent); }
      const last = got[got.length - 1];
      if (got.length !== limit || !last) break;
      after = { lastActivityAt: last.lastActivityAt, id: last.id };
    }
    return listed;
  }

  /** The projects whose archived sessions have been listed since this connection opened. */
  private archivedLoaded = new Set<string>();


  /** The project's workflow list is on screen. The first holder asks for it. */
  holdWorkflows(host: string, folder: string): void {
    const key = `${host}|${folderKey(folder)}`;
    const count = this.workflowHolds.get(key) ?? 0;
    this.workflowHolds.set(key, count + 1);
    if (count === 0) void this.loadWorkflows(host, folder);
  }

  /** A view of the list went away. The last one lets the list go (#291). */
  releaseWorkflows(host: string, folder: string): void {
    const key = `${host}|${folderKey(folder)}`;
    const left = (this.workflowHolds.get(key) ?? 1) - 1;
    if (left > 0) {
      this.workflowHolds.set(key, left);
      return;
    }
    this.workflowHolds.delete(key);
    this.workflowsLoaded.delete(key);
    this.writeWorkflows(key, undefined);
  }

  async loadWorkflows(host: string, folder: string): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const listed = await this.link.call("workflows/list", { folder: folder as never }, host).catch(() => null);
    if (!this.workflowHolds.has(key)) return;
    this.workflowsLoaded.add(key);
    if (listed) this.writeWorkflows(key, listed);
  }

  /** One project's newest archived sessions, a page of them, asked for when its fold opens (#170). */
  async loadArchived(host: string, folder: string): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    if (this.archivedLoaded.has(key)) return;
    this.archivedLoaded.add(key);
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: false, archivedOnly: true, folder: folder as never, lean: true, limit: archivedPage,
    }, host).catch(() => null);
    if (!listed || !this.archivedLoaded.has(key)) return;
    // On show in the fold now: no longer the search's to let go.
    for (const agent of listed) this.searched.get(host)?.delete(agent.id);
    this.addAgents(listed, host);
  }

  /** The search's words, trimmed; empty when there is none. */
  private searchWords = "";
  /** Bumped by each search: a reply for words no longer asked is dropped. */
  private searchTurn = 0;
  /** Archived sessions a search brought in, by host, let go when the search ends or changes. */
  private searched = new Map<string, Set<string>>();
  /** The next page of matches, for each host whose last page was full (#176, #193). */
  readonly searchNext = signal<Record<string, ListRequest>>({});

  /**
   * Ask every host for the sessions matching `words`, archived ones included, a capped page each
   * (#165, #193): the sidebar holds the live ones and filters those itself. What the last search
   * brought in is let go first, so the page holds one search's matches at a time.
   */
  async searchSessions(words: string): Promise<void> {
    const turn = ++this.searchTurn;
    this.searchWords = words;
    this.searchNext.value = {};
    this.forgetSearched();
    if (!words) return;
    const request: ListRequest = {
      includeArchived: true, archivedCommands: false, archivedOnly: false, lean: true, limit: searchShown, query: words,
    };
    for (const host of this.hosts.value) {
      if (turn !== this.searchTurn) return;
      if (this.hostIsOnline(host.id)) await this.search(request, host.id, turn);
    }
  }

  /** The next page from each host that has more, newest first as the host lists them. */
  async searchMore(): Promise<void> {
    const turn = this.searchTurn;
    const next = this.searchNext.value;
    this.searchNext.value = {};
    for (const [host, request] of Object.entries(next)) {
      if (turn !== this.searchTurn) return;
      await this.search(request, host, turn);
    }
  }

  private async search(request: ListRequest, host: string, turn: number): Promise<void> {
    const found = await this.link.call("agents/list", request, host).catch(() => null);
    // The search ended or changed while this was on its way: not what is asked now.
    if (!found || turn !== this.searchTurn) return;
    const archived = found.filter((a) => a.state === "archived");
    const held = new Set((this.agents.value[host] ?? []).map((a) => a.id));
    const brought = this.searched.get(host) ?? new Set<string>();
    for (const agent of archived) if (!held.has(agent.id)) brought.add(agent.id);
    this.searched.set(host, brought);
    if (archived.length) this.addAgents(archived, host);
    const last = found[found.length - 1];
    if (found.length === request.limit && last) {
      this.searchNext.value = { ...this.searchNext.value,
        [host]: { ...request, after: { lastActivityAt: last.lastActivityAt, id: last.id } } };
    }
  }

  /** What searches brought in, let go: the open session stays, and anything no longer archived. */
  private forgetSearched(): void {
    const watching = this.watching.value;
    for (const [host, ids] of this.searched) {
      const held = this.agents.value[host] ?? [];
      const gone = held.filter((a) => ids.has(a.id) && a.state === "archived"
        && !(watching?.host === host && watching.session === a.id));
      if (gone.length) {
        const without = new Set(gone.map((a) => a.id));
        this.setAgents(host, held.filter((a) => !without.has(a.id)), [...new Set(gone.map(projectFolder))]);
      }
    }
    this.searched.clear();
  }

  /** Its fold closed: the project's archived sessions are let go, and listed again when it opens. */
  unloadArchived(host: string, folder: string): void {
    this.archivedLoaded.delete(`${host}|${folderKey(folder)}`);
    this.dropArchived(host, folder);
  }

  async openSession(host: string, session: string): Promise<void> {
    this.watch(host, session);
    await this.loadTranscript(host, session);
  }

  closeSession(): void {
    this.unwatch();
  }

  /** The open session's record whole, with the menus a lean list leaves out (#107). */
  private async loadWhole(host: string, session: string): Promise<void> {
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: true, archivedOnly: false, lean: false, agentID: session as never, limit: 1,
    }, host).catch(() => null);
    // A host from before #107 ignores agentID and answers with its newest, which isn't this one.
    const whole = listed?.find((a) => a.id === session);
    if (whole) this.addAgents([whole], host);
  }

  /** The finished turns first, as summaries, then the transcript from where the open turn starts. */
  private async loadTranscript(host: string, session: string): Promise<void> {
    void this.loadWhole(host, session);
    this.heardSincePage ??= [];
    const load = ++this.transcriptLoads;
    const agentID = session as never;
    // The last 12, as the window opens a chat (#90); the rest come as the top is reached. A host
    // too old to keep turns gives the lot; any other failure is said, and the chat still opens (#400).
    const failed: { turns?: string; page?: string } = {};
    const turns = await this.link.call("agents/turns", { agentID, limit: openingTurns }, host)
      .catch((error: unknown) => {
        if (!(error instanceof CallFailed && error.code === methodNotFound)) failed.turns = describe(error);
        return { turns: [], firstTurn: 0, openStart: 0 };
      });
    const page = await this.link.call("agents/transcript", { agentID, limit: 200, from: turns.openStart }, host)
      .catch((error: unknown) => {
        failed.page = describe(error);
        log("call.failed", error instanceof CallFailed ? error.code : undefined);
        return null;
      });
    // A chat opened since is not this one, and a newer load of this one has the say.
    const now = this.watching.value;
    if (now?.host !== host || now.session !== session || load !== this.transcriptLoads) return;
    if (!page) {
      this.transcriptLoadFailure.value = { nothingLoaded: true, reason: failed.page ?? "no answer." };
      return;
    }
    batch(() => {
      this.replaceTurns(turns);
      this.replaceTranscript(page);
      if (failed.turns) this.transcriptLoadFailure.value = { nothingLoaded: false, reason: failed.turns };
    });
  }

  /** Ask again for the open chat's history, after it did not load (#400). */
  async reloadTranscript(): Promise<void> {
    const watching = this.watching.value;
    if (watching) await this.loadTranscript(watching.host, watching.session);
  }

  /** An entry its host sent as a stub, read from among its neighbours (#203). */
  protected override oversized(host: string, agentID: string, entryID: string, index: number | undefined): void {
    const around = index === undefined ? { limit: 50 } : { before: index + 4, limit: 8 };
    void this.link.call("agents/transcript", { agentID: agentID as never, ...around }, host)
      .then((page) => {
        const entry = page.entries.find((e) => e.id === entryID);
        if (entry) this.fillOversized(entry, host, agentID);
      })
      .catch(() => {});
  }

  /** Further back: the open turn's earlier entries, then the turns before it. A chat scrolled up
   * stops once it holds a bounded history (#291). */
  async loadEarlier(): Promise<void> {
    const watching = this.watching.value;
    if (!watching || !this.hasMoreOfTheConversation) return;
    const agentID = watching.session as never;
    if (!this.hasMoreBefore.value) {
      if (this.turns.value.length >= historyTurnsCap) return;
      const turns = await this.link.call("agents/turns", { agentID, before: this.firstTurn.value, limit: 50 }, watching.host)
        .catch(() => null);
      if (turns && this.watching.value === watching) this.prependTurns(turns);
      return;
    }
    if (this.entries.value.length >= historyEntriesCap) return;
    const page = await this.link.call("agents/transcript", {
      agentID, before: this.firstEntryIndex.value, limit: 200, from: this.openTurnStart.value,
    }, watching.host).catch(() => null);
    if (page && this.watching.value === watching) this.prepend(page);
  }

  /**
   * One page of a finished turn, the last `turnPage` entries before `range.end` (#291).
   * `firstIndex` is past `range.start` when the turn has earlier steps.
   */
  async turnEntries(host: string, session: string, range: { start: number; end: number }): Promise<TurnDetailPage> {
    const span = range.end - range.start;
    if (span <= 0) return { entries: [], firstIndex: range.start };
    const page = await this.link.call("agents/transcript", {
      agentID: session as never, before: range.end, limit: Math.min(span, turnPage), from: range.start,
    }, host).catch(() => null);
    return { entries: page?.entries ?? [], firstIndex: page?.firstIndex ?? range.start };
  }

  // MARK: What the browser sends (071 US3)

  /** Each runtime and what each says it can take, by host. */
  readonly runtimes = signal<Record<string, RuntimeStatus[]>>({});
  /** Allowance readings and out states for each host's Runtimes page. */
  readonly runtimeAllowances = signal<Record<string, RuntimeAllowances>>({});
  /** Each host's sandbox default per runtime (SandboxSettings); absent means its runtime decides. */
  readonly sandboxDefaults = signal<Record<string, Record<string, SandboxChoice>>>({});
  readonly accounts = signal<Record<string, RuntimeAccount[]>>({});
  /** A choice made on a menu that the host hasn't confirmed, by agent then option. */
  readonly pendingOptions = signal<Record<string, Record<string, JSONValue>>>({});
  /** What is typed and attached, per session or per new-agent form, kept across a reload (#254). */
  readonly drafts = new Drafts(typeof localStorage === "undefined" ? undefined : localStorage);

  /** Calls `method`, and on failure says why in `problem` and answers null. */
  async act<M extends keyof Methods>(method: M, params: Methods[M]["params"], host: string): Promise<Methods[M]["result"] | null> {
    try {
      return await this.link.call(method, params, host);
    } catch (error) {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      this.say(describe(error));
      return null;
    }
  }

  /**
   * A folder on `host` as a project (#115), as the window's Add Folder… does. Answers the
   * project, or null with `problem` saying why.
   */
  async addProject(host: string, folder: string): Promise<ProjectSummary | null> {
    const summary = await this.act("projects/add", { folder: folder as never }, host);
    if (summary) this.upsertProject(summary, host);
    return summary;
  }

  /**
   * Clones `url` into the host's home folder and adds it (027, #115). Answers once the clone
   * has finished; the row meanwhile comes from `clone/changed`.
   */
  async cloneProject(host: string, url: string): Promise<ProjectSummary | null> {
    const summary = await this.act("projects/clone", { url }, host);
    if (summary) this.upsertProject(summary, host);
    return summary;
  }

  /**
   * An archived project brought back (#343), as the window's Bring Back does: a project again,
   * with its new-session form open.
   */
  async unarchiveProject(host: string, folder: string): Promise<ProjectSummary | null> {
    const summary = await this.act("projects/unarchive", { folder: folder as never }, host);
    if (summary) this.upsertProject(summary, host);
    return summary;
  }

  /** Why `host` has a chat project or not (#229), for a New Chat that found none listed. Throws a refusal. */
  chatState(host: string): Promise<ChatProjectState> {
    return this.link.call("projects/chatState", {}, host);
  }

  /** The folders at `path` on `host`, for choosing one as a project (037). Throws a refusal. */
  browse(host: string, path: string): Promise<DirectoryListing> {
    return this.link.call("files/browse", { path }, host);
  }

  /** What runs on a host, and what each runtime takes; asked once a connection. */
  async loadRuntimes(host: string): Promise<void> {
    const [runtimes, accounts, modes, sandbox, allowances] = await Promise.all([
      this.link.call("runtimes/list", {}, host).catch(() => null),
      this.link.call("runtimes/accounts", {}, host).catch(() => null),
      this.link.call("modes/remembered", {}, host).catch(() => null),
      // A host on an older build is not asked by the page: every runtime then follows its own.
      this.link.call("sandbox/state", {}, host).catch(() => null),
      this.link.call("runtimes/allowances", null, host).catch(() => null),
    ]);
    batch(() => {
      if (sandbox) this.sandboxDefaults.value = { ...this.sandboxDefaults.value, [host]: sandbox.defaults };
      if (runtimes) this.runtimes.value = { ...this.runtimes.value, [host]: sortedRuntimes(runtimes) };
      if (allowances) this.runtimeAllowances.value = { ...this.runtimeAllowances.value, [host]: allowances };
      if (accounts) this.accounts.value = { ...this.accounts.value, [host]: accounts };
      if (modes) this.rememberedModes.value = { ...this.rememberedModes.value, [host]: modes };
    });
  }

  async markRuntimeAvailable(host: string, credentialKey: string): Promise<void> {
    const allowances = await this.link.call("runtimes/markAvailable", { credentialKey }, host).catch(() => null);
    if (allowances) this.runtimeAllowances.value = { ...this.runtimeAllowances.value, [host]: allowances };
  }

  account(host: string, runtimeID: string): RuntimeAccount | undefined {
    return (this.accounts.value[host] ?? []).find((a) => a.runtimeID === runtimeID);
  }

  async prompt(host: string, agentID: string, text: string, attachments: Attachment[]): Promise<boolean> {
    try {
      await this.lending("agents/prompt", { agentID: agentID as UUID, text, attachments, from: "person" }, host);
      return true;
    } catch (error) {
      // Its folder has gone (#119): said with the ways on, carrying what was typed.
      if (error instanceof CallFailed && error.code === Failure.folderGone) {
        this.folderGone.value = { host, agentID, message: error.message, text, attachments };
        return false;
      }
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      this.say(describe(error));
      return false;
    }
  }

  /** A server's key ask (#344), the window's TokenAskCard, while it is open. One at a time. */
  readonly tokenAsk = signal<TokenAsk | null>(null);

  /**
   * `method` on `host`, as the window's DaemonClient sends it with a lender (043): a server that
   * wants a key asks the person here, and once one is lent the call goes again, unchanged, so a
   * start's `requestID` keeps it the same start. Cancelled, or asked while another ask is open,
   * it fails as the server said.
   */
  private async lending<M extends Method>(method: M, params: Params<M>, host: string): Promise<Result<M>> {
    try {
      return await this.link.call(method, params, host);
    } catch (error) {
      const runtime = error instanceof CallFailed && error.code === Failure.credentialWanted ? wantedRuntime(error.data) : null;
      if (host === "mac" || !runtime || !takesKey(runtime) || this.tokenAsk.peek()) throw error;
      const lent = await new Promise<boolean>((answer) => { this.tokenAsk.value = { host, runtimeID: runtime, answer }; });
      if (!lent) throw error;
      return await this.link.call(method, params, host);
    }
  }

  /**
   * The person pasted a key into the ask: offered and lent to the server that asked, on this
   * browser's own connection, and kept nowhere. Answers why not, leaving the ask open, or null
   * once it is lent and the call that asked goes again. "notAKey" is a paste of something else.
   */
  async lendKey(text: string): Promise<string | null> {
    const ask = this.tokenAsk.peek();
    if (!ask) return null;
    const kind = keyKind(text, ask.runtimeID);
    if (!kind) return "notAKey";
    try {
      await this.link.call("credentials/offer", { runtimes: [ask.runtimeID], ownSignInOnly: false }, ask.host);
      await this.link.call("credentials/lend", { runtime: ask.runtimeID, kind, secret: text.trim() }, ask.host);
    } catch (error) {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      return describe(error);
    }
    this.finishTokenAsk(true);
    return null;
  }

  /** The ask answered: lent (true), or cancelled. Once: its answer is a promise's. */
  finishTokenAsk(lent: boolean): void {
    const ask = this.tokenAsk.peek();
    if (!ask) return;
    this.tokenAsk.value = null;
    ask.answer(lent);
  }

  /** A send refused because the agent's folder has gone (#119), until a way on or Cancel. */
  readonly folderGone = signal<FolderGoneAsk | null>(null);

  /**
   * Continue in the project folder (#119): a successor that reads this session and carries on,
   * with whatever was typed. Answers its id, or null with `problem` saying why.
   */
  async continueInProject(host: string, agentID: string, text = "", attachments: Attachment[] = []): Promise<string | null> {
    return this.act("agents/continueInProject",
      { agentID: agentID as UUID, text, attachments, requestID: crypto.randomUUID().toUpperCase() as UUID }, host);
  }

  /**
   * Branch (#342): a new session that carries this one's history so far, the original left alone.
   * Answers its id, or null with `problem` saying why.
   */
  async fork(host: string, agentID: string): Promise<string | null> {
    return this.act("agents/fork", { agentID: agentID as UUID }, host);
  }

  /** Recreate the worktree from its branch (#119); the row follows from `agent/changed`. */
  async recreateWorktree(host: string, agentID: string): Promise<void> {
    const agent = await this.act("agents/recreateWorktree", { agentID: agentID as UUID }, host);
    if (agent) this.apply("agent/changed", agent, host);
  }

  async sendNow(host: string, agentID: string, promptID: string): Promise<void> {
    await this.acting(agentID, { sendNow: promptID }, () =>
      this.act("agents/sendNow", { agentID: agentID as UUID, promptID: promptID as UUID }, host));
  }

  /**
   * What is on its way to each agent (#87; AgentsModel's acting): stop, park, unpark, archive or
   * Send now, one at a time. Every control that would send a second sees the first is going.
   */
  readonly onItsWay = signal<Record<string, AgentAct>>({});

  /** Who an action goes to, as the pending mark says it: "your Mac", or the host's name. */
  recipient(host: string): string {
    return host === "mac" ? "your Mac" : this.hosts.value.find((h) => h.id === host)?.name ?? "the host";
  }

  private async acting(agentID: string, act: AgentAct, run: () => Promise<unknown>): Promise<void> {
    if (this.onItsWay.value[agentID]) return;
    this.onItsWay.value = { ...this.onItsWay.value, [agentID]: act };
    try {
      await run();
    } finally {
      const { [agentID]: _done, ...rest } = this.onItsWay.value;
      this.onItsWay.value = rest;
    }
  }

  async unqueue(host: string, agentID: string, promptID: string): Promise<void> {
    await this.act("agents/unqueue", { agentID: agentID as UUID, promptID: promptID as UUID }, host);
  }

  /** Who an agent was, when it is not held and may have been retired; nothing when it wasn't. */
  async lookUpRetired(host: string, agentID: string): Promise<void> {
    if (this.tombstones.peek()[`${host}|${agentID}`]) return;
    const found = await this.link.call("agents/retired", { ids: [agentID as UUID] }, host).catch(() => null);
    const gone = found?.find((t) => t.id === agentID);
    if (gone) this.tombstones.value = { ...this.tombstones.value, [`${host}|${agentID}`]: gone };
  }

  /** One task an agent left running, and nothing else it is doing (057, #253). */
  async stopBackground(host: string, agentID: string, itemID: string): Promise<void> {
    await this.act("agents/stopBackground", { agentID: agentID as UUID, itemID }, host);
  }

  /** A runtime's sandbox that could not start (064, #253): Continue without it, or Keep stopped. */
  async answerSandbox(host: string, agentID: string, carryOn: boolean): Promise<void> {
    await this.act("agents/answerSandbox", { agentID: agentID as UUID, carryOn }, host);
  }

  async setAgentSandbox(host: string, agentID: string, choice: SandboxChoice | undefined): Promise<void> {
    await this.act("agents/setSandbox", { agentID: agentID as UUID, ...(choice ? { choice } : {}) }, host);
  }

  async letAgentGoOn(host: string, agent: Agent): Promise<void> {
    const limits = this.costs.value[host]?.limits;
    const ceiling = agent.costCeiling ?? limits?.perAgent;
    const currency = ceiling?.currency ?? "USD";
    const spent = agent.costToDate?.[currency] ?? 0;
    const step = ceiling?.amount ?? spent;
    await this.act("agents/setCeiling", {
      agentID: agent.id, ceiling: { amount: spent + step, currency },
    }, host);
  }

  async perform(host: string, agentID: string,
                action: "agents/stop" | "agents/park" | "agents/unpark" | "agents/archive" | "agents/unarchive"): Promise<void> {
    await this.acting(agentID, action, () => this.act(action, { agentID: agentID as UUID }, host));
  }

  // MARK: Files, changes and live pages (071 US4)

  listFiles(host: string, agentID: string, folder: string) {
    return this.link.call("files/list", { agentID: agentID as UUID, folder }, host);
  }

  readFile(host: string, agentID: string, path: string, knownStamp?: FileStamp) {
    return this.link.call("files/read", { agentID: agentID as UUID, path, ...(knownStamp ? { knownStamp } : {}) }, host);
  }

  /** Panes holding one folder watch. The host watches the agent's folder, so two paths inside it are one watch. */
  private fileWatches = new WatchCounts();
  /** The root each watch was given, newest last, so leaving releases that one if the agent's folder has since moved. */
  private watchedRoot = new Map<string, string[]>();

  /**
   * Watch the agent's folder that holds `folder`. Counted, so a file open under Files and the
   * tree beside it share one watch, and closing the file does not stop the tree's (#258).
   */
  watchFolder(host: string, agentID: string, folder: string): void {
    const root = this.watchRoot(host, agentID, folder);
    const caller = `${host}|${agentID}|${folder}`;
    const held = this.watchedRoot.get(caller) ?? [];
    held.push(root);
    this.watchedRoot.set(caller, held);
    if (this.fileWatches.watch(`${host}|${agentID}|${root}`)) {
      void this.link.call("files/watch", { agentID: agentID as UUID, folder: root }, host).catch(() => {});
    }
  }

  unwatchFolder(host: string, agentID: string, folder: string): void {
    const caller = `${host}|${agentID}|${folder}`;
    const held = this.watchedRoot.get(caller);
    const root = held?.pop() ?? this.watchRoot(host, agentID, folder);
    if (held && held.length === 0) this.watchedRoot.delete(caller);
    if (this.fileWatches.unwatch(`${host}|${agentID}|${root}`)) {
      void this.link.call("files/unwatch", { agentID: agentID as UUID, folder: root }, host).catch(() => {});
    }
  }

  /** The folder the host actually watches for this path: the agent's own, or an extra one it was given. */
  private watchRoot(host: string, agentID: string, folder: string): string {
    const agent = (this.agents.peek()[host] ?? []).find((item) => item.id === agentID);
    return agent ? scopeRoot(agent.cwd, agent.additionalDirectories ?? [], folder) : folder;
  }

  changes(host: string, agentID: string) {
    return this.link.call("changes/list", { agentID: agentID as UUID }, host);
  }

  changedFile(host: string, agentID: string, path: string, whole = false) {
    return this.link.call("changes/file", { agentID: agentID as UUID, path, whole }, host);
  }

  /** What the person typed on a live page, written to the file as the window writes it. */
  async writeArtifact(host: string, agentID: string, path: string, text: string): Promise<boolean> {
    return (await this.act("artifact/write", { agentID: agentID as UUID, path, text }, host)) !== null;
  }

  // MARK: Pinned pages (#159)

  pinsIn(host: string, folder: string): PinView[] {
    return this.pins.value[`${host}|${folderKey(folder)}`] ?? [];
  }

  /** A file of the project's: a pinned page, or what an HTML page draws from. */
  readPage(host: string, folder: string, path: string, knownStamp?: FileStamp) {
    return this.link.call("pins/read", { folder: folder as never, path, ...(knownStamp ? { knownStamp } : {}) }, host);
  }

  async writePage(host: string, folder: string, path: string, text: string): Promise<boolean> {
    return (await this.act("pins/write", { folder: folder as never, path, text }, host)) !== null;
  }

  async pin(host: string, folder: string, path: string): Promise<void> {
    const pins = await this.act("pins/pin", { folder: folder as never, path }, host);
    if (pins) this.pins.value = { ...this.pins.value, [`${host}|${folderKey(folder)}`]: pins };
  }

  /** A chat's view pinned to its project (#189): keyed by its ui:// address. Answers whether
   *  it was; a refusal is said in `problem`. */
  async pinView(host: string, folder: string, view: ViewPin): Promise<boolean> {
    const pins = await this.act("pins/pin", { folder: folder as never, path: view.uri, view }, host);
    if (pins) this.pins.value = { ...this.pins.value, [`${host}|${folderKey(folder)}`]: pins };
    return pins !== null;
  }

  async unpin(host: string, folder: string, path: string): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    this.pins.value = { ...this.pins.value, [key]: this.pinsIn(host, folder).filter((p) => p.path !== path) };
    await this.act("pins/unpin", { folder: folder as never, path }, host);
  }

  /** A drop or a Move item: shown at once, then the whole order sent once. */
  async arrangePins(host: string, folder: string, paths: string[]): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.pinsIn(host, folder);
    this.pins.value = { ...this.pins.value, [key]: paths.flatMap((path) => held.filter((p) => p.path === path)) };
    await this.act("pins/arrange", { folder: folder as never, paths }, host);
  }

  // MARK: Pinned sessions (#180)

  sessionPinsIn(host: string, folder: string): string[] {
    return this.sessionPins.value[`${host}|${folderKey(folder)}`] ?? [];
  }

  /** Pin or Unpin from a session's menu: shown at once, then the host told. */
  async setPinned(host: string, folder: string, agentID: string, pinned: boolean): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.sessionPinsIn(host, folder).filter((id) => id !== agentID);
    this.sessionPins.value = { ...this.sessionPins.value, [key]: pinned ? [...held, agentID] : held };
    await this.act(pinned ? "pins/pinSession" : "pins/unpinSession",
      { folder: folder as never, agentID: agentID as UUID }, host);
  }

  /** A Move item among the pinned sessions: shown at once, then the whole order sent once. */
  async arrangeSessionPins(host: string, folder: string, ids: string[]): Promise<void> {
    this.sessionPins.value = { ...this.sessionPins.value, [`${host}|${folderKey(folder)}`]: ids };
    await this.act("pins/arrangeSessions", { folder: folder as never, agentIDs: ids as UUID[] }, host);
  }

  /** Run now (US5). The session it starts arrives as any other does, by agent/changed. */
  async runWorkflow(host: string, summary: WorkflowSummary): Promise<void> {
    const ran = await this.act("workflows/run", { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID }, host);
    if (ran) this.placeWorkflow(ran, host);
  }

  /** Turn Off / Turn On (#100): it keeps its place on the list either way. */
  async setWorkflowEnabled(host: string, summary: WorkflowSummary, enabled: boolean): Promise<void> {
    const changed = await this.act("workflows/enable",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, enabled }, host);
    if (changed) this.placeWorkflow(changed, host);
  }

  /** Approve (#142): the digest is what the page was showing, so a file changed since still waits. */
  async approveWorkflow(host: string, summary: WorkflowSummary): Promise<void> {
    if (!summary.awaitingApproval) return;
    const changed = await this.act("workflows/approve",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, digest: summary.awaitingApproval.digest }, host);
    if (changed) this.placeWorkflow(changed, host);
  }

  /** Archive or Bring Back (#142), as the window's page has them. */
  async setWorkflowArchived(host: string, summary: WorkflowSummary, archived: boolean): Promise<void> {
    const changed = await this.act("workflows/archive",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, archived }, host);
    if (changed) this.placeWorkflow(changed, host);
  }

  private settingsInFlight = new Map<string, Promise<unknown>>();

  /**
   * One setting, its label list, its cooldown or the computers it runs on (#162, #317), written
   * to the file through the daemon as the window's page writes it. `change` is applied to what
   * the file says when the call is sent, after any earlier change to the same workflow has been
   * answered, so two quick changes cannot undo each other. The answer replaces the one summary;
   * the list is not asked for again. Answers the daemon's refusal, for the page to say beside
   * the controls, or null.
   */
  setWorkflowSettings(host: string, summary: WorkflowSummary,
                      change: { settings?: (s: WorkflowSettings) => WorkflowSettings; cooldown?: string; labels?: (labels: string[]) => string[]; hosts?: string[] }): Promise<string | null> {
    const { folder, workflowID } = summary.workflow;
    const key = `${host}|${folderKey(folder)}|${workflowID}`;
    const send = async (): Promise<string | null> => {
      const latest = (this.workflows.value[`${host}|${folderKey(folder)}`] ?? []).find((w) => w.workflow.workflowID === workflowID) ?? summary;
      const current = latest.workflow.settings;
      const settings = change.settings ? change.settings(current) : current;
      try {
        const updated = await this.link.call("workflows/settings", {
          folder, workflowID, settings,
          ...(change.cooldown !== undefined ? { cooldown: change.cooldown } : {}),
          ...(change.labels !== undefined ? { labels: change.labels(current.labels) } : {}),
          ...(change.hosts !== undefined ? { hosts: change.hosts } : {}),
        }, host);
        this.placeWorkflow(updated, host);
        return null;
      } catch (error) {
        log("call.failed", error instanceof CallFailed ? error.code : undefined);
        return describe(error);
      }
    };
    const next = (this.settingsInFlight.get(key) ?? Promise.resolve()).then(send);
    this.settingsInFlight.set(key, next);
    void next.finally(() => { if (this.settingsInFlight.get(key) === next) this.settingsInFlight.delete(key); });
    return next;
  }

  /** What a runtime last advertised in a folder, for the workflow page's menus; starts nothing. */
  async rememberedOptions(host: string, runtimeID: string, folder: string): Promise<ConfigOption[]> {
    return (await this.link.call("options/remembered", { runtimeID, cwd: folder as never }, host).catch(() => null)) ?? [];
  }

  /** When this page last asked to warm each session, and why (#183). */
  private readonly prewarmed = new Map<string, number>();

  /**
   * Ask a session's host to start its runtime ahead of a prompt (#183): it was opened, or
   * somebody is typing in it. Once per session and reason in a while, however many keys;
   * the host debounces too. Silent: an older host that does not know the call is not warmed.
   */
  prewarm(host: string, agentID: string, why: "opened" | "typing"): void {
    const agent = this.agent(host, agentID);
    if (!agent || (agent.state !== "finished" && agent.state !== "stopped")) return;
    const key = `${host}|${agentID}|${why}`;
    const now = Date.now();
    if (now - (this.prewarmed.get(key) ?? 0) < 15_000) return;
    this.prewarmed.set(key, now);
    if (this.prewarmed.size > 64) {
      for (const [k, at] of this.prewarmed) if (now - at >= 15_000) this.prewarmed.delete(k);
    }
    void this.link.call("agents/prewarm", { agentID: agentID as UUID, why }, host).catch(() => {});
  }

  /** Mark as Unread / Mark as Read (#70). */
  async setUnread(host: string, agentID: string, unread: boolean): Promise<void> {
    await this.act("agents/setUnread", { agentID: agentID as UUID, unread }, host);
  }

  /** A menu's choice, shown at once and sent; the host's answer settles it either way. */
  async setOption(host: string, agentID: string, optionID: string, value: JSONValue): Promise<void> {
    this.pendingOptions.value = { ...this.pendingOptions.value,
      [agentID]: { ...this.pendingOptions.value[agentID], [optionID]: value } };
    await this.act("agents/setOption", { agentID: agentID as UUID, optionID, value }, host);
    const mine = { ...this.pendingOptions.value[agentID] };
    if (JSON.stringify(mine[optionID]) === JSON.stringify(value)) delete mine[optionID];
    this.pendingOptions.value = { ...this.pendingOptions.value, [agentID]: mine };
  }

  async setLabels(host: string, agentID: string, add: string[], remove: string[]): Promise<boolean> {
    const agent = await this.act("agents/setLabels", { agentID: agentID as UUID, add, remove }, host);
    if (agent) this.upsertAgent(agent, host);
    return agent !== null;
  }

  async labelVocabulary(host: string, folder: string): Promise<string[]> {
    return (await this.link.call("agents/labelVocabulary", { folder: folder as never }, host).catch(() => null)) ?? [];
  }

  async worktrees(host: string, folder: string): Promise<WorktreesListResponse | null> {
    return this.link.call("worktrees/list", { folder: folder as never }, host).catch(() => null);
  }

  /** One start's id per project, kept until that start succeeds, so a retry is not a second agent (#291). */
  private startRequests = new Map<string, UUID>();

  startRequestID(host: string, folder: string): UUID {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.startRequests.get(key);
    if (held) return held;
    const id = crypto.randomUUID().toUpperCase() as UUID;
    this.startRequests.set(key, id);
    return id;
  }

  /** The start went through. The next one from this project is a new request. */
  finishStartRequest(host: string, folder: string): void {
    this.startRequests.delete(`${host}|${folderKey(folder)}`);
  }

  /** A runtime started behind the new-agent form, so its choices are real ones. */
  async draft(host: string, runtimeID: string, cwd: string) {
    try {
      return await this.link.call("agents/options", { runtimeID, cwd: cwd as never, mcpServers: [] }, host);
    } catch (error) {
      return { failure: describe(error) };
    }
  }

  /** Files under the agent's folders for an `@` (#255): the host walks its own disk, as for the Remote. */
  async mentions(host: string, agentID: string, term: string): Promise<FileMentionDTO[]> {
    return this.link.call("files/mention", { agentID: agentID as UUID, term }, host).catch(() => []);
  }

  discardDraft(host: string, draftID: string): void {
    void this.link.call("agents/discardDraft", { draftID: draftID as UUID }, host).catch(() => {});
  }

  /**
   * Starts an agent; answers its id, or null with `problem` saying why. A runtime whose sandbox
   * will not start (064) answers what it said instead, for the form to offer Start without sandbox.
   */
  async start(host: string, request: StartRequest): Promise<string | SandboxWillNotStart | null> {
    try {
      return await this.lending("agents/start", request, host);
    } catch (error) {
      if (error instanceof CallFailed && error.code === Failure.sandboxWillNotStart && isSandboxRefusal(error.data)) {
        return { ...error.data, message: error.message };
      }
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      this.say(describe(error));
      return null;
    }
  }

  /** The newest page of each host's events, for the sidebar's Events row and page (#151). */
  readonly events = signal<Record<string, EventsPage>>({});
  /** Each host's day of spending and its limits, for Spending (#151). */
  readonly costs = signal<Record<string, CostState>>({});

  /** Finds a consequence's session by id when it is not already among the loaded rows. */
  async loadEventAgent(host: string, agentID: string): Promise<Agent | undefined> {
    const existing = this.agent(host, agentID);
    if (existing) return existing;
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: true, archivedOnly: false, lean: false,
      agentID: agentID as UUID, limit: 1,
    }, host).catch(() => null);
    const agent = listed?.find((candidate: Agent) => candidate.id === agentID);
    if (agent) this.addAgents([agent], host);
    return agent;
  }

  async loadEvents(host: string, limit = 50): Promise<void> {
    const page = await this.link.call("events/list", { limit }, host).catch(() => null);
    if (page) {
      const older = this.events.value[host]?.events ?? [];
      const merged = [...page.events, ...older.filter((event) => !page.events.some((next: ActivityEvent) => next.position === event.position))]
        .sort((a: ActivityEvent, b: ActivityEvent) => b.position - a.position);
      this.events.value = { ...this.events.value, [host]: { ...page, events: merged } };
    }
  }

  /** Appends one older page without losing the current head or waiting rows. */
  async loadOlderEvents(host: string): Promise<void> {
    const current = this.events.value[host];
    const before = current?.events[current.events.length - 1]?.position;
    if (!current?.hasMore || before === undefined) return;
    const page = await this.link.call("events/list", { limit: 100, before }, host).catch(() => null);
    if (!page) return;
    const held = this.events.value[host];
    if (!held) return;
    const byPosition = new Map([...held.events, ...page.events].map((event: ActivityEvent) => [event.position, event]));
    this.events.value = { ...this.events.value, [host]: {
      ...held, events: [...byPosition.values()].sort((a, b) => b.position - a.position), hasMore: page.hasMore,
    } };
  }

  async loadCost(host: string): Promise<void> {
    const state = await this.link.call("cost/state", {}, host).catch(() => null);
    if (state) this.costs.value = { ...this.costs.value, [host]: state };
  }
}
