// What the page holds and what each notification means: the Store class, in slices under ./store (#5384).
import { sendPreferencesWith } from "./preferences";
import { computed, signal, type ReadonlySignal } from "@preact/signals";
import type { BrowserFrame, ControlMachine, JSONValue, RuntimeAccount, RuntimeStatus, UUID, AutoMappings, AutoSettings, BusEvent, CostState, ListRequest, SandboxChoice, PolicySetBy, RuntimeAllowances, MachineJoinStatus, KeptDelivered, KeptList, UsageHistory, TimeHistory, VelocityHistory, CapReached, ChannelLinkDecided, ChannelLinkRequest, ConnectReport, JoinDecided, JoinRequest, SecretsLeft, SignInDecided, PolicyView, SignInRequest, CatalogRequest, BudgetRequest, ClientPermissionSettings, LineageNode, LineageSessionIssue, PlaneMoveReport, WebRemoteStatus } from "../protocol/generated";
import { type Link } from "../wire/link";
import type { FolderGoneAsk } from "./missingFolder";
import { describe } from "./errors";
import { addCap } from "./teamGroups";
import { withGovernanceRequest } from "./governance";
import { withBudgetRequest } from "./console";
import { type EnvelopeFilter } from "./eventBus";
import { Drafts } from "./drafts";
import { WatchCounts } from "./fileWatch";
import { Capability } from "../protocol/capabilities.generated";
import { withJoin, withoutJoin } from "./people";
import { withRequest, withoutRequest } from "./channelLinks";
import { withSignIn, withoutSignIn } from "./signIn";
import { Providers } from "./providers";
import { MachineLock } from "./machineLock";
import { failureLine } from "./pendingWrites";
import { type TranscriptCopy } from "./localCopy";
import { markOnce } from "./marks";
import { type AgentAct, type RuntimeSignInTarget } from "./store/shared";
import { mixin } from "./store/mixin";
import { Work } from "./store/work";
import { userScopeMethods } from "./store/userScope";
import { controlPlaneMethods } from "./store/controlPlane";
import { hostLifecycleMethods } from "./store/hostLifecycle";
import { sessionSearchMethods } from "./store/sessionSearch";
import { chatLoadingMethods } from "./store/chatLoading";
import { machineBackupsMethods } from "./store/machineBackups";
import { machinesMethods } from "./store/machines";
import { agentActionsMethods } from "./store/agentActions";
import { approvalsMethods } from "./store/approvals";
import { runtimesAccountsMethods } from "./store/runtimesAccounts";
import { promptingMethods } from "./store/prompting";
import { pinsRequestsMethods } from "./store/pinsRequests";
import { agentSettingsMethods } from "./store/agentSettings";
import { eventsMethods } from "./store/events";

export * from "./store/shared";
export { Work } from "./store/work";
export { folderKey } from "./groups";

/** The reducer, fed by the link: everything loaded on each connection, then kept by notifications. */
export class Store extends Work {
  /** The control plane's workspace providers (#1808), for Settings ▸ Control plane. */
  readonly providers: Providers;

  /** This browser in its person's machine lock, and the devices that ask to join it (#3490). */
  readonly machineLock: MachineLock;

  /** The server runtime being signed in (#3349), drawn at the page's root and not modal (#5203):
   * a sign-in waits on another tab for minutes, and the person works on meanwhile. */
  readonly runtimeSignIn = signal<RuntimeSignInTarget | null>(null);

  /** A machine Add as Machine… installed is linked to its workspace once it joins (#3365). */
  override takeHosts(hosts: ControlMachine[], now = Date.now()): void {
    super.takeHosts(hosts, now);
    this.providers.linkJoined(hosts);
  }

