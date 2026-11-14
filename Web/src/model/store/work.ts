// What the page holds, as the Work class: its state, in slices (#5384).
import type { ExportImportBusy } from "../exports";
import { type HeardLiveFrame } from "../liveTile";
import { computed, signal, type ReadonlySignal, type Signal } from "@preact/signals";
import type { Agent, BrowserFrame, BrowserPageState, LiveSource, ControlMachine, ElicitationRequest, PermissionRequest, FolderSummary, TranscriptEntry, TurnSummary, WorkflowSummary, DraftOptionsNotification, JSONValue, AccountProfile, CloneSummary, LeaseSnapshot, HostedMCPSnapshot, MCPHealthSnapshot, DiskState, CapacityState, EventsPage, PinView, ReviewPull, CheckSuggestion, MachineJoinStatus, RequiredCapabilities, KeptDelivered, KeptRequest, Approval, Achievements, Multiplier, FolderWorktrees, WorktreeSize, BackupState, CapReached, ChannelLinkRequest, ConnectReport, ControlPerson, DailySummarySettings, SummaryPage, DesktopControlSettings, WakeSettings, JoinRequest, PeopleList, PersonRow, SecretsLeft, PolicyView, PolicyState, PassThroughName, SignInRequest, CatalogRequest, BudgetRequest, RemoveRequest, Connection, MoveNotification, Request as PersonRequest, OutsideAccount, ListRevision, PlaneMoveReport, UserSecretRow, WebRemoteStatus, WireDate } from "../../protocol/generated";
import { type Artifact } from "../artifacts";
import { folderKey, type FolderView } from "../groups";
import { decideMacHostNotice, steadyNotice, type MacHostNotice } from "../macHostNotice";
import { DisplayBuilder, keepingTurns, turns, type ChatTurn, type Item } from "../turns";
import { shownItems } from "../thoughts";
import { firstAsk, type GitLendAsk } from "../gitLending";
import type { ChartHint } from "../chart";
import { PendingWrites } from "../pendingWrites";
import { type Sending } from "../sending";
import { type Inverse } from "../changeUndo";
import { type MachineJoin } from "../machineRow";
import { type NewMachineAsk, historyEntriesCap, historyTurnsCap, entriesTrimmedAt, type ByHost, keepingLatestByID, storedTurnOf, type UsageRead } from "./shared";
import { mixin } from "./mixin";
import { chatStateMethods } from "./chatState";
import { reducerMethods } from "./reducer";
import { agentListsMethods } from "./agentLists";
import { transcriptMethods } from "./transcript";
import { hostRowsMethods } from "./hostRows";

/**
 * The reducer: what each notification does to what is held. Kept apart from the link so the
 * fixtures can drive it, as `AgentsModel` is driven in Swift.
 */
export class Work {
  readonly hosts = signal<ControlMachine[]>([]);

  readonly folders = signal<ByHost<FolderSummary>>({});

  /** The accounts added to each host's runtimes (#840), by host. */
  readonly accountProfiles = signal<Record<string, AccountProfile[]>>({});

  /** The clones under way on each host (027), drawn where the folder will be. */
  readonly clones = signal<ByHost<CloneSummary>>({});

  /**
   * Moves to another machine under way, by session, whichever host makes them (#4641), and those
   * that stopped with a problem, until the session is opened: a line on the session's row.
   */
  readonly moves = signal<Record<string, MoveNotification>>({});

  /** What to do once a move this page asked for is there: open the session there (#4641). */
  readonly moveFollows = new Map<string, () => void>();

  readonly agents = signal<ByHost<Agent>>({});

  readonly permissions = signal<ByHost<PermissionRequest>>({});

  readonly elicitations = signal<ByHost<ElicitationRequest>>({});

  /** The conversation being read, and only that one. */
  readonly watching = signal<{ host: string; session: string } | null>(null);

  /**
   * The prompts on their way to each agent, by `host|agentID` (#4814): drawn in its chat as the
   * person's bubble at once, until the host's own entry for one lands, and gone when one did not go.
   */
  readonly sending = signal<Record<string, Sending[]>>({});

