// What the page holds and what each notification means: AgentsModel (Client/AgentsModel.swift),
// ported by hand for the notifications the web remote hears and held to Fixtures/web/reducer
// (research R7). Nothing here decides anything; the hosts do.
import { preferencesSaid, sendPreferencesWith } from "./preferences";
import { folderPath as hostedFolderPath } from "./hostedMCP";
import type { ExportImportBusy } from "./exports";
import { batch, computed, signal, type ReadonlySignal, type Signal } from "@preact/signals";
import type {
  Agent, AgentRemovedNotification, ResumingNotification, ControlMachine, MachineRef, MachineWorkspace, ElicitationNotification, ElicitationRequest, EntryNotification,
  PermissionNotification, PermissionRequest, FolderSummary, TranscriptEntry, TranscriptPage, TurnsPage, TurnSummary,
  WorkflowSummary, Attachment, FilesChangedNotification, ShowFileNotification, WorkflowRemovedNotification, FolderRemovedNotification, DraftOptionsNotification, JSONValue, Methods, AccountProfile, RuntimeAccount, RuntimeStatus,
  StartRequest, UUID, AutoMappings, AutoPreview, AutoPreviewRequest, AutoSettings, ClientPermissionMode, Levels, ModelLevel, PermissionLevel, WorktreesListResponse, Persona, FileStamp, WriteFailure, CloneNotification, CloneSummary, DirectoryListing, LeaseSnapshot, HostedMCPSnapshot, MCPHealthSnapshot, DiskState, StoreNotes,
  CostState, EventsPage, Event as ActivityEvent, ConfigOption, WorkflowSettings,
  PagesChangedNotification, PinsChangedNotification, PinView, ViewPin, ListCursor, ListRequest, FileMentionDTO, SandboxChoice, PolicySetBy, RuntimeAllowances,
  GuardedChange, GuardedChangeReading, MachineJoinStatus, RequiredCapabilities, KeptDelivered, KeptList, KeptRequest, Approval, ApprovalAction, UsageHistory, TimeHistory, Milestones,
  BuildOutputRemoved, FolderWorktrees, RemovalCheck, WorktreeSize, WorktreeSummary, WorktreesSized, FindResult,
  BackupRestoreResult, BackupSettings, BackupState, CapReached, ChannelLinkDecided, ChannelLinkRequest, ControlPerson, JoinDecided, JoinRequest, PeopleList, PersonRow, SecretsLeft, SignInDecided,
  PolicyView, PolicyState, PassThroughName, SignInRequest, CatalogRequest, RemoveRequest, ClientPermissionSettings, PRCostComment } from "../protocol/generated";
import { Failure } from "../protocol/generated";
import { CallFailed, type Link } from "../wire/link";
import type { FolderGoneAsk } from "./missingFolder";
import { describe, methodNotFound } from "./errors";
import { fromWireDate } from "../protocol/dates";
import { addCap, dropCap, openCaps } from "./teamGroups";
import { withGovernanceRequest } from "./governance";
import type { SaveOutcome } from "./sourceEdit";
import { artifactsIn, withArtifactsOf, type Artifact } from "./artifacts";
import { log } from "../log";
import { knowPublicViews } from "../place";
import { folderKey, folderPath as agentFolderPath, folderView, type FolderView } from "./groups";
import { decideMacHostNotice, type MacHostNotice } from "./macHostNotice";
import { DisplayBuilder, keepingTurns, storedTurn, turns, type ChatTurn, type Item } from "./turns";
import { sortedRuntimes } from "./runtimes";
import { personPrompts } from "./sessionPrompts";
import { shownItems } from "./thoughts";
import { blockLines, openBlock } from "./block";
import { Drafts } from "./drafts";
import { giveBackInto } from "./promptQuote";
import { scopeRoot, WatchCounts } from "./fileWatch";
import { workflowRunsOn } from "./workflows";
import type { WhenDone } from "./workflowSettings";
import { keyKind, takesKey, wantedRuntime } from "./credentials";
import { askID, firstAsk, waiting, type GitLendAsk } from "./gitLending";
import type { Method, Params, Result } from "../protocol/methods";
import { dropboxRefusal, dropboxRequest } from "./dropbox";
import { goOnRequest } from "./limits";
import { milestonesSeen } from "./milestones";
import { hostAnswers, hostHas } from "./capabilities";
import { Capability } from "../protocol/capabilities.generated";
import { providerManaged, withJoin, withoutJoin } from "./people";
import { orgNames } from "./signIn";
import { withRequest, withoutRequest } from "./channelLinks";
import { withSignIn, withoutSignIn } from "./signIn";
import type { ChartHint } from "./chart";
import { Providers } from "./providers";

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

/** How many archived sessions the Archived page lists: as many as it shows (#170). */
export const archivedPage = 50;
/** How many an open folder's Recently archived sessions lists (#2587): no more is asked (#2731). */
export const recentArchivedShown = 3;

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
export class Work {
  readonly hosts = signal<ControlMachine[]>([]);
  readonly folders = signal<ByHost<FolderSummary>>({});
  /** The accounts added to each host's runtimes (#840), by host. */
  readonly accountProfiles = signal<Record<string, AccountProfile[]>>({});
  /** The clones under way on each host (027), drawn where the folder will be. */
  readonly clones = signal<ByHost<CloneSummary>>({});
  readonly agents = signal<ByHost<Agent>>({});
  readonly permissions = signal<ByHost<PermissionRequest>>({});
  readonly elicitations = signal<ByHost<ElicitationRequest>>({});

  /** The conversation being read, and only that one. */
  readonly watching = signal<{ host: string; session: string } | null>(null);
  /** The conversation last looked for: once it is, one not in hand has gone (#2652), as PoppedChat.looked. */
  readonly lookedFor = signal<{ host: string; session: string } | null>(null);
  readonly entries = signal<TranscriptEntry[]>([]);
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
  private heardTurns: ChatTurn[] = [];

  /**
   * Whether the chat is following the end, as the chat says. The page is trimmed at the front
   * only while it is: rows somebody scrolled up to read are never taken from under them.
   */
  isFollowingEnd = true;
  private nextTrimAt = entriesTrimmedAt;
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
  protected transcriptLoads = 0;

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

  /** Hold how to draw a CSV as a chart (#836); the same hint again changes nothing. */
  noteChartHint(host: string, path: string, hint: ChartHint | undefined): void {
    if (!hint) return;
    const key = `${host}|${path}`;
    const held = this.chartHints.peek()[key];
    if (held && JSON.stringify(held) === JSON.stringify(hint)) return;
    this.chartHints.value = { ...this.chartHints.peek(), [key]: hint };
  }

  chartHint(host: string, path: string): ChartHint | undefined {
    return this.chartHints.value[`${host}|${path}`];
  }

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
  /** Bumped by pages/changed: a page shown may have changed on disk; read it again. */
  readonly pageRevisions = signal<Record<string, number>>({});

  /** Each folder's workflows by `host|folder`, listed while that folder is open. */
  readonly workflows = signal<Record<string, WorkflowSummary[]>>({});
  /** One folder's list, so a change redraws that fold and no other (#291). */
  private workflowSlices = new Map<string, Signal<WorkflowSummary[]>>();
  /** Folders whose workflow list is on screen, and how many views hold it. */
  protected workflowHolds = new Map<string, number>();
  /** Lists a fetch has answered, so a page can tell "loading" from "gone". */
  protected workflowsLoaded = new Set<string>();

  /** One folder's workflows: a reader redraws only when this folder's list changes. */
  folderWorkflows(host: string, folder: string): WorkflowSummary[] {
    const key = `${host}|${folderKey(folder)}`;
    let slice = this.workflowSlices.get(key);
    if (!slice) {
      slice = signal(this.workflows.peek()[key] ?? []);
      this.workflowSlices.set(key, slice);
    }
    return slice.value;
  }

  /** User-scope workflows from this host, with their source Markdown for Settings. */
  userWorkflows(host: string): WorkflowSummary[] {
    return Object.entries(this.workflows.value)
      .filter(([key]) => key.startsWith(`${host}|`))
      .flatMap(([, workflows]) => workflows)
      .filter((summary) => summary.scope === "user" && summary.content !== undefined);
  }

  /** Whether `loadWorkflows` has answered for this folder since it was opened. */
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
    // A folder not on screen keeps no list: the next open asks for the whole of it (#291).
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
    if (workflowRunsOn(summary.workflow.runsOn, this.hostMachineID(host))) this.upsertWorkflow(summary, host);
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
  /** The MCP servers each host runs for every agent (#488), replaced whole by `mcp/hostedChanged`. */
  readonly hostedMCP = signal<Record<string, HostedMCPSnapshot>>({});
  /** Every MCP server each host's mcp.json files name, and how each is doing (#753), replaced whole
   * by `mcp/healthChanged`. */
  readonly mcpHealth = signal<Record<string, MCPHealthSnapshot>>({});
  /** Each host's chats it is bringing back by itself after a restart: Coming back (#251). */
  readonly resuming = signal<Record<string, readonly string[]>>({});
  /** Each host's volumes low on space (#196), replaced whole by each disk/changed, never merged. */
  readonly disk = signal<Record<string, DiskState>>({});
  /** The person's Mac's backups (#1810), for Settings ▸ Backups: null until it has said, or from a
   * host too old to keep backups, which leaves the section out. */
  readonly backups = signal<BackupState | null>(null);
  /** Each host's folders' worktrees (#790), as `worktrees/all` last answered: asked when Activity ▸
   * Worktrees is shown, not kept up by the host. */
  readonly worktreeLists = signal<Record<string, FolderWorktrees[]>>({});
  /** Each worktree's size as `worktrees/sized` said since the list, by host and root: newer than it. */
  readonly worktreeSizes = signal<Record<string, Record<string, WorktreeSize>>>({});
  /** Each host's files it could not read in this run (#205, #223), replaced whole by each store/notesChanged. */
  readonly storeNotes = signal<Record<string, string[]>>({});
  /** Each host's milestones (#984), replaced whole by each milestones/changed. */
  readonly milestones = signal<Record<string, Milestones>>({});

