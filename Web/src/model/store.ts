// What the page holds and what each notification means: AgentsModel (Client/AgentsModel.swift),
// ported by hand for the notifications the web remote hears and held to Fixtures/web/reducer
// (research R7). Nothing here decides anything; the hosts do.
import { batch, signal } from "@preact/signals";
import type {
  Agent, AgentRemovedNotification, ControlHost, ElicitationNotification, ElicitationRequest, EntryNotification,
  PermissionNotification, PermissionRequest, ProjectSummary, TranscriptEntry, TranscriptPage, TurnsPage, TurnSummary,
  WorkflowSummary,
} from "../protocol/generated";
import { CallFailed, type Link } from "../wire/link";
import { log } from "../log";
import { folderKey } from "./groups";
import { DisplayBuilder, type Item } from "./turns";

export { folderKey } from "./groups";

/** How many entries heard as they happened are kept to lay over a page that arrives late. */
const heardSincePageLimit = 1_000;

type ByHost<T> = Record<string, T[]>;

function newestFirst(agents: Agent[]): Agent[] {
  return agents.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
}

/**
 * The reducer: what each notification does to what is held. Kept apart from the link so the
 * fixtures can drive it, as `AgentsModel` is driven in Swift.
 */
export class Work {
  readonly hosts = signal<ControlHost[]>([]);
  readonly projects = signal<ByHost<ProjectSummary>>({});
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

  private display = new DisplayBuilder();
  private entryIDs = new Set<string>();
  private heardSincePage: TranscriptEntry[] = [];

  /** One notification from one host. Returns false for one this does not know. */
  apply(method: string, params: unknown, host: string): boolean {
    switch (method) {
      case "agent/changed":
        this.upsertAgent(params as Agent, host);
        return true;
      case "project/changed": {
        const summary = params as ProjectSummary;
        const list = (this.projects.value[host] ?? [])
          .filter((p) => folderKey(p.project.folder) !== folderKey(summary.project.folder));
        this.projects.value = { ...this.projects.value, [host]: [...list, summary] };
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

  upsertAgent(agent: Agent, host: string): void {
    const list = (this.agents.value[host] ?? []).filter((a) => a.id !== agent.id);
    this.agents.value = { ...this.agents.value, [host]: newestFirst([...list, agent]) };
  }

  /** One host's agents as it just listed them; every other host's are left alone. */
  replaceAgents(listed: Agent[], host: string): void {
    this.agents.value = { ...this.agents.value, [host]: newestFirst([...listed]) };
  }

  /** Archived agents of one project, listed when the fold opens, added beside the live ones. */
  addAgents(listed: Agent[], host: string): void {
    const ids = new Set(listed.map((a) => a.id));
    const kept = (this.agents.value[host] ?? []).filter((a) => !ids.has(a.id));
    this.agents.value = { ...this.agents.value, [host]: newestFirst([...kept, ...listed]) };
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
    this.hosts.value = hosts;
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
    const agents = await this.link.call("agents/list",
      { includeArchived: false, archivedCommands: false, archivedOnly: false }, host).catch(failed("agents/list"));
    if (agents) this.replaceAgents(agents, host);
    const projects = await this.link.call("projects/list", { includeArchived: false }, host).catch(failed("projects/list"));
    if (projects) this.projects.value = { ...this.projects.value, [host]: projects };
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

  /** Each project's workflows by `host|folder`, listed when the project is chosen (names only until US5). */
  readonly workflows = signal<Record<string, WorkflowSummary[]>>({});

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
      includeArchived: true, archivedCommands: false, archivedOnly: true, folder: folder as never,
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

  /** The finished turns first, as summaries, then the transcript from where the open turn starts. */
  private async loadTranscript(host: string, session: string): Promise<void> {
    const agentID = session as never;
    const turns = await this.link.call("agents/turns", { agentID, limit: 50 }, host)
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
}