  /** The conversation last looked for: once it is, one not in hand has gone (#2652), as PoppedChat.looked. */
  readonly lookedFor = signal<{ host: string; session: string } | null>(null);

  readonly entries = signal<TranscriptEntry[]>([]);

  /** Where the open chat's entries came from (#4790): none yet, this device's copy, or its host. */
  readonly transcriptSource = signal<"none" | "device" | "host">("none");

  /** The hosts drawn from this device's copy (#4790) whose own answer has not come yet. */
  readonly fromDevice = signal<ReadonlySet<string>>(new Set());

  /** When the oldest machine drawn from this device's copy was read (#5141), for the "Last update" line. */
  readonly copyAt = computed(() => {
    const reads = [...this.fromDevice.value].map((host) => this.copyReads.get(host)).filter((at): at is number => at !== undefined);
    return reads.length > 0 ? Math.min(...reads) : undefined;
  });

  readonly copyReads = new Map<string, number>();

  /** The page as the chat draws it, folded once as each entry lands. */
  readonly items = signal<Item[]>([]);

  /**
   * Everything exchanged in `entries`, newest first, as `artifactsIn` gives it: folded as each
   * entry lands, and moved only when one brings something (#946).
   */
  readonly artifacts = signal<readonly Artifact[]>([]);

  /** The finished turns before `entries`, as stored. `entries` start at `openTurnStart`. */
  readonly turns = signal<TurnSummary[]>([]);

  /**
   * The chat's turns, stored then heard, each the same object until something in it changes,
   * so an entry redraws the one turn it landed in (#170).
   */
  readonly chatTurns: ReadonlySignal<ChatTurn[]> = computed(() => {
    // Thoughts left off unless the chat menu's Show Thoughts shows them (#1725, #2383).
    this.heardTurns = keepingTurns(turns(shownItems(this.items.value)), this.heardTurns);
    return keepingLatestByID([...this.turns.value.map(storedTurnOf), ...this.heardTurns]);
  });

  heardTurns: ChatTurn[] = [];

  /**
   * Whether the chat is following the end, as the chat says. The page is trimmed at the front
   * only while it is: rows somebody scrolled up to read are never taken from under them.
   */
  isFollowingEnd = true;

  nextTrimAt = entriesTrimmedAt;

  readonly firstTurn = signal(0);

  /** How many of the person's prompts come before `turns`, as the host counts them (#1862). Null from a host too old to say. */
  readonly firstPrompt = signal<number | null>(null);

  readonly openTurnStart = signal(0);

  readonly firstEntryIndex = signal(0);

  readonly hasMoreBefore = signal(false);

  /**
   * Why the open chat's history did not load, or only its earlier turns (#400), until a page lands
   * or the chat is left. Said in the chat with Try Again, where a failed load used to leave it blank.
   */
  readonly transcriptLoadFailure = signal<{ nothingLoaded: boolean; reason: string } | null>(null);

  /** The latest load of the open chat: an older answer landing after a newer one is dropped (#400). */
  transcriptLoads = 0;

  /**
   * The live tile's latest frame of each source (#3004, #4140, `live/frame`): a host sends frames
   * only to the page with that agent's chat in front. Each is replaced by the next of its source,
   * never kept (FR-016).
   */
  readonly liveFrames = signal<Partial<Record<LiveSource, HeardLiveFrame>>>({});

  /** Each host's browser as the Agent Browser shows it (#3528, #4141): its state, by host. */
  readonly browserStates = signal<Record<string, BrowserPageState>>({});

  /** The newest frame of the browser the tab watches (#3528). Replaced by the next, never kept. */
  readonly browserFrame = signal<{ host: string; frame: BrowserFrame } | null>(null);

  /** The last file an agent asked to be put in front of the person (`agent/showFile`). */
  readonly shownFile = signal<{ host: string; agentID: string; path: string; line?: number | undefined; at: number } | null>(null);

  /** A new agent a view filled in (#834, agents/start-agent), for the new-agent form on that
   *  folder to take: the prompt, the labels and the worktree. Starting it is still the person's move. */
  readonly offeredStart = signal<{ host: string; folder: string; start: { prompt: string; labels: string[]; worktree?: string | undefined; branch?: string | undefined } } | null>(null);