  protected takeMilestones(host: string, milestones: Milestones): void {
    this.milestones.value = { ...this.milestones.value, [host]: milestones };
    milestonesSeen.take(milestones);
  }
  /**
   * The control plane's machine, its home host, and how this Mac's host says its join stands
   * (#666), from `control/status`.
   */
  readonly plane = signal<{ machineID: string; homeHost?: string | undefined; thisMacHost?: MachineJoinStatus | undefined;
    name?: string; version?: string; required?: RequiredCapabilities | undefined } | null>(null);
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
    return listed && listed.relay === undefined && listed.platform.startsWith("macOS") ? listed.id : "mac";
  });
  /** Whether `host` is the person's Mac (#1501). */
  isMac(host: string | undefined): boolean {
    return host !== undefined && host === this.macHostID.value;
  }
  /** Why this Mac's host is quiet, as the window says it (#666), or nil while it is online. */
  readonly macHostNotice: ReadonlySignal<MacHostNotice | null> = computed(() => {
    const plane = this.plane.value;
    const macID = this.macHostID.value;
    const mac = this.hosts.value.find((h) => h.id === macID);
    const onThisMac = !!plane?.machineID && plane.machineID === mac?.machineID;
    return decideMacHostNotice(onThisMac, mac?.state, plane?.thisMacHost);
  });
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
  /** Counts each control/peopleChanged (#994): Settings ▸ People loads its list again when it moves. */
  readonly peopleChanges = signal(0);
  /**
   * The people this person may see (#2055): every one for an admin, a member only themselves. Loaded once per
   * connection and per change, and read by every view, not one people/list each. Null until it answers.
   */
  readonly people = signal<PeopleList | null>(null);
  /** Why `people` could not be loaded: the failure itself, for each view to word. */
  readonly peopleFailure = signal<unknown>(null);
  /** Each org provider's name by its id (#1002, FR-028), for People's "Managed by Okta": read once, when a person or group has one. */
  readonly orgProviderNames = signal<Record<string, string>>({});
  protected orgNamesRead = false;
  /** The bots stopped at a cap (#1761, control/capReached), for an admin: one per bot, each only while true (#2073). */
  readonly capped = signal<CapReached[]>([]);
  /** The last of them, for Console ▸ Requests. */
  readonly capReached = computed(() => this.capped.value.at(-1) ?? null);
  protected capExpiry: ReturnType<typeof setTimeout> | null = null;
  /** OK on a cap notice (#2198): the cap stays as it is, and the notice goes. */
  dismissCap(reached: CapReached) {
    this.capped.value = dropCap(reached, this.capped.value);
  }
  /** Counts each control/userSettingsChanged (#1760): Machines ▸ Secrets and the parts load again when it moves. */
  readonly userScopeChanges = signal(0);
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
      case "daemon/policyStateChanged":
        this.policyStates.value = { ...this.policyStates.value, [host]: params as PolicyState };
        return true;
      case "runtimes/accountProfilesChanged":
        this.accountProfiles.value = { ...this.accountProfiles.value, [host]: params as AccountProfile[] };
        return true;
      case "folder/removed":
        // Deleted (#677); its sessions went before it, each by its own agent/removed.
        this.removeFolder((params as FolderRemovedNotification).folder, host);
        return true;
      case "folder/changed":
        this.upsertFolder(params as FolderSummary, host);
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
        let list = (this.permissions.value[host] ?? []).filter((p) =>
          !(p.agentID === note.agentID && p.id === note.requestID));
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
        this.workflowPins.value = { ...this.workflowPins.value, [`${host}|${folderKey(note.folder)}`]: note.workflows ?? [] };
        this.serverViews.value = { ...this.serverViews.value, [`${host}|${folderKey(note.folder)}`]: note.views ?? [] };
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
        this.noteChartHint(host, note.file.path, note.file.chart);
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
      case "resources/changed":
        this.leases.value = { ...this.leases.value, [host]: params as LeaseSnapshot };
        return true;
      case "mcp/hostedChanged":
        this.hostedMCP.value = { ...this.hostedMCP.value, [host]: params as HostedMCPSnapshot };
        return true;
      case "mcp/healthChanged":
        this.mcpHealth.value = { ...this.mcpHealth.value, [host]: params as MCPHealthSnapshot };
        return true;
      case "disk/changed":
        this.disk.value = { ...this.disk.value, [host]: params as DiskState };
        return true;
      case "backups/changed":
        if (this.isMac(host)) this.backups.value = params as BackupState;
        return true;
      case "worktrees/sized": {
        const held = { ...(this.worktreeSizes.value[host] ?? {}) };
        for (const note of (params as WorktreesSized).sizes) held[note.root] = note.size;
        this.worktreeSizes.value = { ...this.worktreeSizes.value, [host]: held };
        return true;
      }
      case "store/notesChanged":
        this.storeNotes.value = { ...this.storeNotes.value, [host]: (params as StoreNotes).notes };
        return true;
      case "milestones/changed":
        this.takeMilestones(host, params as Milestones);
        return true;
      case "preferences/changed":
        if (this.isMac(host)) preferencesSaid(params as Record<string, JSONValue>);
        return true;
      case "modes/changed":
        this.rememberedModes.value = { ...this.rememberedModes.value, [host]: params as Record<string, JSONValue> };
        return true;
      case "agent/removed": {
        const { agentID } = params as AgentRemovedNotification;
        const held = this.agents.value[host] ?? [];
        const gone = held.find((a) => a.id === agentID);
        batch(() => {
          if (gone) this.setAgents(host, held.filter((a) => a !== gone), [agentFolderPath(gone)]);
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

  removeFolder(folder: string, host: string): void {
    const list = (this.folders.value[host] ?? []).filter((p) => folderKey(p.folder.folder) !== folderKey(folder));
    this.folders.value = { ...this.folders.value, [host]: list };
  }

  upsertFolder(summary: FolderSummary, host: string): void {
    const list = (this.folders.value[host] ?? [])
      .filter((p) => folderKey(p.folder.folder) !== folderKey(summary.folder.folder));
    this.folders.value = { ...this.folders.value, [host]: [...list, summary] };
  }

  /**
   * One agent as it is now, put where its activity sorts it. Only its folder's list, and the
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
    this.setAgents(host, list, was ? [agentFolderPath(was), agentFolderPath(agent)] : [agentFolderPath(agent)]);
  }

  /** One host's agents as it just listed them; every other host's are left alone. */
  replaceAgents(listed: Agent[], host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    this.setAgents(host, newestFirst(listed.map((a) => keepingLists(a, held.get(a.id)))));
  }

  /** Archived agents of one folder, listed when the fold opens, added beside the live ones. */
  addAgents(listed: Agent[], host: string): void {
    const held = new Map((this.agents.value[host] ?? []).map((a) => [a.id, a]));
    const incoming = new Set(listed.map((l) => l.id));
    const kept = [...held.values()].filter((a) => !incoming.has(a.id));
    this.setAgents(host, newestFirst([...kept, ...listed.map((a) => keepingLists(a, held.get(a.id)))]),
      listed.map(agentFolderPath));
  }

  /**
   * One folder's archived agents let go, when its Archived fold closes: the page holds the live
   * agents and a page of archived ones per open fold, no more (#170). The open session stays.
   */
  dropArchived(host: string, folder: string): void {
    const key = folderKey(folder);
    const watching = this.watching.value;
    const held = this.agents.value[host] ?? [];
    const kept = held.filter((a) => a.state !== "archived" || agentFolderPath(a) !== key
      || (watching?.host === host && watching.session === a.id));
    if (kept.length !== held.length) this.setAgents(host, kept, [key]);
  }

  /** Each folder's agents by `host|folder`, kept as each change lands: one change redraws one folder (#170). */
  private slices = new Map<string, Signal<Agent[]>>();
  private views = new Map<string, ReadonlySignal<FolderView>>();
  private byID = new Map<string, ReadonlySignal<Agent | undefined>>();

  /**
   * Every write to a host's agents. `touched` names the folders that changed; without it every
   * folder of the host is worked out again, and only those whose agents differ are told.
   */
  protected setAgents(host: string, list: Agent[], touched?: readonly string[]): void {
    const prefix = `${host}|`;
    batch(() => {
      this.agents.value = { ...this.agents.value, [host]: list };
      if (touched) {
        for (const folder of new Set(touched)) {
          const slice = this.slices.get(prefix + folder);
          if (slice) slice.value = list.filter((a) => agentFolderPath(a) === folder);
        }
        return;
      }
      const grouped = new Map<string, Agent[]>();
      for (const agent of list) {
        const folder = agentFolderPath(agent);
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
      slice = signal((this.agents.peek()[host] ?? []).filter((a) => agentFolderPath(a) === folder));
      this.slices.set(name, slice);
    }
    return slice;
  }

  /** One folder's agents, newest first: what reads them is redrawn only when they change. */
  folderAgents(host: string, folder: string): Agent[] {
    return this.slice(host, folderKey(folder)).value;
  }

  /** One folder's headings, archived sessions, subtitle and counts, worked out once per change to it. */
  folderView(host: string, folder: string): FolderView {
    const key = folderKey(folder);
    const name = `${host}|${key}`;
    let view = this.views.get(name);
    if (!view) {
      const slice = this.slice(host, key);
      view = computed(() => folderView(slice.value, key));
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
      this.artifacts.value = withArtifactsOf(this.artifacts.value, note.entry);
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
      const artifacts = this.artifacts.value;
      if (artifacts.some((artifact) => !this.entryIDs.has(artifact.entryID))) {
        this.artifacts.value = artifacts.filter((artifact) => this.entryIDs.has(artifact.entryID));
      }
    }
    this.entries.value = entries;
    this.nextTrimAt = Math.max(entriesTrimmedAt, entries.length + entriesTrimmedAt - entriesKept);
  }

  /** Asks for the open chat's end, counted so two in a row both land: its sidebar row clicked again (#1349). */
  readonly toEndAsks = signal(0);

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
      if (this.firstPrompt.value !== null) this.firstPrompt.value += personPrompts(held.slice(0, cut));
      this.turns.value = held.slice(cut);
      this.firstTurn.value += cut;
    });
  }

  /** The finished turns at the end of the conversation, and where the one in progress starts. */
  replaceTurns(page: TurnsPage): void {
    batch(() => {
      this.turns.value = keepingLatestByID(page.turns);
      this.firstTurn.value = page.firstTurn;
      this.firstPrompt.value = page.firstPrompt ?? null;
      this.openTurnStart.value = page.openStart;
    });
  }

  /** Earlier finished turns, put in front. Past the cap, they wait until the reader is back at the end (#291). */
  prependTurns(page: TurnsPage): void {
    if (this.turns.value.length >= historyTurnsCap) return;
    batch(() => {
      this.turns.value = keepingLatestByID([...page.turns, ...this.turns.value]);
      this.firstTurn.value = page.firstTurn;
      this.firstPrompt.value = page.firstPrompt ?? null;
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
    this.firstPrompt.value = null;
    this.openTurnStart.value = 0;
    this.refold([]);
  }

  private refold(entries: TranscriptEntry[]): void {
    this.entryIDs = new Set(entries.map((e) => e.id));
    this.display = new DisplayBuilder();
    for (const entry of entries) this.display.add(entry);
    this.entries.value = entries;
    this.items.value = this.display.items;
    this.artifacts.value = artifactsIn(entries);
    this.nextTrimAt = entriesTrimmedAt;
  }

  /**
   * Whether anything of the conversation comes before what is in hand, and the chat will still
   * take it. At the history cap it waits until the reader is back at the end (#291).
   */
  get hasMoreOfTheConversation(): boolean {
    return this.moreOfTheConversation.value;
  }

  /** Computed, so a view that reads it redraws when the answer changes, not on every entry (#946). */
  private readonly moreOfTheConversation = computed(() => {
    if (this.hasMoreBefore.value) return this.entries.value.length < historyEntriesCap;
    return this.firstTurn.value > 0 && this.turns.value.length < historyTurnsCap;
  });

  /**
   * Since when each host has not been online, as this page first heard it (#83; the window's
   * macDownSince). Kept while it stays down, dropped once it is back.
   */
  readonly downSince = signal<Record<string, number>>({});

  /** Whether a host can do what `capability` names (#1748): true when it said no list. */
  has(host: string, capability: string): boolean {
    return hostHas(this.hosts.value, host, capability);
  }

  /** The hosts as listed, with when each one went down noted. */
  takeHosts(hosts: ControlMachine[], now = Date.now()): void {
    const since: Record<string, number> = {};
    for (const host of hosts) if (!hostAnswers(host.state)) since[host.id] = this.downSince.value[host.id] ?? now;
    const still = waiting(hosts);
    batch(() => {
      this.hosts.value = hosts;
      this.downSince.value = since;
      this.gitAsksAnswered.value = new Set([...this.gitAsksAnswered.value].filter((id) => still.has(id)));
    });
  }

  /** Git asks answered on this page, until the control plane's list drops them (#1122). */
  readonly gitAsksAnswered = signal<ReadonlySet<string>>(new Set());

  /** A host's git asking to use a Mac's git access (#1122), not answered here yet. */
  get gitLendAsk(): GitLendAsk | null { return firstAsk(this.hosts.value, this.gitAsksAnswered.value); }

  /** The hosts whose `hosts/start` is out now, so the strip's Start waits for it (#691). */
  readonly hostsBeingStarted = signal<readonly string[]>([]);

  /** Prompts and starts the control plane keeps for a stopped workspace (#691 US3), every host's. */
  readonly kept = signal<readonly KeptRequest[]>([]);
  /** The last kept request to reach its host, so a page showing a kept start opens the agent it made. */
  readonly keptDelivered = signal<KeptDelivered | null>(null);

  /**
   * Whether a prompt or a start sent to `host` now is kept rather than refused: it is linked to a
   * workspace that is stopped or starting, and starts when used (FR-020).
   */
  startsWhenUsed(host: string): boolean {
    const row = this.hosts.value.find((h) => h.id === host);
    return !!row?.workspace?.startWhenUsed && (row.state === "stopped" || row.state === "starting");
  }

  /** The prompts kept for one agent, oldest first. */
  keptFor(host: string, agentID: string): KeptRequest[] {
    return this.kept.value.filter((k) => k.host === host && k.kind === "prompt" && k.agentID === agentID);
  }

  /** The agent starts kept for one folder. */
  keptStarts(host: string, folder: string): KeptRequest[] {
    return this.kept.value.filter((k) => k.host === host && k.kind === "start" && !!k.folder && folderKey(k.folder) === folderKey(folder));
  }

  /** A kept request, said by the control plane as it answered: shown at once, before `control/keptChanged`. */
  protected noteKept(error: CallFailed): KeptRequest | null {
    const said = error.data as KeptRequest | undefined;
    if (!said || typeof said.id !== "string") return null;
    if (!this.kept.value.some((k) => k.id === said.id)) this.kept.value = [...this.kept.value, said];
    return said;
  }


  /** One host's row, or its state and workspace, as said now, in place of what was listed. */
  protected takeHostRow(change: { id: string; state: string; workspace?: MachineWorkspace | undefined }): void {
    const hosts = this.hosts.value;
    const at = hosts.findIndex((h) => h.id === change.id);
    if (at < 0) return;
    const row: ControlMachine = { ...hosts[at]!, state: change.state };
    if (change.workspace) row.workspace = change.workspace;
    else delete row.workspace;
    this.takeHosts(hosts.map((h, i) => (i === at ? row : h)));
  }

  /** Whether a host answers: online, or held back for a reason the page says. */
  hostIsOnline(host: string): boolean {
    return hostAnswers(this.hosts.value.find((h) => h.id === host)?.state);
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
export type AgentAct = "agents/stop" | "agents/archive" | "agents/unarchive"
  | { sendNow: string };

/** What the pending mark says it is doing, before "telling your Mac" (AgentAct.doing). */
export function actDoing(act: AgentAct): string {
  if (typeof act !== "string") return "Sending";
  return { "agents/stop": "Stopping", "agents/archive": "Archiving", "agents/unarchive": "Unarchiving" }[act];
}

/** Telling.words: "Archiving — telling your Mac", or "telling your Mac" beside a button that says what. */
export function tellingWords(doing: string | null, recipient: string): string {
  return doing ? `${doing} — telling ${recipient}` : `telling ${recipient}`;
}

/** The reducer, fed by the link: everything loaded on each connection, then kept by notifications. */
/** Said when an edit came too late (#1552), as QueuedPrompt.sentBeforeEdit says it. */
export const sentBeforeEdit = "That prompt was sent before your change. Your words are in the prompt bar.";

export class Store extends Work {
  /** The control plane's workspace providers (#1808), for Settings ▸ Control plane. */
  readonly providers: Providers;

  async loadUserWorkflows(host: string): Promise<void> {
    const listed = await this.link.call("workflows/list", { scope: "user" }, host).catch(() => null);
    if (!listed) return;
    const byFolder = new Map<string, WorkflowSummary[]>();
    for (const workflow of listed) {
      const key = folderKey(workflow.workflow.folder);
      byFolder.set(key, [...(byFolder.get(key) ?? []), workflow]);
    }
    for (const [folder, workflows] of byFolder) {
      const key = `${host}|${folder}`;
      this.workflowsLoaded.add(key);
      this.writeWorkflows(key, workflows);
    }
  }

  async writeUserWorkflow(host: string, workflowID: string, content: string): Promise<string | null> {
    try {
      const updated = await this.link.call("workflows/write", { workflowID, content }, host);
      this.upsertWorkflow(updated, host);
      return null;
    } catch (error) {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      return describe(error);
    }
  }

  async agentConfigEditorFiles(host: string, folder: string | undefined, kind: "skills" | "personas" | "workflows") {
    return this.link.call("agentConfig/editorFiles", { folder: folder as never, kind }, host).catch(() => null);
  }

  async saveAgentConfigEditorFile(host: string, folder: string | undefined,
    kind: "skills" | "personas" | "workflows", path: string, content: string, remove: boolean): Promise<string | null> {
    try {
      await this.link.call("agentConfig/editorSave", { folder: folder as never, kind, path, content, delete: remove }, host);
      if (kind === "workflows" && folder === undefined) await this.loadUserWorkflows(host);
      if (kind === "workflows" && folder !== undefined) await this.loadWorkflows(host, folder);
      return null;
    } catch (error) { return describe(error); }
  }

  constructor(readonly link: Link) {
    super();
    // The person's display choices are kept on their Mac (#1033).
    sendPreferencesWith((changes) => {
      void this.link.call("preferences/set", changes as Record<string, JSONValue>, this.macHostID.peek())
        .then((said) => preferencesSaid(said)).catch(() => undefined);
    });
    this.providers = new Providers(link);
    link.onNotification((method, params, host) => {
      if (method === "control/providersChanged") {
        this.providers.take(params);
        return;
      }
      if (method === "control/hostChanged") {
        this.hostChanged(params);
        return;
      }
      if (method === "control/keptChanged") {
        this.kept.value = (params as KeptList | null)?.kept ?? [];
        return;
      }
      if (method === "control/keptDelivered") {
        this.keptDelivered.value = params as KeptDelivered;
        return;
      }
      if (method === "control/joinRequested") {
        const request = params as JoinRequest | null;
        if (request?.request) this.joinRequests.value = withJoin(this.joinRequests.value, request);
        return;
      }
      if (method === "control/joinDecided") {
        const decided = params as JoinDecided | null;
        if (decided?.request) this.joinRequests.value = withoutJoin(this.joinRequests.value, decided.request);
        return;
      }
      if (method === "control/linkRequested") {
        const request = params as ChannelLinkRequest | null;
        if (request?.request) this.linkRequests.value = withRequest(this.linkRequests.value, request);
        // One that names nobody is an admin's to send on: whom to, if not loaded yet.
        if (request && !request.for && this.linkPeople.value.length === 0) void this.loadLinkRequests();
        return;
      }
      if (method === "control/governanceRequested") {
        const request = params as CatalogRequest | null;
        if (request?.id && this.people.value?.admin) this.governanceRequests.value = withGovernanceRequest(this.governanceRequests.value, request);
        this.governanceChanges.value += 1;
        return;
      }
      if (method === "control/linkDecided") {
        const decided = params as ChannelLinkDecided | null;
        if (decided?.request) this.linkRequests.value = withoutRequest(this.linkRequests.value, decided.request);
        return;
      }
      if (method === "control/signInRequested") {
        const request = params as SignInRequest | null;
        if (request?.request) this.signInRequests.value = withSignIn(this.signInRequests.value, request);
        return;
      }
      if (method === "control/signInDecided") {
        const decided = params as SignInDecided | null;
        if (decided?.request) this.signInRequests.value = withoutSignIn(this.signInRequests.value, decided.request);
        return;
      }
      if (method === "control/linksChanged") {
        this.linksChanges.value += 1;
        return;
      }
      if (method === "control/peopleChanged") {
        void this.loadPeople().then(() => Promise.all([this.loadLinkRequests(), this.loadRemoveRequests()]))
          .then(() => { this.peopleChanges.value += 1; });
        return;
      }
      if (method === "control/capReached") {
        const reached = params as CapReached | null;
        if (reached?.user) this.capped.value = addCap(reached, this.capped.value);
        // Only the bot's spend today changed.
        void this.loadPeople();
        return;
      }
      if (method === "control/projectsChanged") {
        this.projectsChanges.value += 1;
        return;
      }
      if (method === "control/groupsChanged") {
        // Settings ▸ Groups, and each provider's group's name (#1761).
        void this.providers.loadGroups().then(() => { this.keepCapsTrue(); this.peopleChanges.value += 1; });
        return;
      }
      if (method === "control/orgRoutesChanged") {
        this.orgRoutesChanges.value += 1;
        return;
      }
      if (method === "control/policyChanged" || method === "control/stopAll") {
        this.orgPolicy.value = (params as PolicyView | null) ?? {};
        return;
      }
      if (method === "control/userSettingsChanged") {
        this.userScopeChanges.value += 1;
        return;
      }
      if (method === "control/secretsLeft") {
        this.secretsLeft.value = (params as SecretsLeft | null) ?? null;
        this.userScopeChanges.value += 1;
        return;
      }
      if (method === "control/thisMacHostChanged") {
        const plane = this.plane.value;
        if (plane) this.plane.value = { ...plane, thisMacHost: (params as MachineJoinStatus | null) ?? undefined };
        return;
      }
      if (method === "auto/changed") {
        if (host) {
          this.autoSettings.value = { ...this.autoSettings.value, [host]: params as AutoSettings };
          void this.loadAuto(host);
        }
        return;
      }
      if (method === "clientPermissions/changed") {
        if (host === this.macHostID.peek()) {
          this.clientPermissions.value = { ...this.clientPermissions.value, [host]: params as ClientPermissionSettings };
        }
        return;
      }
      if (host) this.apply(method, params, host);
      if (host && method === "daemon/policyStateChanged") {
        // The marks on the lists change with the policy, and the page hears no change of them (#998).
        void this.loadRuntimes(host);
        void this.loadCost(host);
      }
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
   * then folders, then the cards and the open conversation at once. No cursors on the wire.
   * One at a time: asked again while running, it runs once more after.
   */
  load(): Promise<void> {
    return this.once("*", async () => {
      const [hosts] = await Promise.all([this.link.call("hosts/list", {}), this.loadPlane(), this.loadKept(), this.loadJoinRequests(),
        this.loadPeople().then(() => Promise.all([this.loadLinkRequests(), this.loadGovernanceRequests(), this.loadRemoveRequests()])),
        this.loadSignInRequests()]);
      this.takeHosts(hosts);
      await Promise.all(this.hosts.value.filter((host) => hostAnswers(host.state)).map((host) => this.onHost(host.id, async () => {
        // A removal that landed while this waited is not loaded back (#291).
        if (!this.hostIsOnline(host.id)) return;
        await this.loadHost(host.id);
      })));
      // One offline or stopped now lists what it last did, greyed, as the window keeps it (#962).
      await Promise.all(this.hosts.value.filter((host) => !hostAnswers(host.state) && host.relay === undefined)
        .map((host) => this.onHost(host.id, () => this.loadLastHeard(host.id))));
      const watching = this.watching.value;
      if (watching) await this.loadTranscript(watching.host, watching.session);
    });
  }

  /** What the control plane keeps for stopped workspaces; one without providers keeps nothing. */
  private async loadKept(): Promise<void> {
    const listed = await this.link.call("hosts/listKept", {}).catch(() => null);
    this.kept.value = listed?.kept ?? [];
  }

  /** The control plane's status, for this Mac's host notice; a plane that can't say leaves it as it was. */
  private async loadPlane(): Promise<void> {
    const status = await this.link.call("control/status", {}).catch(() => null);
    if (!status) return;
    this.plane.value = { machineID: status.machineID, homeHost: status.homeHost, thisMacHost: status.thisMacHost,
      name: status.name, version: status.version, required: status.required };
    this.person.value = status.person ?? null;
    this.joinCommand.value = status.joinCommand || null;
    knowPublicViews(status.publicViews);
  }

  /** Machines waiting to join (#994); a control plane before it has none to say. */
  private async loadJoinRequests(): Promise<void> {
    const listed = await this.link.call("hosts/joinRequests", {}).catch(() => null);
    this.joinRequests.value = listed ?? [];
  }

  /** GitHub sign-ins waiting (#995); a control plane before sign-in has none to say. */
  private async loadSignInRequests(): Promise<void> {
    const listed = await this.link.call("signIn/requests", {}).catch(() => null);
    this.signInRequests.value = listed ?? [];
  }

  /**
   * Approve or deny a GitHub sign-in on a new client (#995). The card goes at once; a refusal is
   * said, and the card stays.
   */
  async decideSignIn(request: string, approve: boolean, code?: string): Promise<void> {
    try {
      await this.link.call(approve ? "signIn/approve" : "signIn/deny", code === undefined ? { request } : { request, code });
      this.signInRequests.value = withoutSignIn(this.signInRequests.value, request);
    } catch (error) {
      this.say(describe(error));
    }
  }

  /**
   * The one people list (#2055), and the groups the first time: every view reads these. A control plane before
   * people has none.
   */
  async loadPeople(): Promise<void> {
    try {
      this.people.value = await this.link.call("people/list", {});
      this.peopleFailure.value = null;
    } catch (error) {
      this.peopleFailure.value = error;
      return;
    }
    if (this.providers.groups.value.length === 0) await this.providers.loadGroups();
    this.keepCapsTrue();
    await this.loadOrgNames();
  }

  /** The org providers' names (#1002), once, when a person or a group names one; an older control plane has none. */
  private async loadOrgNames(): Promise<void> {
    if (this.orgNamesRead) return;
    const named = (this.people.value?.people ?? []).some(providerManaged) || this.providers.groups.value.some((g) => g.source);
    if (!named) return;
    this.orgNamesRead = true;
    const providers = await this.link.call("signIn/providers", {}).catch(() => null);
    if (providers) this.orgProviderNames.value = orgNames(providers.orgProviders);
    else this.orgNamesRead = false;
  }

  /** Drops the cap notices no longer true (#2073), and wakes when the next one's day ends. */
  private keepCapsTrue(): void {
    const open = openCaps(this.capped.value, this.people.value?.people ?? null, this.providers.groups.value);
    if (open.length !== this.capped.value.length) this.capped.value = open;
    if (this.capExpiry) clearTimeout(this.capExpiry);
    this.capExpiry = null;
    if (open.length === 0) return;
    const next = Math.min(...open.map((n) => fromWireDate(n.until).getTime()));
    this.capExpiry = setTimeout(() => this.keepCapsTrue(), Math.max(1000, next - Date.now()));
  }

  /** An admin's requests for an MCP server or skill (#2019, M5); a control plane before them has none. */
  async loadGovernanceRequests(): Promise<void> {
    const admin = this.people.value?.admin ?? false;
    const listed = admin ? await this.link.call("governance/requests", {}).then((l) => l.requests, () => []) : [];
    // An admin's own decided ones come too, for Settings ▸ Policy: the Console has the waiting ones.
    this.governanceRequests.value = listed.filter((r) => r.state === "waiting");
  }

  /** An admin's SCIM removals waiting (#1002, #2436); a member, or a control plane before SCIM, has none. */
  async loadRemoveRequests(): Promise<void> {
    const admin = this.people.value?.admin ?? false;
    this.removeRequests.value = admin ? await this.link.call("people/removeRequests", {}).then((r) => r.requests, () => []) : [];
  }

  /** Link requests (#1762), and for an admin whom to send them on to; a control plane before links has none. */
  private async loadLinkRequests(): Promise<void> {
    const listed = await this.link.call("links/requests", {}).catch(() => null);
    this.linkRequests.value = listed ?? [];
    const people = this.people.value;
    this.linkPeople.value = people?.admin ? people.people.filter((p) => p.kind === "person") : [];
  }

  /**
   * Approve, deny or send on a channel link's request (#1762). `to` is the person an admin sends a
   * request that names nobody on to. The card goes at once; a refusal is said, and the card stays.
   */
  async decideLink(request: string, approve: boolean, to?: string): Promise<void> {
    try {
      await this.link.call(approve ? "links/approve" : "links/deny", { request, ...(to ? { for: to } : {}) });
      this.linkRequests.value = withoutRequest(this.linkRequests.value, request);
    } catch (error) {
      this.say(describe(error));
    }
  }

  /**
   * Approve or deny a machine's ask to join (#994). The card goes at once; the control plane's
   * control/joinDecided says the same to every other client. A refusal is said, and the card stays.
   */
  async decideJoin(request: string, approve: boolean): Promise<void> {
    try {
      await this.link.call(approve ? "hosts/approveJoin" : "hosts/denyJoin", { request });
      this.joinRequests.value = withoutJoin(this.joinRequests.value, request);
    } catch (error) {
      this.say(describe(error));
    }
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
    const said = params as { host?: unknown; state?: unknown; workspace?: MachineWorkspace } | null;
    const host = said?.host;
    if (typeof host !== "string") {
      void this.load();
      return;
    }
    // Its state and workspace as said, at once: a workspace's start shows its steps as they come (#691).
    if (typeof said?.state === "string" && said.state !== "removed") this.takeHostRow({ id: host, state: said.state, workspace: said.workspace });
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
      if (!hostAnswers(now.state)) return this.loadLastHeard(host);
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
      this.folders.value = without(this.folders.value);
      this.clones.value = without(this.clones.value);
      this.permissions.value = without(this.permissions.value);
      this.elicitations.value = without(this.elicitations.value);
      this.workflows.value = notOf(this.workflows.value);
      this.pageRevisions.value = notOf(this.pageRevisions.value);
      this.pins.value = notOf(this.pins.value);
      this.sessionPins.value = notOf(this.sessionPins.value);
      this.workflowPins.value = notOf(this.workflowPins.value);
      this.serverViews.value = notOf(this.serverViews.value);
      this.leases.value = without(this.leases.value);
      this.hostedMCP.value = without(this.hostedMCP.value);
      this.mcpHealth.value = without(this.mcpHealth.value);
      this.runtimes.value = without(this.runtimes.value);
      this.accounts.value = without(this.accounts.value);
      this.sandboxDefaults.value = without(this.sandboxDefaults.value);
      this.sandboxSetBy.value = without(this.sandboxSetBy.value);
      this.policyStates.value = without(this.policyStates.value);
      this.passThrough.value = without(this.passThrough.value);
      this.rememberedModes.value = without(this.rememberedModes.value);
      this.resuming.value = without(this.resuming.value);
      this.events.value = without(this.events.value);
      this.costs.value = without(this.costs.value);
      this.disk.value = without(this.disk.value);
      this.storeNotes.value = without(this.storeNotes.value);
    });
    for (const key of [...this.archivedHolds.keys()]) if (key.startsWith(prefix)) this.archivedHolds.delete(key);
    this.searched.delete(host);
    if (this.searchNext.value[host]) this.searchNext.value = without(this.searchNext.value);
  }

  /** What an offline host last listed, from the control plane (#962), when nothing of it is held:
   *  a page opened while it is stopped lists its folders and sessions as one open when it went. */
  private async loadLastHeard(host: string): Promise<void> {
    if (this.hostIsOnline(host) || this.folders.value[host] !== undefined) return;
    const heard = await this.link.call("hosts/lastHeard", { host: host as MachineRef }).catch(() => null);
    if (!heard || this.hostIsOnline(host) || this.folders.value[host] !== undefined) return;
    batch(() => {
      if (heard.agents) this.replaceAgents(heard.agents, host);
      if (heard.folders) this.folders.value = { ...this.folders.value, [host]: heard.folders };
    });
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
    for (const [key, hold] of this.archivedHolds) {
      if (!key.startsWith(prefix)) continue;
      hold.listed = 0;
      void this.listArchived(host, key.slice(prefix.length), key, Math.max(...hold.limits));
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
    // Archived ones too, as the window lists them: the sidebar folds them under Archived folders
    // (#343), and Spending still counts what they cost.
    const folders = await this.link.call("folders/list", { includeArchived: true }, host).catch(failed("folders/list"));
    if (folders) this.folders.value = { ...this.folders.value, [host]: folders };
    const clones = await this.link.call("folders/clones", {}, host).catch(failed("folders/clones"));
    if (clones) this.clones.value = { ...this.clones.value, [host]: clones };
    void this.loadRuntimes(host);
    void this.link.call("pins/list", {}, host).then((listed) => {
      const held = Object.fromEntries(Object.entries(this.pins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const sessions = Object.fromEntries(Object.entries(this.sessionPins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const flows = Object.fromEntries(Object.entries(this.workflowPins.value).filter(([key]) => !key.startsWith(`${host}|`)));
      const views = Object.fromEntries(Object.entries(this.serverViews.value).filter(([key]) => !key.startsWith(`${host}|`)));
      for (const folder of listed) {
        views[`${host}|${folderKey(folder.folder)}`] = folder.views ?? [];
        held[`${host}|${folderKey(folder.folder)}`] = folder.pins;
        sessions[`${host}|${folderKey(folder.folder)}`] = folder.sessions ?? [];
        flows[`${host}|${folderKey(folder.folder)}`] = folder.workflows ?? [];
      }
      this.pins.value = held;
      this.sessionPins.value = sessions;
      this.workflowPins.value = flows;
      this.serverViews.value = views;
    }).catch(failed("pins/list"));
    // A host from before #251 doesn't answer, and nothing is said to be coming back.
    void this.link.call("agents/resuming", {}, host).then((response) => {
      this.resuming.value = { ...this.resuming.value, [host]: response.agentIDs };
    }).catch(failed("agents/resuming"));
    void this.link.call("resources/snapshot", {}, host).then((snapshot) => {
      this.leases.value = { ...this.leases.value, [host]: snapshot };
    }).catch(failed("resources/snapshot"));
    // A host from before #488 doesn't know the method, and hosts no servers.
    void this.link.call("mcp/hosted", {}, host).then((snapshot) => {
      this.hostedMCP.value = { ...this.hostedMCP.value, [host]: snapshot };
    }).catch(failed("mcp/hosted"));
    // A host from before #753 doesn't know it: its page shows the hosted servers alone.
    void this.link.call("mcp/health", {}, host).then((snapshot) => {
      this.mcpHealth.value = { ...this.mcpHealth.value, [host]: snapshot };
    }).catch(failed("mcp/health"));
    // A host too old to know disk/state says nothing, and no strip is drawn.
    void this.link.call("disk/state", {}, host).then((state) => {
      this.disk.value = { ...this.disk.value, [host]: state };
    }).catch(failed("disk/state"));
    // A host too old to know store/notes says nothing, as one with nothing to say.
    void this.link.call("store/notes", {}, host).then((state) => {
      this.storeNotes.value = { ...this.storeNotes.value, [host]: state.notes };
    }).catch(failed("store/notes"));
    // The person's display choices, from their Mac (#1033). A Mac too old to know the method
    // leaves every choice at its default.
    if (host === this.macHostID.peek()) {
      void this.link.call("preferences/get", {}, host).then((said) => preferencesSaid(said))
        .catch(failed("preferences/get"));
    }
    // A host from before #984 doesn't know it: the Time page shows no milestones.
    void this.link.call("milestones/state", {}, host).then((state) => this.takeMilestones(host, state))
      .catch(failed("milestones/state"));
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

  /** The folders whose archived sessions are on screen: the limit each view asked for, and the
   *  most listed since this connection opened. The sidebar's fold and the Archive page each hold
   *  one, so the one closing first does not take the other's rows (#2731). */
  private archivedHolds = new Map<string, { limits: number[]; listed: number }>();


  /** The folder's workflow list is on screen. The first holder asks for it. */
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

  /** One folder's newest `limit` archived sessions, asked for when a view of them opens (#170): the
   *  sidebar's few (#2731) or the Archive page's page. Only more than is held is asked again. Each
   *  call is matched by one `unloadArchived` with the same limit. */
  async loadArchived(host: string, folder: string, limit = archivedPage): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const hold = this.archivedHolds.get(key) ?? { limits: [], listed: 0 };
    this.archivedHolds.set(key, hold);
    hold.limits.push(limit);
    if (limit <= hold.listed) return;
    await this.listArchived(host, folder, key, limit);
  }

  private async listArchived(host: string, folder: string, key: string, limit: number): Promise<void> {
    const hold = this.archivedHolds.get(key);
    if (hold) hold.listed = Math.max(hold.listed, limit);
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: false, archivedOnly: true, folder: folder as never, lean: true, limit,
    }, host).catch(() => null);
    if (!listed || this.archivedHolds.get(key) !== hold) return;
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
    this.saidLines.value = {};
    if (!words) return;
    const request: ListRequest = {
      includeArchived: true, archivedCommands: false, archivedOnly: false, lean: true, limit: searchShown, query: words,
    };
    for (const host of this.hosts.value) {
      if (turn !== this.searchTurn) return;
      if (!this.hostIsOnline(host.id)) continue;
      await this.search(request, host.id, turn);
      if (turn !== this.searchTurn) return;
      // What was said (#1585): the sessions whose prompts or replies hold the words. Not asked of a
      // host too old to say (#1748).
      if (!this.has(host.id, Capability.agentsSaid1)) continue;
      const said = await this.link.call("agents/said", { text: words }, host.id).catch(() => null);
      if (Array.isArray(said?.matches) && turn === this.searchTurn) {
        this.saidLines.value = { ...this.saidLines.value, ...Object.fromEntries(said.matches.map((m) => [m.agentID, m.line])) };
      }
    }
  }

  /** While the sidebar searches: the line each session said that matches, by its id (#1585). */
  readonly saidLines = signal<Record<string, string>>({});

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
        this.setAgents(host, held.filter((a) => !without.has(a.id)), [...new Set(gone.map(agentFolderPath))]);
      }
    }
    this.searched.clear();
  }

  /** A view of them closed: once the last has, the folder's archived sessions are let go, and listed
   *  again when one opens. */
  unloadArchived(host: string, folder: string, limit = archivedPage): void {
    const key = `${host}|${folderKey(folder)}`;
    const hold = this.archivedHolds.get(key);
    if (hold) {
      const at = hold.limits.indexOf(limit);
      if (at >= 0) hold.limits.splice(at, 1);
      if (hold.limits.length > 0) return;
    }
    this.archivedHolds.delete(key);
    this.dropArchived(host, folder);
  }

  async openSession(host: string, session: string): Promise<void> {
    this.watch(host, session);
    await this.loadTranscript(host, session);
  }

  closeSession(): void {
    this.unwatch();
  }

  /** The open session's record whole, with the menus a lean list leaves out (#107). Whether its host answered. */
  private async loadWhole(host: string, session: string): Promise<boolean> {
    const listed = await this.link.call("agents/list", {
      includeArchived: true, archivedCommands: true, archivedOnly: false, lean: false, agentID: session as never, limit: 1,
    }, host).catch(() => null);
    // A host from before #107 ignores agentID and answers with its newest, which isn't this one.
    const whole = listed?.find((a) => a.id === session);
    if (whole) this.addAgents([whole], host);
    return listed !== null;
  }

  /**
   * The open session's record and its history, side by side. Looked for once its host has answered both,
   * so one not in hand then has gone (#2652); a call that failed is not an answer, and the chat says it
   * with Try Again instead of calling the session deleted (#2743). Only the history is waited for.
   */
  private async loadTranscript(host: string, session: string): Promise<void> {
    const page = this.loadPage(host, session);
    void Promise.all([this.loadWhole(host, session), page]).then(([listed, paged]) => {
      const now = this.watching.value;
      if (listed && paged && now?.host === host && now.session === session) this.lookedFor.value = { host, session };
    }, () => {});
    await page;
  }

  /**
   * The finished turns first, as summaries, then the transcript from where the open turn starts. Whether
   * its host answered: with the page, or that it has no such session (#2743).
   */
  private async loadPage(host: string, session: string): Promise<boolean> {
    // Only what is heard from now: what came before is on the page or before it, and laid after a
    // page that starts in a turn's reply it drew the turn's ask below that reply (#2807).
    this.heardSincePage = [];
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
    let gone = false;
    const page = await this.link.call("agents/transcript", { agentID, limit: 200, from: turns.openStart }, host)
      .catch((error: unknown) => {
        gone = error instanceof CallFailed && error.code === Failure.noSuchAgent;
        failed.page = describe(error);
        log("call.failed", error instanceof CallFailed ? error.code : undefined);
        return null;
      });
    // A chat opened since is not this one, and a newer load of this one has the say.
    const now = this.watching.value;
    if (now?.host !== host || now.session !== session || load !== this.transcriptLoads) return false;
    if (!page) {
      this.transcriptLoadFailure.value = { nothingLoaded: true, reason: failed.page ?? "no answer." };
      return gone;
    }
    batch(() => {
      this.replaceTurns(turns);
      this.replaceTranscript(page);
      if (failed.turns) this.transcriptLoadFailure.value = { nothingLoaded: false, reason: failed.turns };
    });
    return true;
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

  /** Find in Chat (#1532): what was said in the open chat that holds `text`, found by its host. */
  async find(host: string, agentID: string, text: string): Promise<FindResult | null> {
    return this.link.call("agents/find", { agentID: agentID as UUID, text }, host).catch(() => null);
  }

  /** Whether the transcript entry at `index` is in hand: in the page, or in a stored turn (AgentsModel.holds). */
  holds(index: number): boolean {
    return (this.entries.value.length > 0 && index >= this.firstEntryIndex.value)
      || this.turns.value.some((turn) => turn.start <= index && index < turn.end);
  }

  /** Earlier pages, as Load Earlier brings them, until the entry at `index` is in hand or no more come (#1532). */
  async loadUntil(index: number): Promise<void> {
    while (!this.holds(index) && this.hasMoreOfTheConversation) {
      const before = [this.firstTurn.value, this.firstEntryIndex.value, this.turns.value.length, this.entries.value.length].join();
      await this.loadEarlier();
      if ([this.firstTurn.value, this.firstEntryIndex.value, this.turns.value.length, this.entries.value.length].join() === before) return;
    }
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
    if (!page) return { entries: [], firstIndex: range.start, failed: true };
    return { entries: page.entries, firstIndex: page.firstIndex };
  }

  // MARK: What the browser sends (071 US3)

  /** Each runtime and what each says it can take, by host. */
  readonly runtimes = signal<Record<string, RuntimeStatus[]>>({});
  /** Allowance readings and out states for each host's Runtimes page. */
  readonly runtimeAllowances = signal<Record<string, RuntimeAllowances>>({});
  /** Each host's sandbox default per runtime (SandboxSettings); absent means its runtime decides. */
  readonly sandboxDefaults = signal<Record<string, Record<string, SandboxChoice>>>({});
  /** Auto (#2658): the person's order, Include switches and own cells, and every cell, by host. */
  readonly autoSettings = signal<Record<string, AutoSettings>>({});
  readonly autoMappings = signal<Record<string, AutoMappings>>({});
  /** Why the last load of a host's Auto cells failed (#2894); cleared when one starts. */
  readonly autoProblems = signal<Record<string, string>>({});
  private readonly autoLoading = new Set<string>();
  /** Each host's mark while the organisation requires the sandbox (SandboxSettings.setBy, #998). */
  readonly sandboxSetBy = signal<Record<string, PolicySetBy>>({});
  /** The Mac-wide permission choice for Cursor, Grok and OpenCode (061). */
  readonly clientPermissions = signal<Record<string, ClientPermissionSettings>>({});
  readonly accounts = signal<Record<string, RuntimeAccount[]>>({});
  /** A choice made on a menu that the host hasn't confirmed, by agent then option. */
  readonly pendingOptions = signal<Record<string, Record<string, JSONValue>>>({});
  /** What is typed and attached, per session or per new-agent form, kept across a reload (#254). */
  readonly drafts = new Drafts(typeof localStorage === "undefined" ? undefined : localStorage);

  /**
   * Starts the workspace `host` runs on (#691, the strip's Start). The control plane answers at
   * once with the host's row; the start's progress comes as `control/hostChanged`, and a refusal
   * is said in `problem`.
   */
  /** Allow or Don’t Allow: any client may answer, and the control plane takes the first. */
  async answerGitLend(ask: GitLendAsk, allowed: boolean): Promise<void> {
    this.gitAsksAnswered.value = new Set([...this.gitAsksAnswered.value, askID(ask.host, ask.server)]);
    await this.lendGit(ask.host, ask.from, ask.server, allowed);
  }

  /** Settings ▸ Backups (#1810), asked when Settings is shown. */
  loadBackups(): void {
    void this.hostBackups(this.macHostID.value).then((state) => {
      if (state) this.backups.value = state;
    });
  }

  /** A host's backups (#1815): the Mac's for Settings ▸ Backups, a server's for its own section.
   * Null from a host too old to know backups/state, which leaves the section out. */
  async hostBackups(host: string): Promise<BackupState | null> {
    try {
      return await this.link.call("backups/state", {}, host);
    } catch {
      return null;
    }
  }

  /** How often, how many kept, where: answered with the state after, or null when refused, which is
   * said. The Mac's is kept for every view of it. */
  async configureBackups(settings: BackupSettings, host = this.macHostID.value): Promise<BackupState | null> {
    return this.keepBackups(host, () => this.link.call("backups/configure", settings, host));
  }

  async makeBackup(host = this.macHostID.value): Promise<BackupState | null> {
    return this.keepBackups(host, () => this.link.call("backups/make", {}, host));
  }

  private async keepBackups(host: string, call: () => Promise<BackupState>): Promise<BackupState | null> {
    try {
      const state = await call();
      if (this.isMac(host)) this.backups.value = state;
      return state;
    } catch (error) {
      this.say(describe(error));
      return null;
    }
  }

  /** The result, or null when it failed, which is said. */
  async restoreBackup(id: string, host = this.macHostID.value): Promise<BackupRestoreResult | null> {
    try {
      return await this.link.call("backups/restore", { id }, host);
    } catch (error) {
      this.say(describe(error));
      return null;
    }
  }

  /** Said to the control plane; Settings ▸ Git access takes one back with `allowed` false. */
  async lendGit(host: string, from: string, server: string, allowed: boolean): Promise<void> {
    try {
      await this.link.call("hosts/lendGit", { host: host as MachineRef, from: from as MachineRef, server, allowed });
      if (!allowed) {
        this.hosts.value = this.hosts.value.map((row) => {
          if (row.id !== host || !row.gitFrom) return row;
          const rest = { ...row.gitFrom };
          delete rest[server];
          return { ...row, gitFrom: rest };
        });
      }
    } catch (error) {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      this.say(describe(error));
    }
  }

  async startHost(host: string): Promise<void> {
    if (this.hostsBeingStarted.value.includes(host)) return;
    this.hostsBeingStarted.value = [...this.hostsBeingStarted.value, host];
    try {
      const row = await this.link.call("hosts/start", { host: host as MachineRef });
      this.takeHostRow(row);
    } catch (error) {
      log("call.failed", error instanceof CallFailed ? error.code : undefined);
      this.say(describe(error));
    } finally {
      this.hostsBeingStarted.value = this.hostsBeingStarted.value.filter((h) => h !== host);
    }
  }

  /** × on a kept prompt: it isn't sent, and the workspace keeps starting (US3 AS3). */
  async dropKept(kept: KeptRequest): Promise<void> {
    this.kept.value = this.kept.value.filter((k) => k.id !== kept.id);
    await this.link.call("hosts/dropKept", { host: kept.host, id: kept.id }).catch((error: unknown) => this.say(describe(error)));
  }

  /** Try Again on one that wasn't sent: kept again, and the workspace started. */
  async retryKept(kept: KeptRequest): Promise<void> {
    await this.link.call("hosts/retryKept", { host: kept.host, id: kept.id }).catch((error: unknown) => this.say(describe(error)));
  }

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
   * A folder on `host` as a folder (#115), as the window's Add Folder… does. Answers the
   * folder, or null with `problem` saying why. With `project`, it joins the project picked in
   * the Add Folder sheet (#2671); with none, a folder that names no project gets one of its own.
   */
  async addFolder(host: string, folder: string, project?: string): Promise<FolderSummary | null> {
    const params = project === undefined ? { folder: folder as never } : { folder: folder as never, project };
    const summary = await this.act("folders/add", params, host);
    if (summary) this.upsertFolder(summary, host);
    return summary;
  }

  /**
   * Clones `url` into the host's home folder and adds it (027, #115). Answers once the clone
   * has finished; the row meanwhile comes from `clone/changed`.
   */
  async cloneFolder(host: string, url: string): Promise<FolderSummary | null> {
    const summary = await this.act("folders/clone", { url }, host);
    if (summary) this.upsertFolder(summary, host);
    return summary;
  }

  /**
   * A folder put away (#668), as the window's Archive does: it moves to Archived folders with
   * its sessions. A refusal names the sessions to stop first.
   */
  async archiveFolder(host: string, folder: string): Promise<FolderSummary | null> {
    const summary = await this.act("folders/archive", { folder: folder as never }, host);
    if (summary) this.upsertFolder(summary, host);
    return summary;
  }

  /**
   * An archived folder unarchived (#343), as the window's Unarchive does: a folder again,
   * with its new-session form open.
   */
  async unarchiveFolder(host: string, folder: string): Promise<FolderSummary | null> {
    const summary = await this.act("folders/unarchive", { folder: folder as never }, host);
    if (summary) this.upsertFolder(summary, host);
    return summary;
  }

  /**
   * An archived folder deleted (#677), asked first: every session in it and its record; its
   * folder stays. A refusal says which sessions hold it.
   */
  async deleteFolder(host: string, folder: string): Promise<boolean> {
    if (await this.act("folders/delete", { folder: folder as never }, host) === null) return false;
    this.removeFolder(folder, host);
    return true;
  }

  /**
   * The changes to a folder's own files waiting for Keep or Undo (#531): those asked in `session`,
   * the agent that made them, or with no session, those asked of the folder `folder` on its page.
   */
  guardedChanges(host: string, where: { session: string } | { folder: string }): { folder: string; change: GuardedChange }[] {
    const found: { folder: string; change: GuardedChange }[] = [];
    for (const summary of this.folders.value[host] ?? []) {
      if ("folder" in where && folderKey(summary.folder.folder) !== folderKey(where.folder)) continue;
      for (const change of summary.guardedChanges ?? []) {
        const askedIn = change.askedIn ?? null;
        if ("session" in where ? askedIn === where.session : askedIn === null) {
          found.push({ folder: summary.folder.folder, change });
        }
      }
    }
    return found;
  }

  /** What a guarded file was and is (#502), for the person deciding. */
  async readGuardedChange(host: string, folder: string, change: GuardedChange): Promise<GuardedChangeReading | null> {
    return await this.act("folders/readGuardedChange", { folder: folder as never, path: change.path }, host);
  }

  /** Keep (the change is used from now on) or Undo (the approved copy goes back), of the file as it was shown. */
  async settleGuardedChange(host: string, folder: string, reading: GuardedChangeReading, keep: boolean): Promise<void> {
    const params = { folder: folder as never, path: reading.path, ...(reading.digest !== undefined ? { digest: reading.digest } : {}) };
    const summary = await this.act(keep ? "folders/keepGuardedChange" : "folders/undoGuardedChange", params, host);
    if (summary) this.upsertFolder(summary, host);
  }

  /**
   * What a waiting item is (#773): a file's diff against the approved copy, an MCP server's entry,
   * a plugin's files. Throws a refusal, which the sheet says in its place.
   */
  readApproval(host: string, folder: string, approval: Approval): Promise<GuardedChangeReading> {
    return this.link.call("approvals/read", { folder: folder as never, kind: approval.kind, key: approval.key }, host);
  }

  /**
   * Approve, Deny or Request Changes of a waiting item (#773), of the version read (`digest`), so a
   * change since is refused and not approved. Throws a refusal, which the sheet says in its place,
   * staying open; answered, the folder's list is the host's again.
   */
  async answerApproval(host: string, folder: string, approval: Approval, action: ApprovalAction,
    digest: string | undefined, note?: string): Promise<FolderSummary> {
    const summary = await this.link.call("approvals/answer", {
      folder: folder as never, kind: approval.kind, key: approval.key, action,
      ...(digest !== undefined ? { digest } : {}), ...(note !== undefined ? { note } : {}),
    }, host);
    this.upsertFolder(summary, host);
    return summary;
  }

  /**
   * Keep Session (#773): an agent's request to archive its session denied, so the session stays
   * where it is. From the row's menu, so a refusal is said in `problem`.
   */
  async keepSession(host: string, agent: Agent): Promise<void> {
    const folder = agentFolderPath(agent);
    const listed = (this.folders.value[host] ?? []).find((p) => folderKey(p.folder.folder) === folder)?.folder.folder;
    const summary = await this.act("approvals/answer",
      { folder: (listed ?? folder) as never, kind: "archive", key: agent.id, action: "deny" }, host);
    if (summary) this.upsertFolder(summary, host);
  }

  /**
   * Dismiss a failed workflow (#989): out of Needs You until it fails again, kept on the workflow's
   * record on its host. From the row's menu, so a refusal is said in `problem`.
   */
  async dismissWorkflowFailure(host: string, folder: string, approval: Approval): Promise<void> {
    const summary = await this.act("approvals/answer", {
      folder: folder as never, kind: approval.kind, key: approval.key, action: "dismiss",
      ...(approval.digest !== undefined ? { digest: approval.digest } : {}),
    }, host);
    if (summary) this.upsertFolder(summary, host);
  }

  /** The folder joins a project (#2317), through its own machine. Throws a refusal. */
  async setFolderProject(host: string, folder: string, project: string): Promise<void> {
    const summary = await this.link.call("folders/setProject", { folder: folder as never, project }, host);
    this.upsertFolder(summary, host);
  }

  /** What a folder's merged pull requests say of their cost (#2352). Throws a refusal. */
  async setFolderPRCostComment(host: string, folder: string, prCostComment: PRCostComment): Promise<void> {
    const summary = await this.link.call("folders/setPRCostComment", { folder: folder as never, prCostComment }, host);
    this.upsertFolder(summary, host);
  }

  /** A folder pinned to the top of the sidebar, or not, as the window's Pin and Unpin. */
  async setFolderPinned(host: string, folder: string, pinned: boolean): Promise<void> {
    const summary = await this.act("folders/setPinned", { folder: folder as never, pinned }, host);
    if (summary) this.upsertFolder(summary, host);
  }

  /** The folders at `path` on `host`, for choosing one as a folder (037). Throws a refusal. */
  browse(host: string, path: string): Promise<DirectoryListing> {
    return this.link.call("files/browse", { path }, host);
  }

  /** What runs on a host, and what each runtime takes; asked once a connection. */
  async loadRuntimes(host: string): Promise<void> {
    const macHost = this.macHostID.peek();
    // Auto's cells, for the pills' words on every runtime (#2658): the Mac's host keeps them.
    if (!this.autoMappings.peek()[macHost]) void this.loadAuto(macHost);
    const [runtimes, accounts, modes, sandbox, allowances, profiles, policy, passThrough, permissions] = await Promise.all([
      this.link.call("runtimes/list", {}, host).catch(() => null),
      this.link.call("runtimes/accounts", {}, host).catch(() => null),
      this.link.call("modes/remembered", {}, host).catch(() => null),
      // A host on an older build is not asked by the page: every runtime then follows its own.
      this.link.call("sandbox/state", {}, host).catch(() => null),
      this.link.call("runtimes/allowances", null, host).catch(() => null),
      // A host on an older build has no added accounts (#840).
      this.link.call("runtimes/accountProfiles", {}, host).catch(() => null),
      // A host on an older build follows no policy (#998).
      this.link.call("daemon/policyState", {}, host).catch(() => null),
      this.link.call("settings/passThrough", {}, host).catch(() => null),
      this.clientPermissions.value[macHost] ? Promise.resolve(null)
        : this.link.call("clientPermissions/state", {}, macHost).catch(() => null),
    ]);
    batch(() => {
      if (sandbox) {
        this.sandboxDefaults.value = { ...this.sandboxDefaults.value, [host]: sandbox.defaults };
        const { [host]: _, ...rest } = this.sandboxSetBy.value;
        this.sandboxSetBy.value = sandbox.setBy ? { ...rest, [host]: sandbox.setBy } : rest;
      }
      if (runtimes) this.runtimes.value = { ...this.runtimes.value, [host]: sortedRuntimes(runtimes) };
      if (allowances) this.runtimeAllowances.value = { ...this.runtimeAllowances.value, [host]: allowances };
      if (accounts) this.accounts.value = { ...this.accounts.value, [host]: accounts };
      if (profiles) this.accountProfiles.value = { ...this.accountProfiles.value, [host]: profiles };
      if (modes) this.rememberedModes.value = { ...this.rememberedModes.value, [host]: modes };
      if (policy) this.policyStates.value = { ...this.policyStates.value, [host]: policy };
      if (passThrough) this.passThrough.value = { ...this.passThrough.value, [host]: passThrough.names };
      if (permissions) {
        this.clientPermissions.value = { ...this.clientPermissions.value, [macHost]: permissions };
      }
    });
  }

  /** Set the Mac-wide permission choice, even when this chat belongs to a server. */
  /** Auto's settings and every cell on a host (#2658); an older host has none. */
  /** One load at a time per host: the Auto page asks on each draw until the cells come. */
  async loadAuto(host: string): Promise<void> {
    if (this.autoLoading.has(host)) return;
    this.autoLoading.add(host);
    const { [host]: _, ...others } = this.autoProblems.value;
    this.autoProblems.value = others;
    let problem: string | undefined;
    try {
      const [settings, mappings] = await Promise.all([
        this.link.call("auto/state", {}, host).catch(() => null),
        this.link.call("auto/mappings", {}, host).catch((error: unknown) => {
          problem = describe(error);
          return null;
        }),
      ]);
      batch(() => {
        if (settings) this.autoSettings.value = { ...this.autoSettings.value, [host]: settings };
        if (mappings) this.autoMappings.value = { ...this.autoMappings.value, [host]: mappings };
        if (problem) this.autoProblems.value = { ...this.autoProblems.value, [host]: problem };
      });
    } finally {
      this.autoLoading.delete(host);
    }
  }

  /** Save Auto's settings on the Mac's host, which the Mac sends on to its machines (FR-017). */
  async setAutoSettings(host: string, settings: AutoSettings): Promise<void> {
    const before = this.autoSettings.value[host];
    this.autoSettings.value = { ...this.autoSettings.value, [host]: settings };
    try {
      const saved = await this.link.call("auto/set", settings, host);
      this.autoSettings.value = { ...this.autoSettings.value, [host]: saved };
      await this.loadAuto(host);
    } catch (error) {
      if (before) this.autoSettings.value = { ...this.autoSettings.value, [host]: before };
      this.say(describe(error));
    }
  }

  /** What Auto would pick now for a folder and values, or null. */
  async autoPreview(host: string, request: AutoPreviewRequest): Promise<AutoPreview | null> {
    return this.link.call("auto/preview", request, host).catch(() => null);
  }

  /** A running agent's model level or permission mode, on its own runtime (#2658). */
  async setLevels(host: string, agentID: string, field: "model" | "permission", level: string): Promise<void> {
    const levels: Levels = field === "model" ? { model: level as ModelLevel } : { permission: level as PermissionLevel };
    try {
      await this.link.call("agents/setLevels", { agentID: agentID as UUID, levels }, host);
    } catch (error) {
      this.say(describe(error));
    }
  }

  /** A running agent's own answer to permission requests; none follows Settings (FR-019). */
  async setAgentClientPermission(host: string, agentID: string, mode: ClientPermissionMode | undefined): Promise<void> {
    try {
      await this.link.call("agents/setClientPermission", { agentID: agentID as UUID, ...(mode ? { mode } : {}) }, host);
    } catch (error) {
      this.say(describe(error));
    }
  }

  async setClientPermissionMode(runtimeID: string, mode: ClientPermissionSettings["cursor"]): Promise<void> {
    if (!["cursor", "grok", "opencode"].includes(runtimeID)) return;
    const host = this.macHostID.peek();
    const current = this.clientPermissions.value[host] ?? { cursor: "default", grok: "default", opencode: "default" };
    const settings = { ...current, [runtimeID]: mode } as ClientPermissionSettings;
    try {
      const saved = await this.link.call("clientPermissions/set", settings, host);
      this.clientPermissions.value = { ...this.clientPermissions.value, [host]: saved };
    } catch {
      this.problem.value = "That did not reach your Mac.";
    }
  }

  /** A host's MCP servers (#753); from a host too old to say, its hosted servers alone, as the page
   * showed them before. */
  mcpHealthOf(host: string): MCPHealthSnapshot | undefined {
    const health = this.mcpHealth.value[host];
    if (health) return health;
    const hosted = this.hostedMCP.value[host];
    if (!hosted) return undefined;
    return {
      servers: hosted.servers.map((live) => ({
        name: live.name, ...(live.folder != null ? { folder: live.folder } : {}),
        transport: "stdio" as const, hosted: true, live, check: "unchecked" as const,
      })),
      problems: [], at: hosted.at,
    };
  }

  /** Check Now on the person's own servers (no folder) or a folder's (#753). */
  async checkMCPHealth(host: string, folder?: string): Promise<void> {
    const request = folder === undefined ? {} : { folder: hostedFolderPath(folder) };
    const snapshot = await this.link.call("mcp/health/check", request, host).catch(() => null);
    if (snapshot) this.mcpHealth.value = { ...this.mcpHealth.value, [host]: snapshot };
  }

  /**
   * Takes one connector out of its mcp.json (#2154), the person's own (no folder) or a folder's,
   * one the app added or one written by hand, then checks the rest again. Its secrets stay.
   * Undefined when it went, else why not.
   */
  async removeConnector(host: string, name: string, folder?: string): Promise<string | undefined> {
    const destination = folder === undefined ? { kind: "personal" } : { kind: "folder", folder: hostedFolderPath(folder) };
    const why = await this.link.call("mcp/remove", { destination: destination as never, name }, host)
      .then(() => undefined, (error: unknown) => describe(error));
    if (why === undefined) await this.checkMCPHealth(host, folder);
    return why;
  }

  async markRuntimeAvailable(host: string, credentialKey: string): Promise<void> {
    const allowances = await this.link.call("runtimes/markAvailable", { credentialKey }, host).catch(() => null);
    if (allowances) this.runtimeAllowances.value = { ...this.runtimeAllowances.value, [host]: allowances };
  }

  /** The accounts of one of a host's runtimes: the ones added (#840), in the order they were added, then the organisation's (#999). */
  addedAccounts(host: string, runtimeID: string): AccountProfile[] {
    return (this.accountProfiles.value[host] ?? []).filter((a) => a.runtimeID === runtimeID);
  }

  /** Add an account to a runtime (#840). Throws the host's refusal. */
  async addAccount(host: string, runtimeID: string, name: string): Promise<AccountProfile> {
    const added = await this.link.call("runtimes/addAccount", { runtimeID, name }, host);
    const rest = (this.accountProfiles.value[host] ?? []).filter((a) => a.id !== added.id);
    this.accountProfiles.value = { ...this.accountProfiles.value, [host]: [...rest, added] };
    void this.reloadAllowances(host);
    return added;
  }

  /** Remove an added account: its sessions stop, and its folder goes (#840). */
  async removeAccount(host: string, account: AccountProfile): Promise<void> {
    await this.link.call("runtimes/removeAccount", { runtimeID: account.runtimeID, accountID: account.id }, host);
    this.accountProfiles.value = {
      ...this.accountProfiles.value,
      [host]: (this.accountProfiles.value[host] ?? []).filter((a) => a.id !== account.id),
    };
    void this.reloadAllowances(host);
  }

  /** Reaches the Model By (#999): a runtime's account for new sessions, "default" for its own sign-in. Throws the host's refusal. */
  async setDefaultAccount(host: string, runtimeID: string, accountID: string): Promise<void> {
    await this.link.call("runtimes/setDefaultAccount", { runtimeID, accountID }, host);
    const profiles = await this.link.call("runtimes/accountProfiles", {}, host).catch(() => null);
    if (profiles) this.accountProfiles.value = { ...this.accountProfiles.value, [host]: profiles };
  }

  private async reloadAllowances(host: string): Promise<void> {
    const allowances = await this.link.call("runtimes/allowances", null, host).catch(() => null);
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
      // Kept for a stopped workspace (#691 US3): its bubble says so, and it goes when the host is up.
      if (error instanceof CallFailed && error.code === Failure.kept && this.noteKept(error)) return true;
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
      if (this.isMac(host) || !runtime || !takesKey(runtime) || this.tokenAsk.peek()) throw error;
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
   * Continue in the folder (#119): a successor that reads this session and carries on,
   * with whatever was typed. Answers its id, or null with `problem` saying why.
   */
  async continueInFolder(host: string, agentID: string, text = "", attachments: Attachment[] = []): Promise<string | null> {
    return this.act("agents/continueInFolder",
      { agentID: agentID as UUID, text, attachments, requestID: crypto.randomUUID().toUpperCase() as UUID }, host);
  }

  /**
   * Continue in New (#999): a session in the same folder that reads this one and carries on, on the
   * runtime's account for new sessions. Answers its id, or null with `problem` saying why.
   */
  async continueInNew(host: string, agentID: string, onAuto = false): Promise<string | null> {
    return this.act("agents/continueInNew", { agentID: agentID as UUID, requestID: crypto.randomUUID().toUpperCase() as UUID,
      ...(onAuto ? { auto: true } : {}) }, host);
  }

  /**
   * Branch (#342): a new session that carries this one's history so far, the original left alone.
   * Answers its id, or null with `problem` saying why.
   */
  async fork(host: string, agentID: string): Promise<string | null> {
    return this.act("agents/fork", { agentID: agentID as UUID }, host);
  }

  /**
   * Branch from Here (#1658): a new session that goes on from just before the person's prompt
   * `entryID`, with that prompt's `text` in its prompt bar to change and send. Answers its id, or
   * null with `problem` saying why, in the host's words.
   */
  async branchFrom(host: string, agentID: string, entryID: string, text: string): Promise<string | null> {
    const id = await this.act("agents/branchFrom", { agentID: agentID as UUID, entryID: entryID as UUID }, host);
    if (!id) return null;
    const key = `${host}|${id}`;
    const draft = this.drafts.get(key);
    this.drafts.set(key, { text: giveBackInto(text, draft?.text ?? ""), attachments: draft?.attachments ?? [] });
    return id;
  }

  /** Recreate the worktree from its branch (#119); the row follows from `agent/changed`. */
  async recreateWorktree(host: string, agentID: string): Promise<void> {
    const agent = await this.act("agents/recreateWorktree", { agentID: agentID as UUID }, host);
    if (agent) this.apply("agent/changed", agent, host);
  }

  /** Carry on when the allowance is back, or no longer (#1859); the row follows from `agent/changed`. */
  async continueWhenBack(host: string, agentID: string, on: boolean): Promise<void> {
    const agent = await this.act(on ? "agents/continueWhenBack" : "agents/cancelContinue", { agentID: agentID as UUID }, host);
    if (agent) this.apply("agent/changed", agent, host);
  }

  async sendNow(host: string, agentID: string, promptID: string): Promise<void> {
    await this.acting(agentID, { sendNow: promptID }, () =>
      this.act("agents/sendNow", { agentID: agentID as UUID, promptID: promptID as UUID }, host));
  }

  /**
   * What is on its way to each agent (#87; AgentsModel's acting): stop, archive, unarchive or
   * Send now, one at a time. Every control that would send a second sees the first is going.
   */
  readonly onItsWay = signal<Record<string, AgentAct>>({});

  /** Who an action goes to, as the pending mark says it: "your Mac", or the host's name. */
  recipient(host: string): string {
    return this.isMac(host) ? "your Mac" : this.hosts.value.find((h) => h.id === host)?.name ?? "the machine";
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

  /**
   * New words for the person's queued prompt, in its place in the queue (#1552). When it was sent
   * or taken back first, or the call failed, the words go into the prompt bar under `draftKey`.
   */
  async editQueued(host: string, agentID: string, promptID: string, text: string, draftKey: string): Promise<void> {
    const result = await this.act("agents/editQueued", { agentID: agentID as UUID, promptID: promptID as UUID, text }, host);
    if (result?.edited) return;
    this.offeredPrompt.value = { draftKey, text };
    if (result) this.say(sentBeforeEdit);
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
    // Money or tokens, whichever it reached (#838): Agent.goOnRequest.
    const request = goOnRequest(agent, this.costs.value[host]?.limits);
    await this.act("agents/setCeiling", { ...request, agentID: agent.id }, host);
  }

  /** Undo after Archive (#1534): Unarchive what that Archive put away; one it stopped stays stopped. */
  async undoArchive(): Promise<void> {
    const undo = this.archiveUndo.value;
    if (!undo) return;
    this.archiveUndo.value = null;
    for (const id of undo.agentIDs) await this.perform(undo.host, id, "agents/unarchive");
  }

  /** Whether the host took it, so a caller can leave the chat only when it did (#586). */
  async perform(host: string, agentID: string,
                action: "agents/stop" | "agents/archive" | "agents/unarchive"): Promise<boolean> {
    let done = false;
    await this.acting(agentID, action, async () => { done = await this.act(action, { agentID: agentID as UUID }, host) !== null; });
    return done;
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
  /** The editor's save that checks the file first (#1858): refused when it changed since `base`. */
  async writeArtifactOver(host: string, agentID: string, path: string, text: string, base: string): Promise<SaveOutcome> {
    try {
      await this.link.call("artifact/write", { agentID: agentID as UUID, path, text, base }, host);
      return "saved";
    } catch (error) {
      if (error instanceof CallFailed && error.code === Failure.fileChanged) return "changedOnDisk";
      this.say(describe(error));
      return "failed";
    }
  }

  async writeArtifact(host: string, agentID: string, path: string, text: string): Promise<boolean> {
    return (await this.act("artifact/write", { agentID: agentID as UUID, path, text }, host)) !== null;
  }

  /**
   * Files into a folder's drop box (#231), one after another, as the window's drop puts them.
   * Answers the names sent; the first that could not go is said, and stops the rest.
   */
  async putInDropbox(host: string, folder: string, subfolder: string, files: readonly File[]): Promise<string[]> {
    const sent: string[] = [];
    for (const file of files) {
      const refused = dropboxRefusal(file.name, file.size);
      if (refused) {
        this.say(refused);
        break;
      }
      const bytes = new Uint8Array(await file.arrayBuffer());
      if (await this.act("dropbox/put", dropboxRequest(folder, subfolder, file.name, bytes), host) === null) break;
      sent.push(file.name);
    }
    return sent;
  }

  // MARK: Pinned pages (#159)

  pinsIn(host: string, folder: string): PinView[] {
    return this.pins.value[`${host}|${folderKey(folder)}`] ?? [];
  }

  /** A folder's servers' list views (#2032), the hidden ones too, in the servers' order. */
  serverViewsIn(host: string, folder: string): PinView[] {
    return this.serverViews.value[`${host}|${folderKey(folder)}`] ?? [];
  }

  /** A pin or a server's list view at this path: what a sidebar row opens. */
  pinOrViewIn(host: string, folder: string, path: string): PinView | undefined {
    return this.pinsIn(host, folder).find((p) => p.path === path) ?? this.serverViewsIn(host, folder).find((p) => p.path === path);
  }

  /** Hide or Show on a server's list view (#2032): shown at once, then the host told. */
  async setViewHidden(host: string, folder: string, uri: string, hidden: boolean): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    this.serverViews.value = { ...this.serverViews.value,
      [key]: this.serverViewsIn(host, folder).map((v) => {
        if (v.path !== uri) return v;
        const { hidden: _was, ...rest } = v;
        return hidden ? { ...rest, hidden: true } : rest;
      }) };
    await this.act("pins/hideView", { folder: folder as never, uri, hidden }, host);
  }

  /** A file of the folder's: a pinned page, or what an HTML page draws from. */
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

  /** A chat's view pinned to its folder (#189): keyed by its ui:// address. Answers whether
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

  workflowPinsIn(host: string, folder: string): string[] {
    return this.workflowPins.value[`${host}|${folderKey(folder)}`] ?? [];
  }

  /** Pin or Unpin a workflow (#432) from its menu or page: shown at once, then the host told. */
  async setWorkflowPinned(host: string, folder: string, workflowID: string, pinned: boolean): Promise<void> {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.workflowPinsIn(host, folder).filter((id) => id !== workflowID);
    this.workflowPins.value = { ...this.workflowPins.value, [key]: pinned ? [...held, workflowID] : held };
    await this.act(pinned ? "pins/pinWorkflow" : "pins/unpinWorkflow", { folder: folder as never, workflowID }, host);
  }

  /** A Move item among the pinned workflows: shown at once, then the whole order sent once. */
  async arrangeWorkflowPins(host: string, folder: string, ids: string[]): Promise<void> {
    this.workflowPins.value = { ...this.workflowPins.value, [`${host}|${folderKey(folder)}`]: ids };
    await this.act("pins/arrangeWorkflows", { folder: folder as never, workflowIDs: ids }, host);
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

  /** Clear a server's event trigger's missed-events mark (#383). */
  async clearMCPMissed(host: string, summary: WorkflowSummary, name: string, server: string | undefined): Promise<void> {
    const changed = await this.act("workflows/mcpTrigger/clearMissed",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, name,
        ...(server !== undefined ? { server } : {}) }, host);
    if (changed) this.placeWorkflow(changed, host);
  }

  /** Approve (#142): the digest is what the page was showing, so a file changed since still waits. */
  async approveWorkflow(host: string, summary: WorkflowSummary): Promise<void> {
    await this.answerWorkflow(host, summary, "workflows/approve");
  }

  /** Deny on this host only (#391): it does not run here, its file is untouched, and Approve takes it back. */
  async denyWorkflow(host: string, summary: WorkflowSummary): Promise<void> {
    await this.answerWorkflow(host, summary, "workflows/deny");
  }

  private async answerWorkflow(host: string, summary: WorkflowSummary,
    method: "workflows/approve" | "workflows/deny"): Promise<void> {
    const file = summary.awaitingApproval ?? summary.deniedHere;
    if (!file) return;
    const changed = await this.act(method,
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, digest: file.digest }, host);
    if (changed) this.placeWorkflow(changed, host);
  }

  /** Archive or Unarchive (#142), as the window's page has them. */
  async setWorkflowArchived(host: string, summary: WorkflowSummary, archived: boolean): Promise<void> {
    const changed = await this.act("workflows/archive",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, archived }, host);
    if (changed) this.placeWorkflow(changed, host);
  }

  /** Delete its workflow file and let workflow/removed update every open view (#605). */
  async deleteWorkflow(host: string, summary: WorkflowSummary): Promise<boolean> {
    const deleted = await this.act("workflows/delete",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID }, host);
    return deleted !== null;
  }

  private settingsInFlight = new Map<string, Promise<unknown>>();

  /**
   * One setting, its label list, its cooldown, the computers it runs on or what a run may do
   * when done (#162, #317, #433), written
   * to the file through the daemon as the window's page writes it. `change` is applied to what
   * the file says when the call is sent, after any earlier change to the same workflow has been
   * answered, so two quick changes cannot undo each other. The answer replaces the one summary;
   * the list is not asked for again. Answers the daemon's refusal, for the page to say beside
   * the controls, or null.
   */
  setWorkflowSettings(host: string, summary: WorkflowSummary,
                      change: { settings?: (s: WorkflowSettings) => WorkflowSettings; cooldown?: string; labels?: (labels: string[]) => string[]; runsOn?: string[]; whenDone?: WhenDone; continueWhenBack?: boolean }): Promise<string | null> {
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
          ...(change.runsOn !== undefined ? { runsOn: change.runsOn } : {}),
          ...(change.whenDone !== undefined ? { whenDone: change.whenDone } : {}),
          ...(change.continueWhenBack !== undefined ? { continueWhenBack: change.continueWhenBack } : {}),
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

  /** The session whose title is being edited (#751), and whether in the chat's header or its row. */
  readonly renaming = signal<{ id: string; inChat: boolean } | null>(null);

  /** The person's title for a session (#751); empty, the runtime names it again. */
  async rename(host: string, agentID: string, title: string): Promise<void> {
    await this.act("agents/rename", { agentID: agentID as UUID, title }, host);
  }

  /** Mute Notifications / Unmute Notifications (#2003): kept by the session's host. */
  async setMuted(host: string, agentID: string, muted: boolean): Promise<void> {
    await this.act("agents/setMuted", { agentID: agentID as UUID, muted }, host);
  }

  /** Mute Notifications for a workflow's runs, or Unmute (#2003): `muted: true` in its file. */
  async setWorkflowMuted(host: string, summary: WorkflowSummary, muted: boolean): Promise<void> {
    const changed = await this.act("workflows/setMuted",
      { folder: summary.workflow.folder, workflowID: summary.workflow.workflowID, muted }, host);
    if (changed) this.placeWorkflow(changed, host);
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

  /** The personas a start in this folder can pick (#760); none from a host too old to know them,
   *  and null when the host did not answer, so the page asks again once it does (#1096). */
  async personas(host: string, folder: string): Promise<Persona[] | null> {
    return this.link.call("personas/list", { folder: folder as never }, host)
      .catch((error: unknown) => (error instanceof CallFailed && error.code === methodNotFound ? [] : null));
  }

  async worktrees(host: string, folder: string): Promise<WorktreesListResponse | null> {
    return this.link.call("worktrees/list", { folder: folder as never }, host).catch(() => null);
  }

  /** A worktree's size, the newest heard (#790): from `worktrees/sized`, else its list's. */
  worktreeSize(host: string, worktree: WorktreeSummary): WorktreeSize | undefined {
    return this.worktreeSizes.value[host]?.[worktree.root] ?? worktree.size;
  }

  /** Every folder's worktrees on a host, for Activity ▸ Worktrees (#790). */
  async loadWorktrees(host: string): Promise<void> {
    const listed = await this.link.call("worktrees/all", {}, host).catch(() => null);
    if (!listed) return;
    this.worktreeLists.value = { ...this.worktreeLists.value, [host]: listed };
    // What the list now says is as new as anything heard before it.
    const { [host]: _, ...rest } = this.worktreeSizes.value;
    this.worktreeSizes.value = rest;
  }

  /** What removing a worktree would lose; null when it could not be asked, and the problem says why. */
  async checkWorktreeRemoval(host: string, folder: string, root: string): Promise<RemovalCheck | null> {
    return this.link.call("worktrees/check", { folder: folder as never, root: root as never, confirmed: false }, host)
      .catch((error: unknown) => { this.say(describe(error)); return null; });
  }

  /** Remove a worktree; the host checks again either way. */
  async removeWorktree(host: string, folder: string, root: string, confirmed: boolean): Promise<void> {
    await this.link.call("worktrees/remove", { folder: folder as never, root: root as never, confirmed }, host)
      .catch((error: unknown) => this.say(describe(error)));
    await this.loadWorktrees(host);
  }

  /** Delete an idle worktree's build output, and say what it freed; null when it could not. */
  async removeBuildOutput(host: string, folder: string, root: string): Promise<BuildOutputRemoved | null> {
    const removed = await this.link.call("worktrees/removeBuildOutput",
      { folder: folder as never, root: root as never, confirmed: false }, host)
      .catch((error: unknown) => { this.say(describe(error)); return null; });
    void this.loadWorktrees(host);
    return removed;
  }

  /** One start's id per folder, kept until that start succeeds, so a retry is not a second agent (#291). */
  private startRequests = new Map<string, UUID>();

  startRequestID(host: string, folder: string): UUID {
    const key = `${host}|${folderKey(folder)}`;
    const held = this.startRequests.get(key);
    if (held) return held;
    const id = crypto.randomUUID().toUpperCase() as UUID;
    this.startRequests.set(key, id);
    return id;
  }

  /** The start went through. The next one from this folder is a new request. */
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
  async start(host: string, request: StartRequest): Promise<string | SandboxWillNotStart | { kept: KeptRequest } | { autoRefusal: string } | null> {
    try {
      return await this.lending("agents/start", request, host);
    } catch (error) {
      // No runtime Auto may use can take it (FR-011): said over the prompt, which keeps it.
      if (error instanceof CallFailed && error.code === Failure.autoNoRuntime) return { autoRefusal: error.message };
      // Kept until its stopped workspace is up (#691 US3): the page shows it, then opens the agent.
      if (error instanceof CallFailed && error.code === Failure.kept) {
        const kept = this.noteKept(error);
        if (kept) return { kept };
      }
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
  /** Each host's use by hour and by day (#823), for the charts on Cost. */
  readonly usage = signal<Record<string, UsageHistory>>({});
  /** Where the time of running chats went, by host (#852), for the Time page. */
  readonly time = signal<Record<string, TimeHistory>>({});

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

  /** Events ▸ Waiting now's ✕ (#541): the wait ends and nothing starts the agent again for it. */
  async cancelWait(host: string, agentID: string): Promise<void> {
    const waiting = await this.act("events/cancelWait", { agentID: agentID as UUID }, host);
    const held = this.events.value[host];
    if (waiting && held) this.events.value = { ...this.events.value, [host]: { ...held, waiting } };
    await this.loadEvents(host);
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

  /** A host too old to know the method leaves the charts out. */
  async loadUsage(host: string): Promise<void> {
    const history = await this.link.call("usage/history", {}, host).catch(() => null);
    if (history) this.usage.value = { ...this.usage.value, [host]: history };
  }

  /** A host too old to know the method leaves the Time page loading. */
  async loadTime(host: string): Promise<void> {
    const history = await this.link.call("time/history", {}, host).catch(() => null);
    if (history) this.time.value = { ...this.time.value, [host]: history };
  }
}