  constructor(readonly link: Link) {
    super();
    // The person's display choices are kept on their Mac (#1033).
    // A change that did not go is put back and said (#4814), never swallowed.
    sendPreferencesWith(
      (changes) => this.link.call("preferences/set", changes as Record<string, JSONValue>, this.macHostID.peek()),
      (error) => this.say(failureLine("save the setting", describe(error))));
    this.providers = new Providers(link);
    this.machineLock = new MachineLock({
      call: (method, params) => link.call(method as never, params as never),
      keyRecord: () => link.keyRecord(),
      lockKey: () => link.lockKey(),
      saveLockKey: (pair) => link.saveLockKey(pair),
    }, undefined, (error) => this.say(describe(error)));
    // A test's fake link has none.
    link.setLock?.(() => this.machineLock.signer());
    link.onNotification((method, params, host) => {
      // A browser frame is acked as it lands (#3528): the host sends the next only then, so a
      // slow link gets fewer frames, not a backlog.
      if (method === "browser/frame" && host) {
        void link.call("browser/ack", { ack: (params as BrowserFrame).ack }, host).catch(() => {});
      }
      if (method === "control/providersChanged") {
        this.providers.take(params);
        return;
      }
      if (method === "control/installProgress") {
        // A join from the Machines group says its step on its row (#4978).
        this.heardInstallStep(params as { name?: string; step?: string } | null);
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
      if (method === "control/budgetRequested") {
        const request = params as BudgetRequest | null;
        if (request?.id && this.people.value?.admin) this.budgetRequests.value = withBudgetRequest(this.budgetRequests.value, request);
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
      if (method === "control/lockChanged" || method === "control/lockJoinRequested" || method === "control/lockJoinDecided") {
        if (this.planeHas(Capability.lockJoin1)) this.machineLock.notify(method, params);
        // A machine just added to the lock may now be sealed to (#3491, D8).
        if (method === "control/lockChanged") void this.sealWaiting();
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
      if (method === "control/clientChanged") {
        this.clientChanges.value += 1;
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
      if (method === "control/lineageChanged") {
        this.lineageChanges.value += 1;
        return;
      }
      if (method === "control/groupsChanged") {
        // Settings ▸ Groups, and each provider's group's name (#1761).
        void this.providers.loadGroups().then(() => { this.keepCapsTrue(); this.peopleChanges.value += 1; });
        return;
      }
      if (method === "policy/effectiveChanged") {
        this.policyChanges.value += 1;
        return;
      }
      if (method === "control/orgRoutesChanged") {
        this.orgRoutesChanges.value += 1;
        return;
      }
      if (method === "control/sealingWanted") {
        void this.sealWaiting();
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
      if (method === "control/planeMoveReported") {
        this.planeMoveReport.value = (params as PlaneMoveReport | null) ?? null;
        return;
      }
      if (method === "control/connectReported") {
        this.connectReport.value = (params as ConnectReport | null) ?? null;
        return;
      }
      if (method === "control/webChanged") {
        const plane = this.plane.value;
        if (plane) this.plane.value = { ...plane, web: (params as WebRemoteStatus | null) ?? undefined };
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
      if (state.kind === "open") {
        markOnce("connected");
        void this.load().then(() => this.sealWaiting());
      }
    });
  }

  /** One load of a host at a time: `load` and `reloadHost` queue here rather than running together (#291). */
  hostChain = new Map<string, Promise<void>>();

  /** What is running, by host or "*" for everything, and whether it was asked for again meanwhile. */
  running = new Map<string, { done: Promise<void>; again: boolean }>();

  settling = new Map<string, ReturnType<typeof setTimeout>>();

  /** The folders whose archived sessions are on screen: the limit each view asked for, and the
   *  most listed since this connection opened. The sidebar's fold and the Archive page each hold
   *  one, so the one closing first does not take the other's rows (#2731). */
  archivedHolds = new Map<string, { limits: number[]; listed: number }>();

  /** The search's words, trimmed; empty when there is none. */
  searchWords = "";

  /** Bumped by each search: a reply for words no longer asked is dropped. */
  searchTurn = 0;

  /** Archived sessions a search brought in, by host, let go when the search ends or changes. */
  searched = new Map<string, Set<string>>();

  /** The next page of matches, for each host whose last page was full (#176, #193). */
  readonly searchNext = signal<Record<string, ListRequest>>({});

  /** While the sidebar searches: the line each session said that matches, by its id (#1585). */
  readonly saidLines = signal<Record<string, string>>({});

  /** While the sidebar searches for #<n>: the issue each session on it is on, by its id (lineage/sessions, #3899). */
  readonly issueSessions = signal<Record<string, LineageNode>>({});

  /** While the sidebar searches for #<n>: the issue, then its sub-issues in the epic's order, from each
   *  host that said them, each once (#3900). More than one is an epic, whose sessions the sidebar groups. */
  readonly issueHeadings = signal<LineageSessionIssue[]>([]);

  /** A lead's epic progress, "5/7", by host and session id (#3270), for its sidebar row. */
  readonly leadProgress = signal<Record<string, string>>({});

  /** The state and labels each lead was last asked at: asked again when they change, as a lead wakes for each child. */
  readonly leadAsked = new Map<string, string>();

  /** This device's copy of a chat (#4790), set by `startLocalCopy`: read before a chat with nothing held is asked for. */
  readCopy: ((session: string) => Promise<TranscriptCopy | null | undefined>) | undefined;

  /** Chats fetched before they are opened (#4795): in memory only, the newest few, for a minute. */
  prefetched = new Map<string, TranscriptCopy>();

  prefetching = new Set<string>();

  /** An entry its host sent as a stub, read from among its neighbours (#203). */
  override oversized(host: string, agentID: string, entryID: string, index: number | undefined): void {
    const around = index === undefined ? { limit: 50 } : { before: index + 4, limit: 8 };
    void this.link.call("agents/transcript", { agentID: agentID as never, ...around }, host)
      .then((page) => {
        const entry = page.entries.find((e) => e.id === entryID);
        if (entry) this.fillOversized(entry, host, agentID);
      })
      .catch(() => {});
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

  readonly autoLoading = new Set<string>();

  /** Each host's mark while the organisation requires the sandbox (SandboxSettings.setBy, #998). */
  readonly sandboxSetBy = signal<Record<string, PolicySetBy>>({});

  /** The Mac-wide permission choice for Cursor, Grok and OpenCode (061). */
  readonly clientPermissions = signal<Record<string, ClientPermissionSettings>>({});

  readonly accounts = signal<Record<string, RuntimeAccount[]>>({});

  /** A choice made on a menu that the host hasn't confirmed, by agent then option. */
  readonly pendingOptions = signal<Record<string, Record<string, JSONValue>>>({});

  /** What is typed and attached, per session or per new-agent form, kept across a reload (#254). */
  readonly drafts = new Drafts(typeof localStorage === "undefined" ? undefined : localStorage);

  /** Whether this page may ask for Connect to Another… (#4257): its control plane is one that Agents runs on
   * this Mac (it reads the Mac host's join), it knows the method, and the person is an admin. */
  readonly canConnectAnother: ReadonlySignal<boolean> = computed(() =>
    this.planeHas(Capability.controlConnectAnother1) && !!this.plane.value?.thisMacHost && this.person.value?.role === "admin");

  /** Whether this page may restart its control plane and serve it or not (#4252): Agents runs it on this Mac and
   * starts it again, it knows the methods, and the person is an admin. */
  readonly canControlThisMac: ReadonlySignal<boolean> = computed(() =>
    this.planeHas(Capability.controlLocal1) && !!this.plane.value?.restartable && this.person.value?.role === "admin");

  /** Move to Another Machine… and Run It Here Again… (#4255): there is a window on a Mac to do them, and the person
   * is an admin. */
  readonly canMovePlane: ReadonlySignal<boolean> = computed(() =>
    this.planeHas(Capability.controlPlaneMove1) && this.person.value?.role === "admin"
    && !!this.planeMoveReport.value && (this.planeMoveReport.value.rows.length > 0 || !!this.planeMoveReport.value.flow));

  /** A send refused because the agent's folder has gone (#119), until a way on or Cancel. */
  readonly folderGone = signal<FolderGoneAsk | null>(null);

  /**
   * What is on its way to each agent (#87; AgentsModel's acting): stop, archive, unarchive or
   * Send now, one at a time. Every control that would send a second sees the first is going.
   */
  readonly onItsWay = signal<Record<string, AgentAct>>({});

  /** Panes holding one folder watch. The host watches the agent's folder, so two paths inside it are one watch. */
  fileWatches = new WatchCounts();

  /** The root each watch was given, newest last, so leaving releases that one if the agent's folder has since moved. */
  watchedRoot = new Map<string, string[]>();

  settingsInFlight = new Map<string, Promise<unknown>>();

  /** When this page last asked to warm each session, and why (#183). */
  readonly prewarmed = new Map<string, number>();

  /** The session whose title is being edited (#751), and whether in the chat's header or its row. */
  readonly renaming = signal<{ id: string; inChat: boolean } | null>(null);

  /** One start's id per folder, kept until that start succeeds, so a retry is not a second agent (#291). */
  startRequests = new Map<string, UUID>();

  /** Each host's day of spending and its limits, for Spending (#151). */
  readonly costs = signal<Record<string, CostState>>({});

  /** Each host's use by hour and by day (#823), for the charts on Cost. */
  readonly usage = signal<Record<string, UsageHistory>>({});

  /** Where the time of running chats went, by host (#852), for the Time page. */
  readonly time = signal<Record<string, TimeHistory>>({});

  /** Each host's velocity/history (#4598): the PRs that landed, by hour and day, by repository. */
  readonly velocity = signal<Record<string, VelocityHistory>>({});

  /**
   * The person's bus log (#4732): every machine's events, newest first, for the rows no host here
   * has. Null until read, and on a control plane too old for it. `filter` is what it was read for.
   */
  readonly busLog = signal<{ events: BusEvent[]; next?: string; filter: EnvelopeFilter; at: number } | null>(null);
}

export interface Store extends S0, S1, S2, S3, S4, S5, S6, S7, S8, S9, S10, S11, S12, S13 {}
type S0 = typeof userScopeMethods;
type S1 = typeof controlPlaneMethods;
type S2 = typeof hostLifecycleMethods;
type S3 = typeof sessionSearchMethods;
type S4 = typeof chatLoadingMethods;
type S5 = typeof machineBackupsMethods;
type S6 = typeof machinesMethods;
type S7 = typeof agentActionsMethods;
type S8 = typeof approvalsMethods;
type S9 = typeof runtimesAccountsMethods;
type S10 = typeof promptingMethods;
type S11 = typeof pinsRequestsMethods;
type S12 = typeof agentSettingsMethods;
type S13 = typeof eventsMethods;

mixin(Store, userScopeMethods, controlPlaneMethods, hostLifecycleMethods, sessionSearchMethods, chatLoadingMethods, machineBackupsMethods, machinesMethods, agentActionsMethods, approvalsMethods, runtimesAccountsMethods, promptingMethods, pinsRequestsMethods, agentSettingsMethods, eventsMethods);