  /**
   * How to draw each CSV an agent showed as a chart (#836), by `host|path`: from `agent/showFile`
   * and from the chat's file cards. The pane looks a CSV up here; a Vega-Lite spec says it itself.
   */
  readonly chartHints = signal<Record<string, ChartHint>>({});

  /** The last folders said to have changed, for a pane watching them (`files/changed`). */
  readonly filesChanged = signal<{ host: string; agentID: string; folders: string[]; many: boolean; at: number } | null>(null);

  /** Each folder's pinned pages by `host|folder` (#159), kept by pins/changed. */
  readonly pins = signal<Record<string, PinView[]>>({});

  /** Each folder's pinned sessions by `host|folder` (#180), in their order, kept by pins/changed. */
  readonly sessionPins = signal<Record<string, string[]>>({});

  /** Each folder's pinned workflows' ids by `host|folder` (#432), in their order, kept by pins/changed. */
  readonly workflowPins = signal<Record<string, string[]>>({});

  /** Each folder's servers' list views by `host|folder` (#2032), the hidden ones marked, kept by pins/changed. */
  readonly serverViews = signal<Record<string, PinView[]>>({});

  /** Each folder's pull requests waiting for the person's approval by `host|folder` (#3330), newest first, kept by pins/changed. */
  readonly reviewPulls = signal<Record<string, ReviewPull[]>>({});

  /** Each host's open requests to the person (#3864), oldest first: Needs You's rows. */
  readonly personRequests = signal<Record<string, PersonRequest[]>>({});

  /** Each folder's suggestions of the daily checks by `host|folder` (#3331), newest first, kept by pins/changed. */
  readonly checkSuggestions = signal<Record<string, CheckSuggestion[]>>({});

  /** Bumped by pages/changed: a page shown may have changed on disk; read it again. */
  readonly pageRevisions = signal<Record<string, number>>({});

  /** Each folder's workflows by `host|folder`, listed while that folder is open. */
  readonly workflows = signal<Record<string, WorkflowSummary[]>>({});

  /** One folder's list, so a change redraws that fold and no other (#291). */
  workflowSlices = new Map<string, Signal<WorkflowSummary[]>>();

  /** Folders whose workflow list is on screen, and how many views hold it. */
  workflowHolds = new Map<string, number>();

  /** Lists a fetch has answered, so a page can tell "loading" from "gone". */
  workflowsLoaded = new Set<string>();

  /** The latest correction to a new agent's form, for the form holding that draft. */
  readonly draftOptions = signal<DraftOptionsNotification | null>(null);

  /** Each host's resources and who holds them (036, #116): read-only on the page. */
  readonly leases = signal<Record<string, LeaseSnapshot>>({});

  /** The MCP servers each host runs for every agent (#488), replaced whole by `mcp/hostedChanged`. */
  readonly hostedMCP = signal<Record<string, HostedMCPSnapshot>>({});

  /** Every MCP server each host's mcp.json files name, and how each is doing (#753), replaced whole
   * by `mcp/healthChanged`. */
  readonly mcpHealth = signal<Record<string, MCPHealthSnapshot>>({});

  /** Each host's connections that ended (#3407), which turn the Connectors rows red. The host tells no client, so they are
   * read when it connects, every few minutes, and whenever Connectors reads them. */
  readonly endedConnections = signal<Record<string, Connection[]>>({});

  /** A project's Connectors folder (`host|folder`), and the ended connection its slots use (#3407). */
  readonly endedInFolders = signal<Record<string, Connection>>({});

  /** Each host's chats it is bringing back by itself after a restart: Coming back (#251). */
  readonly resuming = signal<Record<string, readonly string[]>>({});

  /** Each host's volumes low on space (#196), replaced whole by each disk/changed, never merged. */
  readonly disk = signal<Record<string, DiskState>>({});

  /** The newest page of each host's events, for the sidebar's Events row and page (#151); events/changed keeps who waits. */
  readonly events = signal<Record<string, EventsPage>>({});

