// What the page holds and what each notification means: AgentsModel (Client/AgentsModel.swift),
// ported by hand for the notifications the web remote hears and held to Fixtures/web/reducer
// (research R7). Nothing here decides anything; the hosts do.
import { batch, signal } from "@preact/signals";
import type {
  Agent, AgentRemovedNotification, ControlHost, ElicitationNotification, ElicitationRequest, EntryNotification,
  PermissionNotification, PermissionRequest, ProjectSummary, TranscriptEntry, TranscriptPage, TurnsPage, TurnSummary,
  WorkflowSummary, Attachment, FilesChangedNotification, ShowFileNotification, WorkflowRemovedNotification, DraftOptionsNotification, JSONValue, Methods, RuntimeAccount, RuntimeStatus,
  StartRequest, UUID, WorktreesListResponse, FileStamp, WriteFailure, CloneNotification, CloneSummary, DirectoryListing, LeaseSnapshot,
  DashboardChangedNotification, DashboardSnapshot, DashboardSummary,
} from "../protocol/generated";
import { Failure } from "../protocol/generated";
import { CallFailed, type Link } from "../wire/link";
import type { FolderGoneAsk } from "./missingFolder";
import { describe } from "./errors";
import { log } from "../log";
import { folderKey } from "./groups";
import { DisplayBuilder, type Item } from "./turns";

export { folderKey } from "./groups";

/** How many finished turns a chat opens with, as the window's (#90). */
const openingTurns = 12;

/** How many entries heard as they happened are kept to lay over a page that arrives late. */
const heardSincePageLimit = 1_000;

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
        const note = params as FilesChangedNotification;
        this.filesChanged.value = { host, agentID: note.agentID, folders: note.folders, at: Date.now() };
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
        batch(() => {
          this.agents.value = { ...this.agents.value, [host]: (this.agents.value[host] ?? []).filter((a) => a.id !== agentID) };
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

  upsertAgent(agent: Agent, host: string): void {
    const list = (this.agents.value[host] ?? []).filter((a) => a.id !== agent.id);
    this.agents.value = { ...this.agents.value, [host]: newestFirst([...list, agent]) };
  }

  /** One host's agents as it just listed them; every other host's are left alone. */
  replaceAgents(listed: Agent[], host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    this.agents.value = { ...this.agents.value, [host]: newestFirst(listed.map((a) => keepingLists(a, held.get(a.id)))) };
  }

  /** Archived agents of one project, listed when the fold opens, added beside the live ones. */
  addAgents(listed: Agent[], host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    const kept = [...held.values()].filter((a) => !listed.some((l) => l.id === a.id));
    this.agents.value = { ...this.agents.value,
      [host]: newestFirst([...kept, ...listed.map((a) => keepingLists(a, held.get(a.id)))]) };
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
    batch(() => {
      this.entries.value = [...this.entries.value, note.entry];
      this.items.value = this.display.items;
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

  agent(host: string, session: string): Agent | undefined {
    return (this.agents.value[host] ?? []).find((a) => a.id === session);
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
        void this.load();
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
   */
  async load(): Promise<void> {
    this.archivedLoaded.clear();
    const hosts = await this.link.call("hosts/list", {});
    this.takeHosts(hosts);
    await Promise.all(hosts.filter((host) => host.state === "online").map((host) => this.loadHost(host.id)));
    const watching = this.watching.value;
    if (watching) await this.loadTranscript(watching.host, watching.session);
  }

  private async loadHost(host: string): Promise<void> {
    // Logged by code alone: a host's words never reach the console (FR-033).
    const failed = (_what: string) => (error: unknown) => {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      return null;
    };
    // Lean: the columns read none of the option and command lists, 4 MB of 200 agents (#107).
    // The open session's come with loadWhole.
    const agents = await this.link.call("agents/list",
      { includeArchived: false, archivedCommands: false, archivedOnly: false, lean: true }, host).catch(failed("agents/list"));
    if (agents) this.replaceAgents(agents, host);
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

  /** The projects whose archived sessions have been listed since this connection opened. */
  private archivedLoaded = new Set<string>();


  async loadWorkflows(host: string, folder: string): Promise<void> {
    const listed = await this.link.call("workflows/list", { folder: folder as never }, host).catch(() => null);
    if (listed) this.workflows.value = { ...this.workflows.value, [`${host}|${folderKey(folder)}`]: listed };
  }

  /** One project's archived sessions, asked for when its fold opens. */
  async loadArchived(host: string, folder: string): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    if (this.archivedLoaded.has(key)) return;
    this.archivedLoaded.add(key);
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: false, archivedOnly: true, folder: folder as never, lean: true,
    }, host).catch(() => null);
    if (listed) this.addAgents(listed, host);
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

  /** Every entry of a finished turn, for the chat to open it. */
  async turnEntries(host: string, session: string, range: { start: number; end: number }): Promise<TranscriptEntry[]> {
    const page = await this.link.call("agents/transcript", {
      agentID: session as never, before: range.end, limit: range.end - range.start, from: range.start,
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
      if (runtimes) this.runtimes.value = { ...this.runtimes.value, [host]: runtimes };
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

  /** One project's Dashboard (074), asked for when it opens and on each dashboard/changed for it. */
  async loadDashboard(host: string, folder: string): Promise<void> {
    const snapshot = await this.link.call("dashboard/get", { folder: folder as never }, host).catch(() => null);
    if (!snapshot) return;
    const key = `${host}|${folderKey(folder)}`;
    this.dashboards.value = { ...this.dashboards.value, [key]: snapshot };
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

}
