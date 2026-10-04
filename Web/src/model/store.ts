// What the page holds and what each notification means: AgentsModel (Client/AgentsModel.swift),
// ported by hand for the notifications the web remote hears and held to Fixtures/web/reducer
// (research R7). Nothing here decides anything; the hosts do.
import { batch, computed, signal, type ReadonlySignal, type Signal } from "@preact/signals";
import type {
  Agent, AgentRemovedNotification, ControlHost, ElicitationNotification, ElicitationRequest, EntryNotification,
  PermissionNotification, PermissionRequest, ProjectSummary, TranscriptEntry, TranscriptPage, TurnsPage, TurnSummary,
  WorkflowSummary, Attachment, FilesChangedNotification, ShowFileNotification, WorkflowRemovedNotification, DraftOptionsNotification, JSONValue, Methods, RuntimeAccount, RuntimeStatus,
  StartRequest, UUID, WorktreesListResponse, FileStamp, WriteFailure, CloneNotification, CloneSummary, DirectoryListing, LeaseSnapshot,
  DashboardChangedNotification, DashboardOrder, DashboardSnapshot, DashboardSummary, CostState, EventsPage, ConfigOption, WorkflowSettings,
  PagesChangedNotification, PinsChangedNotification, PinView, ListCursor, ListRequest,
} from "../protocol/generated";
import { Failure } from "../protocol/generated";
import { CallFailed, type Link } from "../wire/link";
import type { FolderGoneAsk } from "./missingFolder";
import { describe } from "./errors";
import { log } from "../log";
import { folderKey, projectFolder, projectView, type ProjectView } from "./groups";
import { DisplayBuilder, keepingTurns, storedTurn, turns, type ChatTurn, type Item } from "./turns";
import { sortedRuntimes } from "./runtimes";
import { blockLines, openBlock } from "./block";
import { DashboardOrderSync } from "./dashboardOrderSync";

export { folderKey } from "./groups";

/** How many finished turns a chat opens with, as the window's (#90). */
const openingTurns = 12;

/** The most entries a host gives in one `agents/transcript` answer (TranscriptRequest.limitCeiling, #200). */
const transcriptCeiling = 1_000;

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

/** How long `files/changed` has to be quiet before the panes read the folders again. */
const filesSettle = 250;

/** How many archived sessions an open Archived fold lists: as many as it shows (#170). */
export const archivedPage = 50;

/** The most a search brings back from each host, a page at a time (#165, #193). */
export const searchShown = 200;

type ByHost<T> = Record<string, T[]>;

/**
 * A listed record, keeping the lists already held for it where it came without them: a lean
 * list must not empty the open session's menus (Agent.keepingLists). A runtime never takes
 * its lists back to nothing, so an empty one is one that was left out.
 */
export function keepingLists(listed: Agent, held: Agent | undefined): Agent {
  if (!held) return listed;
  return {
    ...listed,
    advertisedOptions: listed.advertisedOptions.length ? listed.advertisedOptions : held.advertisedOptions,
    availableCommands: listed.availableCommands.length ? listed.availableCommands : held.availableCommands,
    ...(listed.plans?.length || !held.plans ? {} : { plans: held.plans }),
  };
}

function newestFirst(agents: Agent[]): Agent[] {
  return agents.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
}