  /** Each host's capacity level (#4748), from capacity/state on connect and each capacity/changed: its row says it. */
  readonly capacity = signal<Record<string, CapacityState>>({});

  /** The person's Mac's backups (#1810), for Settings ▸ Backups: null until it has said, or from a
   * host too old to keep backups, which leaves the section out. */
  readonly backups = signal<BackupState | null>(null);

  /** When `backups` was last read or told (#5146), for its "Last update" line. */
  readonly backupsAt = signal<number | undefined>(undefined);

  /** Desktop control's own off-by-default switch (#3004, US2), for Settings: null until it has
   * said, or from a host too old to know the method, which leaves the section out. */
  readonly desktopControl = signal<DesktopControlSettings | null>(null);

  /** Where the window on this Mac is in a Connect to Another… asked for here (#4257), from
   * control/connectReported: null until it says. */
  readonly connectReport = signal<ConnectReport | null>(null);

  /** How Move to Another Machine… and Run It Here Again… stand on the Mac that does them (#4255), in its window's
   * words, from control/planeMoveReported: null until a window has said. */
  readonly planeMoveReport = signal<PlaneMoveReport | null>(null);

  /** The Mac's Sleep settings (#4066): how many finished sessions keep their runtime ready for a reply,
   * and how long one with background processes is kept. Null until the Mac's host has said, or from a
   * host too old to know the method, which leaves the section out. */
  readonly wakeSettings = signal<WakeSettings | null>(null);

  /** The daily summary's Off / Summary control and its time (#3351), for Settings ▸ Workflows: null
   * until the Mac's host has said, or from a host too old to know the method, which leaves it out. */
  readonly dailySummary = signal<DailySummarySettings | null>(null);

  /** The daily summary's saved pages on the Mac's host, newest first (#3721): the Summary row and
   * page. Empty from a host too old to know `summaries/list`. */
  readonly summaryPages = signal<SummaryPage[]>([]);

  /** Each host's folders' worktrees (#790), as `worktrees/all` last answered: asked when Activity ▸
   * Worktrees is shown, not kept up by the host. */
  readonly worktreeLists = signal<Record<string, FolderWorktrees[]>>({});

  /** Each worktree's size as `worktrees/sized` said since the list, by host and root: newer than it. */
  readonly worktreeSizes = signal<Record<string, Record<string, WorktreeSize>>>({});

  /** Each host's files it could not read in this run (#205, #223), replaced whole by each store/notesChanged. */
  readonly storeNotes = signal<Record<string, string[]>>({});

  /** Each host's achievements (#984), replaced whole by each achievements/changed. */
  readonly achievements = signal<Record<string, Achievements>>({});

  /** Each host's Multiplier (#3990), from multiplier/state and replaced whole by each multiplier/changed. With a
   * control plane the host counts all the person's machines (#3903), so the page asks only the Mac's. */
  readonly multiplier = signal<Record<string, Multiplier>>({});

  /** When this page last read each host's usage (#5144), for the pages' "Last update" line. */
  readonly usageReadAt = signal<Record<string, Partial<Record<UsageRead, number>>>>({});

  /**
   * The control plane's machine, its home host, and how this Mac's host says its join stands
   * (#666), from `control/status`.
   */
  readonly plane = signal<{ machineID: string; homeHost?: string | undefined; thisMacHost?: MachineJoinStatus | undefined;
    name?: string; version?: string; required?: RequiredCapabilities | undefined; capabilities?: string[] | undefined;
    startedAt?: WireDate | undefined; web?: WebRemoteStatus | undefined; restartable?: boolean | undefined;
    publicWeb?: string | undefined } | null>(null);

  /**
   * The person's Mac (#1501): the host that keeps their display choices (#1033) and that the page
   * calls "This Mac". It is `mac`, or, with a control plane elsewhere, where this Mac's host joins
   * with an id of its own (#1496), the control plane's home host when it is a Mac. The page is on
   * no Mac, so it cannot find the host by its own machine id as the window does.
   */
  readonly macHostID: ReadonlySignal<string> = computed(() => {
    const hosts = this.hosts.value;
    if (hosts.some((h) => h.id === "mac")) return "mac";
    const home = this.plane.value?.homeHost;
    const listed = home ? hosts.find((h) => h.id === home) : undefined;
    return listed && listed.platform.startsWith("macOS") ? listed.id : "mac";
  });

  /** Whether the person has a Mac among their machines (#3382, #3425): with none, a line says what to do here. */
  readonly hasMac: ReadonlySignal<boolean> = computed(() => this.hosts.value.some((h) => this.isMac(h.id)));

  /** Why this Mac's host is quiet, as the window says it (#666), or nil while it is online. */
  readonly macHostNoticeNow: ReadonlySignal<MacHostNotice | null> = computed(() => {
    const plane = this.plane.value;
    const macID = this.macHostID.value;
    const mac = this.hosts.value.find((h) => h.id === macID);
    const onThisMac = !!plane?.machineID && plane.machineID === mac?.machineID;
    return decideMacHostNotice(onThisMac, mac?.state, plane?.thisMacHost);
  });

  /** That notice, held a few seconds after it goes, so a host that keeps dropping and joining does not flicker it. */
  readonly macHostNotice: ReadonlySignal<MacHostNotice | null> = steadyNotice(this.macHostNoticeNow);

  /** Who this client belongs to (#994), from `control/status`: none from a control plane before it. */
  readonly person = signal<ControlPerson | null>(null);

  /** The line a server runs to ask to join as this client's person, with no code (#994), from `control/status`. */
  readonly joinCommand = signal<string | null>(null);

  /** Machines waiting for the person's approval to join (#994), kept by control/joinRequested and joinDecided. */
  readonly joinRequests = signal<JoinRequest[]>([]);

  /** Channel identities waiting for the person to link them, or an admin to send on (#1762). */
  readonly linkRequests = signal<ChannelLinkRequest[]>([]);

  /** Requests for an MCP server or skill waiting for an admin (#2019, M5); empty for a member. */
  readonly governanceRequests = signal<CatalogRequest[]>([]);

  /** Ask for More requests of today waiting for an admin (#3262); empty for a member. */
  readonly budgetRequests = signal<BudgetRequest[]>([]);

  /** People their provider's SCIM deleted, suspended until an admin removes them (#1002); empty for a member. Here,
   * not in the Requests page, so the Console's count has them (#2436). */
  readonly removeRequests = signal<RemoveRequest[]>([]);

  /** Goes up on each control/governanceRequested, so a person's own requests load again. */
  readonly governanceChanges = signal(0);

  /** Whom an admin may send a link request on to (#1762); empty for a member. */
  readonly linkPeople = signal<PersonRow[]>([]);

  /** GitHub sign-ins on new clients waiting for the person's Approve (#995). */
  readonly signInRequests = signal<SignInRequest[]>([]);

  /** Goes up on control/linksChanged, so Settings ▸ Channels loads again. */
  readonly linksChanges = signal(0);

  /** Goes up on control/projectsChanged (#2317), so Console ▸ Projects loads again (#2671). */
  readonly projectsChanges = signal(0);

  /** Goes up on control/lineageChanged (#4276), so Work ▸ Timeline reads the sessions again. */
  readonly lineageChanges = signal(0);

  /** Counts each control/clientChanged: a pairing code's dialog (#4253) names the client it let in. */
  readonly clientChanges = signal(0);

  /** Counts each control/peopleChanged (#994): Settings ▸ People loads its list again when it moves. */
  readonly peopleChanges = signal(0);

  /**
   * The people this person may see (#2055): every one for an admin, a member only themselves. Loaded once per
   * connection and per change, and read by every view, not one people/list each. Null until it answers.
   */
  readonly people = signal<PeopleList | null>(null);

  /** Why `people` could not be loaded: the failure itself, for each view to word. */
  readonly peopleFailure = signal<unknown>(null);

  /** When `people` was last read (#5146), for Settings ▸ People's "Last update" line. */
  readonly peopleAt = signal<number | undefined>(undefined);

  /** Each org provider's name by its id (#1002, FR-028), for People's "Managed by Okta": read once, when a person or group has one. */
  readonly orgProviderNames = signal<Record<string, string>>({});