function sameAgents(a: readonly Agent[], b: readonly Agent[]): boolean {
  return a.length === b.length && a.every((agent, index) => agent === b[index]);
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
    return [...this.turns.value.map(storedTurnOf), ...this.heardTurns];
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

  /** The last file an agent asked to be put in front of the person (`agent/showFile`). */
  readonly shownFile = signal<{ host: string; agentID: string; path: string; line?: number | undefined; at: number } | null>(null);
  /** The last folders said to have changed, for a pane watching them (`files/changed`). */
  readonly filesChanged = signal<{ host: string; agentID: string; folders: string[]; at: number } | null>(null);

  /** Each project's Dashboard row by `host|folder` (074), kept by dashboard/changed. */
  readonly dashboardSummaries = signal<Record<string, DashboardSummary>>({});
  /** The Dashboards opened, by `host|folder`; asked again when `dashboardRevisions` moves. */
  readonly dashboards = signal<Record<string, DashboardSnapshot>>({});
  readonly dashboardRevisions = signal<Record<string, number>>({});

  /** Each project's pinned pages by `host|folder` (#159), kept by pins/changed. */
  readonly pins = signal<Record<string, PinView[]>>({});
  /** Bumped by pages/changed: a page shown may have changed on disk; read it again. */
  readonly pageRevisions = signal<Record<string, number>>({});

  /** Each project's workflows by `host|folder`, listed when the project is chosen. */
  readonly workflows = signal<Record<string, WorkflowSummary[]>>({});

  upsertWorkflow(summary: WorkflowSummary, host: string): void {
    const key = `${host}|${folderKey(summary.workflow.folder)}`;
    const list = (this.workflows.value[key] ?? []).filter((w) => w.workflow.workflowID !== summary.workflow.workflowID);
    this.workflows.value = { ...this.workflows.value, [key]: [...list, summary] };
  }

  /** The latest correction to a new agent's form, for the form holding that draft. */
  readonly draftOptions = signal<DraftOptionsNotification | null>(null);
  /** Each host's resources and who holds them (036, #116): read-only on the page. */
  readonly leases = signal<Record<string, LeaseSnapshot>>({});
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

  private filesSettling = new Map<string, { folders: Set<string>; timer: ReturnType<typeof setTimeout> }>();
  private display = new DisplayBuilder();
  private entryIDs = new Set<string>();
  private heardSincePage: TranscriptEntry[] = [];

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
        this.upsertWorkflow(params as WorkflowSummary, host);
        return true;
      case "dashboard/changed": {
        const note = params as DashboardChangedNotification;
        const key = `${host}|${folderKey(note.folder)}`;
        batch(() => {
          this.dashboardSummaries.value = { ...this.dashboardSummaries.value, [key]: note.summary };
          this.dashboardRevisions.value = { ...this.dashboardRevisions.value, [key]: (this.dashboardRevisions.value[key] ?? 0) + 1 };
        });
        return true;
      }
      case "pins/changed": {
        const note = params as PinsChangedNotification;
        this.pins.value = { ...this.pins.value, [`${host}|${folderKey(note.folder)}`]: note.pins };
        return true;
      }
      case "pages/changed": {
        const note = params as PagesChangedNotification;
        const key = `${host}|${folderKey(note.folder)}`;
        this.pageRevisions.value = { ...this.pageRevisions.value, [key]: (this.pageRevisions.value[key] ?? 0) + 1 };
        return true;
      }
      case "workflow/removed": {
        const note = params as WorkflowRemovedNotification;
        const key = `${host}|${folderKey(note.folder)}`;
        this.workflows.value = { ...this.workflows.value,
          [key]: (this.workflows.value[key] ?? []).filter((w) => w.workflow.workflowID !== note.workflowID) };
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
        const folders = new Set([...(this.filesSettling.get(key)?.folders ?? []), ...note.folders]);
        clearTimeout(this.filesSettling.get(key)?.timer);
        this.filesSettling.set(key, { folders, timer: setTimeout(() => {
          this.filesSettling.delete(key);
          this.filesChanged.value = { host, agentID: note.agentID, folders: [...folders], at: Date.now() };
        }, filesSettle) });
        return true;
      }
      case "storage/writeFailed":
        // Something nobody was waiting on was not kept: a full disk, or a folder refusing
        // writes. Said, as the window and the Remote say it (#88).
        this.say((params as WriteFailure).message);
        return true;
      case "leases/changed":
        this.leases.value = { ...this.leases.value, [host]: params as LeaseSnapshot };
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
  upsertAgent(agent: Agent, host: string): void {
    const list = [...(this.agents.value[host] ?? [])];
    const at = list.findIndex((a) => a.id === agent.id);
    const was = at >= 0 ? list.splice(at, 1)[0] : undefined;
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

  private takeEntry(note: EntryNotification, host: string): void {
    const watching = this.watching.value;
    if (!watching || watching.host !== host || watching.session !== note.agentID) return;
    this.heardSincePage.push(note.entry);
    if (this.heardSincePage.length > heardSincePageLimit) {
      this.heardSincePage.splice(0, this.heardSincePage.length - heardSincePageLimit);
    }
    // Already on the page: written before the host read it, and heard after.
    if (this.entryIDs.has(note.entry.id)) return;
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
    if (cut <= 0) {
      this.entries.value = entries;
      this.items.value = items;
      this.nextTrimAt = entries.length + entriesTrimmedAt - entriesKept;
      return;
    }
    const kept = entries.slice(cut);
    this.firstEntryIndex.value += cut;
    this.hasMoreBefore.value = true;
    this.refold(kept);
    this.nextTrimAt = Math.max(entriesTrimmedAt, kept.length + entriesTrimmedAt - entriesKept);
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
      this.turns.value = page.turns;
      this.firstTurn.value = page.firstTurn;
      this.openTurnStart.value = page.openStart;
    });
  }

  /** Earlier finished turns, put in front. */
  prependTurns(page: TurnsPage): void {
    const held = new Set(this.turns.value.map((t) => t.id));
    batch(() => {
      this.turns.value = [...page.turns.filter((t) => !held.has(t.id)), ...this.turns.value];
      this.firstTurn.value = page.firstTurn;
    });
  }

  /** The first page of the conversation, with what was heard and is not on it laid after it. */
  replaceTranscript(page: TranscriptPage): void {
    const onPage = new Set(page.entries.map((e) => e.id));
    const entries = [...page.entries, ...this.heardSincePage.filter((e) => !onPage.has(e.id))];
    this.heardSincePage = [];
    batch(() => {
      this.firstEntryIndex.value = page.firstIndex;
      this.hasMoreBefore.value = page.firstIndex > this.openTurnStart.value;
      this.refold(entries);
    });
  }

  /** An earlier page, put in front of what is held. */
  prepend(page: TranscriptPage): void {
    const entries = [...page.entries.filter((e) => !this.entryIDs.has(e.id)), ...this.entries.value];
    batch(() => {
      this.firstEntryIndex.value = page.firstIndex;
      this.hasMoreBefore.value = page.firstIndex > this.openTurnStart.value;
      this.refold(entries);
    });
  }

  private clearTranscript(): void {
    this.heardSincePage = [];
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

  /** Whether anything at all of the conversation comes before what is in hand. */
  get hasMoreOfTheConversation(): boolean {
    return this.hasMoreBefore.value || this.firstTurn.value > 0;
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

  /**
   * Everything again, on every connection, in the window's order (refreshEverything): agents,
   * then projects, then the cards and the open conversation at once. No cursors on the wire.
   * One at a time: asked again while running, it runs once more after.
   */
  load(): Promise<void> {
    return this.once("*", async () => {
      const hosts = await this.link.call("hosts/list", {});
      this.takeHosts(hosts);
      await Promise.all(hosts.filter((host) => host.state === "online").map((host) => this.loadHost(host.id)));
      const watching = this.watching.value;
      if (watching) await this.loadTranscript(watching.host, watching.session);
    });
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
    const now = hosts.find((h) => h.id === host);
    if (!now) return this.forgetHost(host);
    if (now.state !== "online") return;
    await this.loadHost(host);
    const watching = this.watching.value;
    if (watching?.host === host) await this.loadTranscript(host, watching.session);
  }

  /** A host removed: what was held of it goes with it. */
  private forgetHost(host: string): void {
    const without = <T,>(held: Record<string, T>) => Object.fromEntries(Object.entries(held).filter(([key]) => key !== host));
    const notOf = <T,>(held: Record<string, T>) => Object.fromEntries(Object.entries(held).filter(([key]) => !key.startsWith(`${host}|`)));
    batch(() => {
      this.setAgents(host, []);
      this.agents.value = without(this.agents.value);
      this.projects.value = without(this.projects.value);
      this.clones.value = without(this.clones.value);
      this.permissions.value = without(this.permissions.value);
      this.elicitations.value = without(this.elicitations.value);
      this.workflows.value = notOf(this.workflows.value);
      this.dashboardSummaries.value = notOf(this.dashboardSummaries.value);
      this.pins.value = notOf(this.pins.value);
    });
    for (const key of [...this.archivedLoaded]) if (key.startsWith(`${host}|`)) this.archivedLoaded.delete(key);
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
    // and the workflows and Dashboards on screen asked again: they may have changed meanwhile.
    const prefix = `${host}|`;
    const reopened = [...this.archivedLoaded].filter((key) => key.startsWith(prefix));
    for (const key of reopened) {
      this.archivedLoaded.delete(key);
      void this.loadArchived(host, key.slice(prefix.length));
    }
    for (const key of Object.keys(this.workflows.value)) if (key.startsWith(prefix)) void this.loadWorkflows(host, key.slice(prefix.length));
    for (const key of Object.keys(this.dashboards.value)) if (key.startsWith(prefix)) void this.loadDashboard(host, key.slice(prefix.length));
    // A search on show: the live list just let its archived matches go, so they are asked again.
    if (this.searchWords) {
      this.searched.delete(host);
      const { [host]: _again, ...rest } = this.searchNext.value;
      this.searchNext.value = rest;
      void this.search({ includeArchived: true, archivedCommands: false, archivedOnly: false, lean: true,
        limit: searchShown, query: this.searchWords }, host, this.searchTurn);
    }
    const projects = await this.link.call("projects/list", { includeArchived: false }, host).catch(failed("projects/list"));
    if (projects) this.projects.value = { ...this.projects.value, [host]: projects };
    const clones = await this.link.call("projects/clones", {}, host).catch(failed("projects/clones"));
    if (clones) this.clones.value = { ...this.clones.value, [host]: clones };
    void this.loadRuntimes(host);
    void this.link.call("dashboard/summaries", {}, host).then((listed) => {
      const held = Object.fromEntries(Object.entries(this.dashboardSummaries.value).filter(([key]) => !key.startsWith(`${host}|`)));
      for (const summary of listed) held[`${host}|${folderKey(summary.folder)}`] = summary;
      this.dashboardSummaries.value = held;
    }).catch(failed("dashboard/summaries"));
    void this.link.call("pins/list", {}, host).then((listed) => {
      const held = Object.fromEntries(Object.entries(this.pins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      for (const project of listed) held[`${host}|${folderKey(project.folder)}`] = project.pins;
      this.pins.value = held;
    }).catch(failed("pins/list"));
    void this.link.call("leases/snapshot", {}, host).then((snapshot) => {
      this.leases.value = { ...this.leases.value, [host]: snapshot };
    }).catch(failed("leases/snapshot"));
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


  async loadWorkflows(host: string, folder: string): Promise<void> {
    const listed = await this.link.call("workflows/list", { folder: folder as never }, host).catch(() => null);
    if (listed) this.workflows.value = { ...this.workflows.value, [`${host}|${folderKey(folder)}`]: listed };
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
    const agentID = session as never;
    // The last 12, as the window opens a chat (#90); the rest come as the top is reached.
    const turns = await this.link.call("agents/turns", { agentID, limit: openingTurns }, host)
      .catch(() => ({ turns: [], firstTurn: 0, openStart: 0 }));
    const page = await this.link.call("agents/transcript", { agentID, limit: 200, from: turns.openStart }, host)
      .catch(() => null);
    // A chat opened since is not this one.
    const now = this.watching.value;
    if (!page || now?.host !== host || now.session !== session) return;
    batch(() => {
      this.replaceTurns(turns);
      this.replaceTranscript(page);
    });
  }

  /** Further back: the open turn's earlier entries, then the turns before it. */
  async loadEarlier(): Promise<void> {
    const watching = this.watching.value;
    if (!watching || !this.hasMoreOfTheConversation) return;
    const agentID = watching.session as never;
    if (!this.hasMoreBefore.value) {
      const turns = await this.link.call("agents/turns", { agentID, before: this.firstTurn.value, limit: 50 }, watching.host)
        .catch(() => null);
      if (turns && this.watching.value === watching) this.prependTurns(turns);
      return;
    }
    const page = await this.link.call("agents/transcript", {
      agentID, before: this.firstEntryIndex.value, limit: 200, from: this.openTurnStart.value,
    }, watching.host).catch(() => null);
    if (page && this.watching.value === watching) this.prepend(page);
  }

  /** A finished turn's entries, for the chat to open it: the last page of them when the turn is
   * longer than a host gives in one answer (#200). */
  async turnEntries(host: string, session: string, range: { start: number; end: number }): Promise<TranscriptEntry[]> {
    const page = await this.link.call("agents/transcript", {
      agentID: session as never, before: range.end, limit: Math.min(range.end - range.start, transcriptCeiling), from: range.start,
    }, host).catch(() => null);
    return page?.entries ?? [];
  }

  // MARK: What the browser sends (071 US3)

  /** Each runtime and what each says it can take, by host. */
  readonly runtimes = signal<Record<string, RuntimeStatus[]>>({});
  readonly accounts = signal<Record<string, RuntimeAccount[]>>({});
  /** A choice made on a menu that the host hasn't confirmed, by agent then option. */
  readonly pendingOptions = signal<Record<string, Record<string, JSONValue>>>({});
  /** What is typed and attached, per session or per new-agent form, kept in memory only. */
  readonly drafts = new Map<string, { text: string; attachments: Attachment[] }>();

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

  /** The folders at `path` on `host`, for choosing one as a project (037). Throws a refusal. */
  browse(host: string, path: string): Promise<DirectoryListing> {
    return this.link.call("files/browse", { path }, host);
  }

  /** What runs on a host, and what each runtime takes; asked once a connection. */
  async loadRuntimes(host: string): Promise<void> {
    const [runtimes, accounts, modes] = await Promise.all([
      this.link.call("runtimes/list", {}, host).catch(() => null),
      this.link.call("runtimes/accounts", {}, host).catch(() => null),
      this.link.call("modes/remembered", {}, host).catch(() => null),
    ]);
    batch(() => {
      if (runtimes) this.runtimes.value = { ...this.runtimes.value, [host]: sortedRuntimes(runtimes) };
      if (accounts) this.accounts.value = { ...this.accounts.value, [host]: accounts };
      if (modes) this.rememberedModes.value = { ...this.rememberedModes.value, [host]: modes };
    });
  }

  account(host: string, runtimeID: string): RuntimeAccount | undefined {
    return (this.accounts.value[host] ?? []).find((a) => a.runtimeID === runtimeID);
  }

  async prompt(host: string, agentID: string, text: string, attachments: Attachment[]): Promise<boolean> {
    try {
      await this.link.call("agents/prompt", { agentID: agentID as UUID, text, attachments, from: "person" }, host);
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

  watchFolder(host: string, agentID: string, folder: string): void {
    void this.link.call("files/watch", { agentID: agentID as UUID, folder }, host).catch(() => {});
  }

  unwatchFolder(host: string, agentID: string, folder: string): void {
    void this.link.call("files/unwatch", { agentID: agentID as UUID, folder }, host).catch(() => {});
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

  /** A file of the project's: a pinned page, a page tile's, or what an HTML page draws from. */
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

  /** The order writes and fetches of each Dashboard, kept in step (#176, #193). */
  private dashboardOrders = new DashboardOrderSync();

  /**
   * One project's Dashboard (074), asked for when it opens and on each dashboard/changed for it.
   * A reply older than one already shown is dropped.
   */
  async loadDashboard(host: string, folder: string): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const ticket = this.dashboardOrders.beginFetch(key);
    const snapshot = await this.link.call("dashboard/get", { folder: folder as never }, host).catch(() => null);
    const shown = snapshot && this.dashboardOrders.accept(key, snapshot, ticket);
    if (shown) this.dashboards.value = { ...this.dashboards.value, [key]: shown };
  }

  /** Hide, Show or Remove: the person's, from any client (FR-027 to FR-029). */
  async actOnTile(host: string, folder: string, method: "dashboard/hide" | "dashboard/show" | "dashboard/remove", id: string): Promise<void> {
    await this.act(method, { folder: folder as never, id }, host);
    await this.loadDashboard(host, folder);
  }

  /** Update now (#146): the dashboard workflow, or a one-off agent; a refusal is said. */
  async updateDashboard(host: string, folder: string): Promise<void> {
    await this.act("dashboard/update", { folder: folder as never }, host);
    await this.loadDashboard(host, folder);
  }

  /**
   * A drop or a Move item (#147): shown at once, then the whole order sent. One send at a time,
   * the newest order next, so the host ends with the last drop (#176, #193).
   */
  async arrangeDashboard(host: string, folder: string, order: DashboardOrder): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const snapshot = this.dashboards.value[key];
    if (snapshot) this.dashboards.value = { ...this.dashboards.value, [key]: { ...snapshot, order } };
    if (!this.dashboardOrders.arrange(key, order)) return;
    for (let next = this.dashboardOrders.takeUnsent(key); next; next = this.dashboardOrders.takeUnsent(key)) {
      await this.act("dashboard/arrange", { folder: folder as never, order: next }, host);
    }
    await this.loadDashboard(host, folder);
  }

  /** Run now (US5). The session it starts arrives as any other does, by agent/changed. */
  async runWorkflow(host: string, summary: WorkflowSummary): Promise<void> {
    const ran = await this.act("workflows/run", { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID }, host);
    if (ran) this.upsertWorkflow(ran, host);
  }

  /** Turn Off / Turn On (#100): it keeps its place on the list either way. */
  async setWorkflowEnabled(host: string, summary: WorkflowSummary, enabled: boolean): Promise<void> {
    const changed = await this.act("workflows/enable",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, enabled }, host);
    if (changed) this.upsertWorkflow(changed, host);
  }

  /** Approve (#142): the digest is what the page was showing, so a file changed since still waits. */
  async approveWorkflow(host: string, summary: WorkflowSummary): Promise<void> {
    if (!summary.awaitingApproval) return;
    const changed = await this.act("workflows/approve",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, digest: summary.awaitingApproval.digest }, host);
    if (changed) this.upsertWorkflow(changed, host);
  }

  /** Archive or Bring Back (#142), as the window's page has them. */
  async setWorkflowArchived(host: string, summary: WorkflowSummary, archived: boolean): Promise<void> {
    const changed = await this.act("workflows/archive",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, archived }, host);
    if (changed) this.upsertWorkflow(changed, host);
  }

  private settingsInFlight = new Map<string, Promise<unknown>>();

  /**
   * One setting, its label list or its cooldown (#162), written to the file through the daemon
   * as the window's page writes it. `change` is applied to what the file says when the call is
   * sent, after any earlier change to the same workflow has been answered, so two quick changes
   * cannot undo each other. The answer replaces the one summary; the list is not asked for
   * again. Answers the daemon's refusal, for the page to say beside the controls, or null.
   */
  setWorkflowSettings(host: string, summary: WorkflowSummary,
                      change: { settings?: (s: WorkflowSettings) => WorkflowSettings; cooldown?: string; labels?: (labels: string[]) => string[] }): Promise<string | null> {
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
        }, host);
        this.upsertWorkflow(updated, host);
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

  /** A runtime started behind the new-agent form, so its choices are real ones. */
  async draft(host: string, runtimeID: string, cwd: string) {
    try {
      return await this.link.call("agents/options", { runtimeID, cwd: cwd as never, mcpServers: [] }, host);
    } catch (error) {
      return { failure: describe(error) };
    }
  }

  discardDraft(host: string, draftID: string): void {
    void this.link.call("agents/discardDraft", { draftID: draftID as UUID }, host).catch(() => {});
  }

  /** Starts an agent; answers its id, or null with `problem` saying why. */
  async start(host: string, request: StartRequest): Promise<string | null> {
    return this.act("agents/start", request, host);
  }

  /** The newest page of each host's events, for the sidebar's Events row and page (#151). */
  readonly events = signal<Record<string, EventsPage>>({});
  /** Each host's day of spending and its limits, for Spending (#151). */
  readonly costs = signal<Record<string, CostState>>({});

  async loadEvents(host: string, limit = 50): Promise<void> {
    const page = await this.link.call("events/list", { limit }, host).catch(() => null);
    if (page) this.events.value = { ...this.events.value, [host]: page };
  }

  async loadCost(host: string): Promise<void> {
    const state = await this.link.call("cost/state", {}, host).catch(() => null);
    if (state) this.costs.value = { ...this.costs.value, [host]: state };
  }
}