  orgNamesRead = false;

  /** The bots stopped at a cap (#1761, control/capReached), for an admin: one per bot, each only while true (#2073). */
  readonly capped = signal<CapReached[]>([]);

  /** The last of them, for Console ▸ Requests. */
  readonly capReached = computed(() => this.capped.value.at(-1) ?? null);

  capExpiry: ReturnType<typeof setTimeout> | null = null;

  /** Counts each control/userSettingsChanged (#1760): Settings ▸ You ▸ Secrets loads again when it moves. */
  readonly userScopeChanges = signal(0);

  /** Status ▸ Secrets and Status ▸ Accounts (#4161): the person's secret rows and accounts, read when the Status section
   * opens and again on each control/userSettingsChanged. Null until read. */
  readonly userScopeStatus = signal<{ secrets: UserSecretRow[]; accounts: OutsideAccount[] } | null>(null);

  /**
   * The organisation's policy in force (#998): from policy/mine when Settings ▸ Policy loads it, and from each
   * control/policyChanged and control/stopAll. Null until either; a view with no policy when none is set.
   */
  readonly orgPolicy = signal<PolicyView | null>(null);

  /** Each host's policy as it follows it (daemon/policyState, #998): the red strip and the composer's reason. */
  readonly policyStates = signal<Record<string, PolicyState>>({});

  /** Each host's person's pass-through names, marked where the policy refuses one (settings/passThrough, #998). */
  readonly passThrough = signal<Record<string, PassThroughName[]>>({});

  /** Counts each control/orgRoutesChanged (#999): Console ▸ Model Access and Settings ▸ Policy load the routes again. */
  readonly orgRoutesChanges = signal(0);

  /** Counts each policy/effectiveChanged (#2957): Agents ▸ Policy loads the layers again. */
  readonly policyChanges = signal(0);

  /** The last machine of the person's removed with secrets on it (#1760, control/secretsLeft), until read. */
  readonly secretsLeft = signal<SecretsLeft | null>(null);

  /** The mode last chosen for each runtime, by host (029). */
  readonly rememberedModes = signal<Record<string, Record<string, JSONValue>>>({});

  /**
   * What didn't work, in one sentence, shown until its own OK closes it. Another arriving
   * meanwhile waits its turn rather than replacing it, as the window's alerts do (#101).
   */
  readonly problem = signal<string | null>(null);

  /** Words for a prompt bar, by its draft key, from elsewhere in the chat: an edit that came too late (#1552). */
  readonly offeredPrompt = signal<{ draftKey: string; text: string } | null>(null);

  /** Words quoted from a reply for a prompt bar, by its draft key (#1553): added after what is typed. */
  readonly offeredQuote = signal<{ draftKey: string; words: string } | null>(null);

  /** The Export… or Import Agents… on its way, as a busy sheet with Cancel (#2437). */
  readonly exportImport = signal<ExportImportBusy | null>(null);

  /** The last Archive, while Undo is offered for it (ArchiveUndo, #1534). */
  readonly archiveUndo = signal<{ key: number; host: string; agentIDs: string[]; line: string } | null>(null);

  /** The last Unarchive, Rename, label change, Mute or Later, while Undo is offered for it (SessionUndo, #4793).
   *  One toast at a time: it and Archive's replace each other. */
  readonly changeUndo = signal<{ key: number; host: string; line: string; menu: string; inverse: Inverse } | null>(null);

  problemsWaiting: string[] = [];

  filesSettling = new Map<string, { folders: Set<string>; many: boolean; timer: ReturnType<typeof setTimeout> }>();

  pageSettle = new Map<string, ReturnType<typeof setTimeout>>();

  display = new DisplayBuilder();

  entryIDs = new Set<string>();

  /**
   * The prompt of the turn the held entries start in, when it is not among them: a long turn
   * trimmed at the front, or opened from its end. Drawn above them, so the turn keeps its prompt
   * whatever is trimmed (#3249).
   */
  leadAsk: TranscriptEntry | null = null;

  /** What was heard while a page is on its way, to lay over it; null when none is (#214). */
  heardSincePage: TranscriptEntry[] | null = [];

  /**
   * How many entries the open chat's host had when it last gave a page of it (#4794): every entry
   * from here on was written after, so a reconnect asks `from` here. Null when no page is held.
   */
  transcriptEnd: number | null = null;

  /** Each host's point in its order of changes, as its last catch-up said (#4794). */
  readonly listPoints = new Map<string, ListRevision>();

  /** A prompt was sent and its echo is not heard yet: the next entry marks `agents:echo` (#4784). */
  echoAwaited = false;

  /**
   * The approvals answered here whose answer is on its way (#4814), by host, folder and id: out of
   * their folder's list until the call is back, and `gone` once the host's list no longer has one.
   */
  answeringApprovals = new Map<string, { approval: Approval; gone: boolean }>();

  static approvalSlot(host: string, folder: string, id: string): string {
    return `${host}|${folderKey(folder)}|${id}`;
  }

  /** Each folder's agents by `host|folder`, kept as each change lands: one change redraws one folder (#170). */
  slices = new Map<string, Signal<Agent[]>>();

  /** The changes drawn on agents before their hosts answer (#4786): one layer for every action. */
  readonly pending = new PendingWrites();

  views = new Map<string, ReadonlySignal<FolderView>>();

  byID = new Map<string, ReadonlySignal<Agent | undefined>>();

  nextSend = 0;

  /** Asks for the open chat's end, counted so two in a row both land: its sidebar row clicked again (#1349). */
  readonly toEndAsks = signal(0);

  /**
   * Whether anything of the conversation comes before what is in hand, and the chat will still
   * take it. At the history cap it waits until the reader is back at the end (#291).
   */
  get hasMoreOfTheConversation(): boolean {
    return this.moreOfTheConversation.value;
  }

  /** Computed, so a view that reads it redraws when the answer changes, not on every entry (#946). */
  readonly moreOfTheConversation = computed(() => {
    if (this.hasMoreBefore.value) return this.entries.value.length < historyEntriesCap;
    return this.firstTurn.value > 0 && this.turns.value.length < historyTurnsCap;
  });

  /**
   * Since when each host has not been online, as this page first heard it (#83; the window's
   * macDownSince). Kept while it stays down, dropped once it is back.
   */
  readonly downSince = signal<Record<string, number>>({});

  /** Git asks answered on this page, until the control plane's list drops them (#1122). */
  readonly gitAsksAnswered = signal<ReadonlySet<string>>(new Set());

  /** A host's git asking to use a Mac's git access (#1122), not answered here yet. */
  get gitLendAsk(): GitLendAsk | null { return firstAsk(this.hosts.value, this.gitAsksAnswered.value); }

  /** The hosts whose `machines/start` is out now, so the strip's Start waits for it (#691). */
  readonly hostsBeingStarted = signal<readonly string[]>([]);

  /** The machines New Machine is making (#3974), by name; "" while the control plane has not named it yet. */
  readonly machinesMaking = signal<readonly string[]>([]);

  /** How each click on a machine that never joined goes (#4978), by `provider/workspace`. */
  readonly machineJoins = signal<Readonly<Record<string, MachineJoin>>>({});

  /** The New Machine sheet (#4634), or null while it is shut: on a provider (the default one when none), or opened
   * again on the choices of a make the provider refused, with its reason. */
  readonly newMachineAsk = signal<NewMachineAsk | null>(null);

  /** Prompts and starts the control plane keeps for a stopped workspace (#691 US3), every host's. */
  readonly kept = signal<readonly KeptRequest[]>([]);

  /** The last kept request to reach its host, so a page showing a kept start opens the agent it made. */
  readonly keptDelivered = signal<KeptDelivered | null>(null);
}

export interface Work extends W0, W1, W2, W3, W4 {}
type W0 = typeof chatStateMethods;
type W1 = typeof reducerMethods;
type W2 = typeof agentListsMethods;
type W3 = typeof transcriptMethods;
type W4 = typeof hostRowsMethods;

mixin(Work, chatStateMethods, reducerMethods, agentListsMethods, transcriptMethods, hostRowsMethods);
