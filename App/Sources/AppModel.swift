import AgentsKitCore
import Foundation
import Observation
import os

/// The window's state, which is a view of the daemon's and never a copy of it.
///
/// Everything here either came from the daemon or is on its way to it. Nothing about an
/// agent is decided in this process, which is what makes two windows agree and makes
/// reconnecting after a crash the same three steps as opening for the first time:
/// connect, list, subscribe.
@MainActor
@Observable
final class AppModel {
    /// The work, as any client sees it: the agents, the folders, the questions
    /// waiting, and the page of transcript being read.
    ///
    /// Held rather than copied, and shared with the phone. What each notification does
    /// to it is written once, in `AgentsKitCore`, because two clients that disagreed
    /// about what `agent/permission` with no request means would be two clients that
    /// disagree about whether the user has already answered.
    ///
    /// Everything below this line is about the window: what it is showing, what it has
    /// half typed, and what it has cost since it opened. None of that is the daemon's
    /// and none of it is the phone's.
    let work = AgentsModel()

    private(set) var runtimes: [RuntimeStatus] = []
    /// The start-up sheet offering to install what is missing (048). Raised once per
    /// launch, and only for a runtime not already offered on this root.
    var isOfferingInstall = false
    var hasWeighedInstallOffer = false
    /// The Get started card (#982): nil until weighed at this launch's first full lists,
    /// then kept on this root. See `AppModel+GetStarted`.
    var getStartedCard: GetStarted.Card? = GetStartedStore.kept
    /// An agent has run a turn on this root, once seen: archived agents are not listed,
    /// and the step stays ticked when the first one is archived.
    var hasSeenAgentRun = GetStartedStore.ranAgent
    /// The milestones this window has shown a card for (#984); nil before its first look
    /// on this root. See `AppModel+Milestones`.
    var milestonesSeen: Set<String>? = MilestonesSeenStore.seen
    /// What each runtime last said about itself: signed in or not, what it takes in a
    /// prompt, which provider is answering.
    private(set) var accounts: [String: RuntimeAccount] = [:]
    /// The accounts added to this Mac's runtimes (#840), beside each runtime's own sign-in.
    private(set) var accountProfiles: [AccountProfile] = [] {
        didSet { accountProfilesRead = true }
    }
    /// Whether the host has listed its accounts yet: until then no session is told its account is gone.
    private(set) var accountProfilesRead = false
    /// What the terminals the daemon is running for an agent have printed so far. The
    /// kit's, so a phone shows the same (033).
    var terminalOutput: [String: String] { work.terminalOutput }
    private(set) var isConnected = false
    /// Whether the daemon's list of folders has arrived at least once. Until it has,
    /// an empty sidebar means "not yet", not "none".
    private(set) var hasLoadedFolders = false
    /// The same for the live agents: until they have come, no agent has not run yet.
    private(set) var hasLoadedAgents = false
    /// 021: the Mac's banner, and the window's report of where the person is. Neither
    /// decides anything; the daemon routes and these two obey.
    private let notifier = MacNotifier()
    var presence: PresenceReporter?
    /// The loop going back for a lost daemon, while there is one.
    private var reconnecting: Task<Void, Never>?
    /// One connect at a time. `attempt` can call `connect` while the reconnect loop's
    /// own is still opening, and the first connection was left open (#285).
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var connectGeneration = 0
    /// Its wait, and the control plane watch's, both cut short by a wake or a network
    /// change (#82).
    @ObservationIgnored private let backoff = Backoff()
    /// When this window last asked each session's host to warm it, and why (#183).
    @ObservationIgnored private var prewarmed: [String: Date] = [:]
    /// The control plane's own client: from 2 s, doubling to a minute, not every 2 s for
    /// ever (#172).
    @ObservationIgnored private let controlBackoff = Backoff(first: .seconds(2), longest: .seconds(60))
    @ObservationIgnored private let wakeAndNetwork = WakeAndNetwork()
    @ObservationIgnored private var checkingAfterWake = false
    private(set) var problem: String?
    /// A send refused because the agent's folder has gone (#119), with the ways on. Said
    /// in the window's alert instead of `problem`, and the words stay in the bar.
    var folderGone: FolderGoneAsk?
    /// A runtime of this Mac's that refused for want of a sign-in: the window answers
    /// with its sign-in sheet rather than an error nobody can act on.
    var signInRuntimeID: String?
    /// Sheets put away without signing in, so that the agents a restart picks back up
    /// do not each raise it again. Forgotten when the runtime says it is signed in.
    private var signInsPutAway: Set<String> = []
    /// Clones under way on this Mac, from whichever window started them (027). Each is
    /// a row in the Folders column until it becomes a folder or fails.
    private(set) var clones: [DaemonAPI.CloneSummary] = []

    // What the window reads, which is the shared model under another name. Forwarded
    // rather than mirrored: a copy is a thing that can fall behind.
    var agents: [Agent] { work.agents }
    var folders: [DaemonAPI.FolderSummary] { work.folders }
    var permissions: [PermissionRequest] { work.permissions }
    var elicitations: [ElicitationRequest] { work.elicitations }
    var entries: [TranscriptEntry] { work.entries }
    var transcriptItems: [TranscriptItem] { work.transcriptItems }
    var filesToShow: [UUID: ShownFile] { work.filesToShow }
    var chartHints: [String: ChartHint] { work.chartHints }
    /// What the reader will allow and what today has cost. Nil until the daemon has
    /// said, which is how every surface knows to show nothing rather than a zero.
    var costState: DaemonAPI.CostState? { work.costState }
    /// Every resource an agent can lease and who holds it (036).
    var leases: DaemonAPI.LeaseSnapshot? { work.leases }
    var hostedMCP: DaemonAPI.HostedMCPSnapshot? { work.hostedMCP }
    var costLimits: CostLimits { work.costState?.limits ?? CostLimits() }
    /// How long archived agents are kept (051). Nil until the daemon has said.
    var retentionState: DaemonAPI.RetentionState? { work.retentionState }
    var runtimeAllowances: RuntimeAllowances? { work.runtimeAllowances }
    /// Cursor and Grok permission mode (061). Defaults until the daemon answers.
    private(set) var clientPermissions = ClientPermissionSettings()
    /// What agents call the person (#121), as this Mac keeps it; nil until it is read,
    /// so a server is never told a blank before the Mac's own answer is in.
    private(set) var person: PersonSettings?
    /// Each runtime's command sandbox default (064).
    private(set) var sandboxSettings = SandboxSettings()
    /// The organisation's policy as this Mac's host follows it (#998): the red strip and the
    /// composer's reason while the kill switch is on. Nil from a host without a policy capability.
    private(set) var policyState: DaemonAPI.PolicyState?
    /// The person's own pass-through names, each marked when the policy refuses it (#998).
    private(set) var passThrough = DaemonAPI.PassThroughState()

    /// Why the Mac is, or is not, being kept awake (024). Nil until the daemon has
    /// said — and for ever against one too old to know the method, which is drawn the
    /// same way as nothing to say.
    var wakeState: DaemonAPI.WakeState? { work.wakeState }
    /// What this Mac's host could not read in this run (#205), said at the sidebar's foot.
    var storeNotes: [String] { work.storeNotes }
    /// The switch and the hours (Settings ▸ Machines ▸ This Mac ▸ Sleep). Nil until the daemon has
    /// said, including a daemon too old to know the method.
    private(set) var wakeSettings: WakeSettings?
    /// How this Mac's host updates Agents Host by itself (#2178). Nil from a host that
    /// cannot (a test's, or one older than the method), and Settings draws nothing for it.
    private(set) var selfUpdate: DaemonAPI.SelfUpdate?
    /// How many workflows turned on may run in each folder (#506): the Mac's,
    /// copied to every server.
    private(set) var workflowLimit: WorkflowLimitSettings?

    /// Which folder this window is looking at.
    ///
    /// Kept here and in `WindowDefaults` rather than in the daemon: the daemon owns what
    /// is true about the work, and which of it somebody happens to be reading is not
    /// that. It is also what keeps two windows independent.
    var selectedFolder: URL? {
        didSet {
            guard selectedFolder != oldValue else { return }
            WindowDefaults.store.set(selectedFolderKey?.stored, forKey: Self.selectedFolderDefault)
            // Picking a folder shows the folder, not a conversation, and not a
            // workflow either. Both are things you go into from here, and come back
            // out of.
            selection = nil
            openWorkflow = nil
            openPin = nil
            folderPage = nil
            composing = false
        }
    }

    static let selectedFolderDefault = "selectedFolderPath"

    /// Which machine the selected folder is on (037). Set with it, by `select`, never
    /// on its own: a folder names a folder only together with its host.
    private(set) var selectedFolderHost: MachineRef = .mac

    /// The selected folder as the window identifies folders now that a server can
    /// have the same path as this Mac.
    var selectedFolderKey: FolderKey? {
        selectedFolder.map { FolderKey(host: selectedFolderHost, folder: $0) }
    }

    /// Whether the window is showing Spending rather than a folder.
    ///
    /// Not persisted, unlike the selected folder. Spending is somewhere you go to
    /// answer a question — what has this cost — and a window that reopens on the bill
    /// rather than on the work would be answering a question nobody asked twice.
    var showsSpending = false {
        didSet {
            guard showsSpending, showsSpending != oldValue else { return }
            showsResources = false
            showsEvents = false
            showsRuntimes = false
            showsMCPServers = false
            showsTime = false
            showsMilestones = false
            showsTokens = false
            showsWorktrees = false
            // The same rule as picking a folder: what you picked is what you see,
            // and a conversation or a workflow left open underneath would be waiting
            // to reappear when the bill is closed, which is a place nobody chose to
            // come back to.
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// Whether the window is showing Resources: who holds the Mac's shared things
    /// and who is waiting (036). A page like Spending, and not persisted for the same
    /// reason: it is somewhere you go to answer a question.
    var showsResources = false {
        didSet {
            guard showsResources, showsResources != oldValue else { return }
            showsSpending = false
            showsEvents = false
            showsRuntimes = false
            showsMCPServers = false
            showsTime = false
            showsMilestones = false
            showsTokens = false
            showsWorktrees = false
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// Whether the window is showing Events: what happened, what came of it, and who
    /// is waiting (042). A page like Resources, and not persisted for the same reason.
    var showsEvents = false {
        didSet {
            guard showsEvents, showsEvents != oldValue else { return }
            showsSpending = false
            showsResources = false
            showsRuntimes = false
            showsMCPServers = false
            showsTime = false
            showsMilestones = false
            showsTokens = false
            showsWorktrees = false
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// Whether the window is showing Runtimes: each runtime and where its allowance
    /// stands (065). A page like Events, and not persisted for the same reason.
    ///
    /// It used to be in Settings, which is where a control belongs. What it says is
    /// the state of the machine, and it changes without anybody touching a setting.
    var showsRuntimes = false {
        didSet {
            guard showsRuntimes, showsRuntimes != oldValue else { return }
            showsSpending = false
            showsResources = false
            showsEvents = false
            showsMCPServers = false
            showsTime = false
            showsMilestones = false
            showsTokens = false
            showsWorktrees = false
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// Whether the window is showing MCP Servers: the servers this Mac runs once for
    /// every agent, and why each last stopped (#488, #589). A page like Runtimes, and not
    /// persisted for the same reason.
    var showsMCPServers = false {
        didSet {
            guard showsMCPServers, showsMCPServers != oldValue else { return }
            showsSpending = false
            showsResources = false
            showsEvents = false
            showsRuntimes = false
            showsTime = false
            showsMilestones = false
            showsTokens = false
            showsWorktrees = false
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// Whether the window is showing Time: where the time of running chats went (#852). A
    /// page like Cost, and not persisted for the same reason.
    var showsTime = false {
        didSet {
            guard showsTime, showsTime != oldValue else { return }
            showsSpending = false
            showsResources = false
            showsEvents = false
            showsRuntimes = false
            showsMCPServers = false
            showsMilestones = false
            showsTokens = false
            showsWorktrees = false
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// Whether the window is showing Milestones: the first steps taken, and the ones still to
    /// take (#1067). A page like Time, and not persisted for the same reason.
    var showsMilestones = false {
        didSet {
            guard showsMilestones, showsMilestones != oldValue else { return }
            showsSpending = false
            showsResources = false
            showsEvents = false
            showsRuntimes = false
            showsMCPServers = false
            showsTime = false
            showsTokens = false
            showsWorktrees = false
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// Whether the window is showing Tokens: what the work used in tokens, and the token
    /// limits (#956). A page like Cost, and not persisted for the same reason.
    var showsTokens = false {
        didSet {
            guard showsTokens, showsTokens != oldValue else { return }
            showsSpending = false
            showsResources = false
            showsEvents = false
            showsRuntimes = false
            showsMCPServers = false
            showsTime = false
            showsMilestones = false
            showsWorktrees = false
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// Whether the window is showing Worktrees: every folder's, and how much each holds
    /// on disk (#790). A page like MCP Servers, and not persisted for the same reason; it
    /// was in Folder Settings, which are for what a person sets, not what changes.
    var showsWorktrees = false {
        didSet {
            guard showsWorktrees, showsWorktrees != oldValue else { return }
            showsSpending = false
            showsResources = false
            showsEvents = false
            showsRuntimes = false
            showsMCPServers = false
            showsTime = false
            showsMilestones = false
            showsTokens = false
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// The event a workflow row asked to be shown, or `waitingNow` for the strip a
    /// chat's waiting capsule asked for. Scrolled to, once.
    var eventsFocus: EventsFocus?

    enum EventsFocus: Equatable {
        case event(EventPosition)
        case waitingNow
    }

    /// Events, at one event or at Waiting now if something asked for it.
    func showEvents(at focus: EventsFocus? = nil) {
        eventsFocus = focus
        showsEvents = true
    }

    /// A workflow's page, from an event that fired or was refused by it.
    func showWorkflow(folder: URL, workflowID: String) {
        showFolder(FolderKey(folder: folder))
        openWorkflow = Folder.standardize(folder).path + "/" + workflowID
    }

    /// The resource a capsule in a chat asked to be shown. Scrolled to, once.
    var resourcesFocus: ResourceName?

    /// Resources, at one resource if a chat's capsule asked for it.
    func showResources(at name: ResourceName? = nil) {
        resourcesFocus = name
        showsResources = true
    }

    /// Runtimes, from the prompt bar's warning about starting on one that is out.
    func showRuntimes() {
        showsRuntimes = true
    }

    /// An agent's chat, from the Resources page or a capsule naming its holder: its
    /// own folder first, as a banner does, so the sidebar and the page agree.
    func openAgent(_ agentID: UUID) {
        showsSpending = false
        showsResources = false
        showsEvents = false
        showsRuntimes = false
        showsMCPServers = false
        showsTime = false
        showsMilestones = false
        showsTokens = false
        showsWorktrees = false
        if let agent = agents.first(where: { $0.id == agentID }) {
            pendingOpen = nil
            select(FolderKey(host: agent.host, folder: agent.folderPath))
        } else {
            // Not listed yet (a banner tapped at launch): picking its folder when the
            // lists arrive would empty the selection, so it is opened again then (#1055).
            pendingOpen = .agent(agentID)
        }
        openWorkflow = nil
        selection = agentID
    }

    /// A folder's own page, from a banner with no session behind it (#531): where a
    /// change git brought to its files is asked.
    func openFolder(_ key: FolderKey) {
        showsSpending = false
        showsResources = false
        showsEvents = false
        showsRuntimes = false
        showsMCPServers = false
        showsTime = false
        showsMilestones = false
        showsTokens = false
        showsWorktrees = false
        // Not listed yet: settling the selection would pick another, so it waits (#1055).
        pendingOpen = liveFolders.contains { $0.key == key } ? nil : .folder(key)
        select(key)
        openWorkflow = nil
        folderPage = nil
        selection = nil
    }

    /// What a banner asked for before the agents and folders it names were listed, as
    /// the Remote keeps a tapped need (#1045). Opened once they are; anything picked in
    /// the sidebar first drops it.
    private enum PendingOpen { case agent(UUID), folder(FolderKey) }
    @ObservationIgnored private var pendingOpen: PendingOpen?

    private func openPending() {
        switch pendingOpen {
        case .agent(let id) where agents.contains { $0.id == id }:
            openAgent(id)
        case .folder(let key) where liveFolders.contains { $0.key == key }:
            openFolder(key)
        default:
            break
        }
    }

    /// What is picked in the sidebar, as one value.
    ///
    /// Activity, the folders and their sessions and workflows share one list (#145), so
    /// they have to share a selection: two bindings would let both look picked at once.
    /// `selectedFolder` stays the stored fact — it is what New Session starts in — and
    /// this is the view of it the list is driven by. A folder's new session lights its
    /// folder's row, since that is where it will be.
    var sidebarItem: SidebarItem? {
        get {
            if showsEvents { return .events }
            if showsResources { return .resources }
            if showsRuntimes { return .runtimes }
            if showsMCPServers { return .mcpServers }
            if showsWorktrees { return .worktrees }
            if showsSpending { return .spending }
            if showsTokens { return .tokens }
            if showsTime { return .time }
            if showsMilestones { return .milestones }
            guard let key = selectedFolderKey else { return nil }
            if let id = openWorkflow { return .workflow(id, in: key) }
            if case .review(let id)? = folderPage { return .review(id, in: key) }
            if folderPage == .archive { return .archive(key) }
            if folderPage == .mcpServers { return .folderMCPServers(key) }
            if let openPin { return .pin(openPin, in: key) }
            if let selection { return .session(selection) }
            return composing ? .folder(key) : nil
        }
        set {
            // The person's own pick wins over a banner still waiting for its lists.
            if newValue != nil { pendingOpen = nil }
            switch newValue {
            case .session(let id):
                openAgent(id)
            case .workflow(let id, let key):
                showsSpending = false
                showsResources = false
                showsEvents = false
                showsRuntimes = false
                showsMCPServers = false
                showsTime = false
                showsMilestones = false
                showsTokens = false
                showsWorktrees = false
                select(key)
                openWorkflow = id
            case .pin(let path, let key):
                showPin(path, in: key)
            case .archive(let key):
                showFolderPage(.archive, of: key)
            case .folderMCPServers(let key):
                showFolderPage(.mcpServers, of: key)
            case .review(let id, let key):
                showFolderPage(.review(id), of: key)
            case .spending:
                showsSpending = true
            case .tokens:
                showsTokens = true
            case .time:
                showsTime = true
            case .milestones:
                showsMilestones = true
            case .resources:
                showResources()
            case .events:
                showEvents()
            case .runtimes:
                showRuntimes()
            case .mcpServers:
                showsMCPServers = true
            case .worktrees:
                showsWorktrees = true
            case .folder(let key):
                showsSpending = false
                showsResources = false
                showsEvents = false
                showsRuntimes = false
                showsMCPServers = false
                showsTime = false
                showsMilestones = false
                showsTokens = false
                showsWorktrees = false
                showFolder(key)
            case nil:
                // A list that clears its own selection — which macOS does while rows
                // come and go — must not empty the detail column. Nothing is picked
                // is not a thing this window can show.
                break
            }
        }
    }

    /// A folder's workflows or its archive, from its row in the sidebar (#495).
    func showFolderPage(_ page: FolderPage, of key: FolderKey) {
        showsSpending = false
        showsResources = false
        showsEvents = false
        showsRuntimes = false
        showsMCPServers = false
        showsTime = false
        showsMilestones = false
        showsTokens = false
        showsWorktrees = false
        select(key)
        folderPage = page
    }

    /// Go to a folder's page, whether or not it was already the selected one.
    ///
    /// `selectedFolder`'s `didSet` says the rule — picking a folder shows the
    /// folder, not a conversation — but it can only fire on a change, and macOS drives
    /// a `List` selection binding from a selection-*changed* notification. Clicking the
    /// row that is already highlighted never calls the setter at all. From inside a
    /// conversation the highlighted row is that conversation's own folder, so the one
    /// click a person would make to go back up was the one the framework discarded.
    ///
    /// This is that rule as something callable. It touches no agent: `selection` only
    /// decides which transcript this window is watching, and the turn belongs to the
    /// daemon.
    func showFolder(_ key: FolderKey) {
        // Going to a folder is going away from Spending, wherever the ask came from
        // — a new folder being added, a menu item, its New session row. And from
        // Resources, for the same reason.
        showsSpending = false
        showsResources = false
        showsEvents = false
        showsRuntimes = false
        showsMCPServers = false
        showsTime = false
        showsMilestones = false
        showsTokens = false
        showsWorktrees = false
        select(key)
        // A new session in it (#366): the folder's own page is where a session starts,
        // as New Session has it. The folder's row in the sidebar only folds (#375).
        composing = true
        // The next New Session starts here too (#495).
        rememberNewSessionFolder(key)
        draftWorktree = nil
    }

    /// The folder New Session at the top of the sidebar starts in (#495, #2160):
    /// `NewSessionFolder`, the Remote's rule too.
    var newSessionFolder: FolderKey? {
        NewSessionFolder.choose(live: liveFolders.map(\.key), remembered: rememberedNewSessionFolder,
                                 selected: selectedFolderKey)?.key
    }

    private var rememberedNewSessionFolder: FolderKey? =
        WindowDefaults.store.string(forKey: AppModel.newSessionFolderDefault).flatMap(FolderKey.init(stored:))

    static let newSessionFolderDefault = "newSessionFolder"

    private func rememberNewSessionFolder(_ key: FolderKey) {
        guard rememberedNewSessionFolder != key else { return }
        rememberedNewSessionFolder = key
        WindowDefaults.store.set(key.stored, forKey: Self.newSessionFolderDefault)
    }

    /// A new session in the selected folder: the empty chat with its prompt, where a
    /// session starts (066). A sibling of `selection`, exclusive with the others.
    var composing = false {
        didSet {
            guard composing, !oldValue else { return }
            selection = nil
            openWorkflow = nil
            openPin = nil
            folderPage = nil
        }
    }

    /// Nothing picked: the help text, not a page (#145). The folder stays selected, so
    /// New Session still knows where to start.
    func showNothing() {
        selection = nil
        openWorkflow = nil
        openPin = nil
        folderPage = nil
        composing = false
    }

    /// Pick a folder on a host. The host goes first, so the folder's `didSet` stores
    /// and compares the pair rather than a folder paired with the last host (037).
    func select(_ key: FolderKey?) {
        let timing = Perf.begin("folder-switch")
        defer { Perf.endWhenDrawn(timing) }
        if let key, key.host != selectedFolderHost {
            selectedFolderHost = key.host
            // The same folder on another host is another folder.
            if selectedFolder == key.folder { selectedFolder = nil }
        }
        selectedFolder = key?.folder
    }

    /// Bumped when something asks the conversation to go to its end.
    ///
    /// A counter rather than a flag, so two asks in a row both land. The end of a
    /// transcript is not an entry, which is why this is not `focusedEntry`.
    private(set) var scrollToEndToken = 0

    /// The sessions open in windows of their own (#826), each with its own page of its
    /// transcript. See `AppModel+Popouts`.
    var popouts: [UUID: PoppedChat] = [:]
    /// The one of them in the key window, if one is: what the person is watching.
    @ObservationIgnored var popoutInFront: UUID?
    /// The folders open in windows of their own (#1089), each with what it shows.
    var folderWindows: [FolderKey: FolderWindowState] = [:]
    /// The folder whose window's prompt the draft is for, while one is (#1089): there is
    /// one draft, and it follows the window last composing in.
    var composingWindow: FolderKey?
    /// Brings a folder's window forward, or opens it: the scene's own action, handed
    /// over by the first window to draw, for what is not a view (a notification).
    @ObservationIgnored var openFolderWindow: ((FolderKey) -> Void)?

    func scrollToEnd() { scrollToEndToken += 1 }

    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            // Which conversation is being read is what decides whether an arriving
            // transcript entry is ours to keep, so the shared model is told first.
            work.watching = selection
            presence?.watching(selection)
            // Opened from Unread, it stays there until something else is opened (#495),
            // as a read message stays in Mail's Unread mailbox while it is selected.
            keptInUnread = selection.flatMap { work.agent($0) }.flatMap { $0.showsUnread ? $0.id : nil }
            // A session picked is the session shown, not a workflow left open over it.
            if selection != nil {
                openWorkflow = nil
                openPin = nil
                folderPage = nil
                composing = false
            }
            if let left = chatOpening { Perf.end(left.timing, "left before it opened") }
            chatOpening = selection.map { (agent: $0, timing: Perf.begin("chat-open")) }
            Task { await loadTranscript() }
        }
    }

    /// The selection once it has been looked for, as `PoppedChat.looked` and the Remote's:
    /// from then a selected session not in hand is one that has gone (#2748).
    private(set) var lookedForSelection: UUID?

    /// The session opened while it was unread, kept in the sidebar's Unread until another
    /// is opened (#495), so it does not leave the list under the pointer on the click.
    private(set) var keptInUnread: UUID?

    /// The agent this window just started, until its chat is opened. A new chat starts
    /// with the sidebar shut, whatever the last one had open (#358).
    @ObservationIgnored var justStarted: UUID?

    /// The session whose title is being edited (#751): in its sidebar row, from the row's
    /// menu or Return, or in the toolbar, from Rename… there or in the Session menu.
    var renaming: Renaming?

    /// The chat being opened and since when, until its transcript is on screen (073).
    @ObservationIgnored private var chatOpening: (agent: UUID, timing: Perf.Interval)?

    /// Which workflow is open, if one is instead of a conversation.
    ///
    /// `selection`'s sibling rather than a widening of it. Making that field an enum
    /// of agent-or-workflow would have been the tidier model and the worse change:
    /// its `didSet` sets `work.watching` and reloads the transcript, and it is
    /// threaded through the view tree as a binding in some forty places, every one of
    /// which would have had to learn about a case it has nothing to say about. One
    /// more field costs one line. The two are exclusive, and `ContentView`'s `page`
    /// binding is the single place navigation sets either.
    var openWorkflow: Workflow.ID? {
        didSet {
            if openWorkflow != nil {
                openPin = nil
                folderPage = nil
                composing = false
            }
        }
    }

    /// A page about the selected folder's work (#495), open where the chat would be: its
    /// workflows, or what it has archived. A fourth sibling of `selection`, `openWorkflow`
    /// and `openPin`, so the sidebar's folder fold is one row for each and never a fold
    /// inside a fold.
    var folderPage: FolderPage? {
        didSet {
            guard folderPage != nil else { return }
            selection = nil
            openWorkflow = nil
            openPin = nil
            composing = false
        }
    }

    enum FolderPage: Equatable {
        case archive
        /// Its MCP servers and how each is doing (#753).
        case mcpServers
        /// A change waiting for an OK, by its `Approval.id` (#1472).
        case review(String)
    }

    /// The selected folder's pinned page (#159) open in the chat's place, by its path in
    /// the folder: a third sibling of `selection` and `openWorkflow`.
    var openPin: String? {
        didSet {
            guard openPin != nil else { return }
            selection = nil
            openWorkflow = nil
            folderPage = nil
            composing = false
        }
    }

    /// A folder's pinned page, from its row.
    func showPin(_ path: String, in key: FolderKey) {
        showsSpending = false
        showsResources = false
        showsEvents = false
        showsRuntimes = false
        showsMCPServers = false
        showsTime = false
        showsMilestones = false
        showsTokens = false
        showsWorktrees = false
        select(key)
        openPin = path
    }

    // What the prompt bar is holding before there is an agent to hold it. It lives
    // here rather than in the view so that starting an agent does not throw it away
    // half way through the bar moving down the pane.
    var draftCwd: URL? {
        didSet {
            guard draftCwd != oldValue else { return }
            // A worktree belongs to one repository, so a new folder is a new question.
            draftWorktree = nil
            draftWorktrees = .notARepository
            Task { await loadDraftWorktrees() }
            // A persona is a file in one folder, or the home's (#760).
            draftPersona = nil
            draftPersonas = []
            Task { await loadDraftPersonas() }
        }
    }
    var draftRuntimeID: String? {
        didSet {
            guard draftRuntimeID != oldValue else { return }
            draftAccountID = nil
            // An account signed in from a terminal since: its state under its name is today's.
            Task { await refreshAccountProfiles() }
        }
    }
    /// The account the next session uses (#840, #999), as `AccountChoices` keeps a choice:
    /// nil for the runtime's account for new sessions. Back to that whenever the runtime changes.
    var draftAccountID: String?
    var draftAccountChoices: AccountChoices? {
        guard draftHost == .mac, let runtimeID = draftRuntimeID else { return nil }
        return AccountChoices(runtimeID: runtimeID, profiles: accountProfiles, policy: policyState?.policy)
    }
    /// The kinds of session the draft folder offers (#760): the folder's personas and
    /// the home's, as the host lists them.
    private(set) var draftPersonas: [Persona] = []
    /// The one picked, by id, sent with the start so the agent gets its prompt.
    private(set) var draftPersona: String?
    /// A persona picked while its runtime's options were still to come: laid over them
    /// when they arrive.
    private var pendingPersona: Persona?
    /// Where in the folder the next agent works, when not the folder (030).
    /// Deliberately not kept with the rest of the form: a worktree is decided per
    /// agent, so it goes back to the folder after every start (FR-004).
    var draftWorktree: WorktreeChoice?
    /// What the draft folder's repository has, for the Worktree chooser. Not a
    /// repository until the daemon says otherwise, which keeps the chooser hidden.
    private(set) var draftWorktrees: DaemonAPI.WorktreesListResponse = .notARepository
    private var draftWorktreesGeneration = 0
    /// Each open agent's folder's worktrees, for the Worktree choice on its page (053).
    /// Asked when the page opens and after each move, never polled.
    private(set) var agentWorktrees: [URL: DaemonAPI.WorktreesListResponse] = [:]
    /// Why the last move asked for an agent was refused, shown under its choice until
    /// the next one. A move that fails later, when it is made, says so in the chat.
    private(set) var moveProblems: [UUID: String] = [:]
    private(set) var draftOptions: [ConfigOption] = []
    private(set) var draftCommands: [SlashCommand] = []
    var draftChosen: [String: JSONValue] = [:]
    /// The next agent's own sandbox choice (064). Nil follows its runtime's default.
    var draftSandbox: SandboxChoice? { didSet { draftSandboxRefusal = nil } }
    /// Why the last start of a new agent did not happen, when its sandbox is why (064):
    /// shown over the prompt with **Start without sandbox**.
    var draftSandboxRefusal: DaemonAPI.SandboxWillNotStart?
    /// A new agent is on its way to its host (#87): a worktree to make and a runtime to
    /// start can take seconds, and the bar shows it rather than nothing. One at a time,
    /// so a second Return is not a second agent.
    private(set) var isStarting = false
    /// Folders beyond the working one, and MCP servers, for the agent about to start.
    var draftFolders: [URL] = []
    var draftServers: [MCPServer] = []
    /// Words handed to a prompt bar from elsewhere on the page: Clean up worktrees' words,
    /// or a queued prompt's edit that came too late. Offered and then taken: the bar of that
    /// agent (#1679) puts them in the field and clears this, because the prompt itself is
    /// still the bar's own and sending it is still the person's move.
    var offeredPrompt: PromptOffer?
    /// Words quoted from a reply for that chat's prompt bar (#1553, #1679): added to what is
    /// there as a quote, then cleared.
    var offeredQuote: PromptOffer?
    /// A new agent a view filled in (#834), for the folder page's bar to take once its
    /// folder is this one: the prompt, the labels and the worktree. Starting it is still
    /// the person's move.
    var offeredStart: OfferedStart?
    private(set) var isLoadingDraftOptions = false
    /// Why the last fetch of a runtime's options failed, if it did.
    ///
    /// Its own thing rather than the global `problem` banner: the row under the prompt
    /// has to say this, and offer to try again, and a modal alert can be dismissed
    /// leaving the row looking like a runtime with nothing to adjust.
    private(set) var draftOptionsFailure: String?
    /// Which fetch is the current one.
    ///
    /// Changing the folder and then the runtime issues two calls, and without this the
    /// first to answer wins and is shown as settled while the right one is still in
    /// flight.
    private var draftOptionsGeneration = 0
    private var draftID: UUID?

    /// This Mac's host: directly over its local socket when it is there (#1118), else
    /// through the control plane (058). Set once more when first run chooses one.
    private var client = DaemonClient(link: UnreachableLink())
    /// The one connection to the control plane every host's client is carried on (058).
    private var controlLink: ControlLink? = ControlConfig.endpoint.flatMap(ControlConfig.link)

    init() {
        // On `controlLink` itself, not a link of its own (#445): a second connection that
        // nothing else knew of was never let go of, so a wedged one stayed for good.
        if let controlLink { client = DaemonClient(link: hostLink(.mac, through: controlLink)) }
        // From the start, not once connected: a banner tapped to launch the app arrives
        // before then, and was dropped (#1055).
        notifier.open = { [weak self] agentID in
            // In its folder's own window when one is open (#1089, Alex).
            if self?.showInFolderWindow(agentID) == true { return }
            // Its own folder first, because picking a folder empties the selection:
            // a chat opened from a banner under some other folder's heading is a
            // sidebar and a page that disagree about where you are.
            self?.openAgent(agentID)
        }
        notifier.openFolder = { [weak self] folder in self?.openFolder(FolderKey(host: .mac, folder: folder)) }
        notifier.answer = { [weak self] token, quick, typed in await self?.answerFromBanner(token, quick, typed: typed) }
        #if DEBUG
        openFromLaunchArguments()
        #endif
    }
    /// Every host the control plane has besides this Mac's, each with a client of its own
    /// over `controlLink` (058, US3): what `HostSet` is for servers reached by ssh from
    /// here, with the ssh on the control plane's side.
    @ObservationIgnored private var controlHosts: [MachineRef: DaemonClient] = [:]
    /// The control plane's own connection, as the watch made it: for Start on a strip (#691).
    @ObservationIgnored private(set) var controlRequests: DaemonClient?
    /// People (#994): the machines waiting for this person's approval, fed from the watch.
    let people = PeopleState()
    /// The GitHub sign-ins waiting for this person's Approve (#995).
    let signIn = SignInState()
    /// The settings and secrets that follow the person to their machines (#1760).
    let userScope = UserScopeState()
    /// Hosts whose Start was pressed here and not answered yet.
    private(set) var hostsBeingStarted: Set<MachineRef> = []
    /// Prompts and starts the control plane keeps for stopped workspaces (#691 US3), every host's.
    var kept: [DaemonAPI.KeptRequest] = []
    /// The kept starts the New Agent prompt has shown here: the one that reaches its host opens.
    @ObservationIgnored var keptStartsShown: Set<UUID> = []
    @ObservationIgnored private var controlWatch: Task<Void, Never>?
    /// Every host the control plane last listed, this Mac's included. Nil when the
    /// window is not its client; empty until the first list arrives (058, R11).
    private(set) var controlPlaneHosts: [DaemonAPI.ControlMachine]? = ControlConfig.endpoint == nil ? nil : []
    /// The control plane's list has arrived at least once, so an empty one means none.
    private var controlPlaneListed = false
    /// `control/status.thisMacHost` (#303): how this Mac's host says its join stands.
    /// Nil when that process is not writing one, or this plane is not beside it.
    private(set) var macHostJoin: DaemonAPI.MachineJoinStatus?
    /// `control/status.machineID`, so a missing host on this Mac is not a plane elsewhere.
    private var controlPlaneMachine: String?

    /// Whether this window has a host on this Mac (058, T093a). Always without a control
    /// plane, and until its first list arrives; after that, only if it lists `.mac`. A
    /// control plane of servers alone, the review demo's, has none, and nothing in the
    /// window waits on one or sends to one.
    var hasMacHost: Bool {
        guard let listed = controlPlaneHosts, controlPlaneListed else { return true }
        return listed.contains { $0.id == .mac }
    }

    /// Whether a host can do what `capability` names (#1748): its row's list. True when
    /// the host said no list, or the window is not a control plane's client.
    func host(_ host: MachineRef, has capability: String) -> Bool {
        controlPlaneHosts?.first { $0.id == host }?.has(capability) ?? true
    }

    /// Whether the host of an agent can do what `capability` names.
    func agent(_ id: UUID?, has capability: String) -> Bool {
        host(host(ofAgent: id), has: capability)
    }

    /// Where an agent lives: the host it was listed from, or, for one not yet listed
    /// (just started, say), the selected folder's host when there is no Mac host.
    private func host(ofAgent id: UUID?) -> MachineRef {
        work.agent(id)?.host ?? id.flatMap { folderShellHosts[$0] } ?? (hasMacHost ? .mac : selectedFolderHost)
    }
    /// The name `control/status` last gave, so the away strip can still say it.
    private(set) var controlPlaneName: String?
    /// The control plane's own client has answered. Distinct from `isConnected`, which
    /// is this Mac's host: a host can be offline while the control plane is up.
    private(set) var controlPlaneReachable = false
    /// A try to reach the control plane failed. Stays quiet during the first try.
    private(set) var controlPlaneMissed = false
    /// No control plane and nothing of the old way: the window asks how to work, and
    /// starts nothing until it is told (058, FR-017).
    private(set) var needsFirstRun = ControlConfig.needsFirstRun
    /// The servers (037). This Mac is `client`, as it always was.
    let hosts = HostSet(locations: .default)
    /// What this window may lend to servers (043). Never to this Mac's own daemon (D5).
    let credentials = ServerCredentials(locations: .default)
    /// A server asked for a credential there is none of; the window asks the person (043).
    var tokenAsk: TokenAsk?
    /// The Export… or Import Agents… on its way, drawn as a busy sheet with Cancel (#2437).
    var exportImport: ExportImportProgress?
    /// A server asked for a sign-in this Mac relays; the window asks the person (T091).
    var signInLendAsk: SignInLendAsk?
    /// Git asks answered here, until the control plane's list drops them (#1122).
    var gitAsksAnswered: Set<String> = []
    /// What a server with no connection answers through: nothing, at once.
    private static let unreachable = DaemonClient(link: UnreachableLink())

    /// The client for work on a host. A server that is not connected answers with an
    /// error straight away, never with the Mac's daemon.
    func client(for host: MachineRef) -> DaemonClient {
        if host == .mac { return client }
        if let through = controlHosts[host] { return through }
        // A control plane's host is never reached by this window's own ssh (T024).
        if controlLink != nil { return Self.unreachable }
        return hosts.client(for: host) ?? Self.unreachable
    }

    /// This Mac's host, for what is this Mac's own rather than a folder's: its runtimes,
    /// pool, settings and catalogue. `client`, or, with a control plane elsewhere that gave
    /// this Mac's host an id of its own, that host's client (#1496): no host is `.mac` then.
    private var macClient: DaemonClient {
        guard let mine = macHostElsewhere, let reached = controlHosts[mine] else { return client }
        return reached
    }

    /// This Mac's host when it is one of the control plane's hosts with an id other than
    /// `.mac` (#1481, #1496). Its work is that host's, by its id; nil when it is `.mac`.
    private var macHostElsewhere: MachineRef? {
        guard controlLink != nil, let mine = thisMacHostID, mine != .mac else { return nil }
        return mine
    }

    /// This Mac's host as the control plane last listed it (#1481), read once at launch.
    @ObservationIgnored private var keptHost: DaemonAPI.ControlMachine? =
        AppModel.controlKey.flatMap { KeptThisMacHost.read(controlKey: $0, from: WindowDefaults.store) }

    /// The host on this Mac the window last reached directly, over its local socket, rather
    /// than through the control plane (#1118): it is still reached with the control plane away.
    private(set) var directHost: MachineRef?

    /// A host's link: through the control plane, and first directly over the host's local
    /// socket when it may be on this Mac (#1118). The host's own answer says whether it is
    /// the one asked for, so `.mac` is tried even before the control plane has listed it.
    private func hostLink(_ host: MachineRef, through controlLink: ControlLink, onThisMac: Bool = true) -> any DaemonLink {
        let fallback = controlLink.link(for: host)
        guard onThisMac, let endpoint = ControlConfig.endpoint, let local = ControlConfig.localLink(endpoint, host: host) else {
            return fallback
        }
        return LocalFirstLink(local: local, fallback: fallback) { [weak self] direct in
            Task { @MainActor in self?.wentDirect(host, direct) }
        }
    }

    private func wentDirect(_ host: MachineRef, _ direct: Bool) {
        if direct {
            directHost = host
        } else if directHost == host {
            directHost = nil
        }
    }

    /// Whether `host` is one of the control plane's, reached through it.
    func reachesThroughControl(_ host: MachineRef) -> Bool { controlHosts[host] != nil }

    /// A connection to the control plane's own methods, for one call (T091); nil with none.
    func controlPlaneClient() -> DaemonClient? {
        controlLink.map { DaemonClient(link: $0.controlLink) }
    }

    /// The host on this Mac, when there is one. `.mac` until the window has a control plane.
    var thisMacHostID: MachineRef? {
        if !controlPlaneListed, let kept = keptHost { return kept.id }
        return ThisMacHost.resolve(controlPlaneHosts) ?? directHost
    }

    /// Whether this window may read `host`'s folders off this disk (058, R11).
    func isOnThisMac(_ host: MachineRef) -> Bool { thisMacHostID == host }

    /// The window cannot ask this host right now: the control plane is away, or the host is.
    func hostUnreachable(_ host: MachineRef) -> Bool {
        (controlPlaneAway && directHost != host) || hosts.isOffline(host)
    }

    /// Lend to a host the control plane reaches (058, FR-020). Nil when this window
    /// still reaches that host over its own ssh, so the caller uses that path.
    func lendThroughControl(_ id: MachineRef, runtime: String, secret: Secret, offered: Bool) async -> Bool? {
        guard controlHosts[id] != nil else { return nil }
        if !offered {
            _ = try? await client(for: id).call(DaemonAPI.Method.credentialsOffer, credentialOffer(id))
        }
        return (try? await client(for: id).call(
            DaemonAPI.Method.credentialsLend,
            DaemonAPI.CredentialsLend(runtime: runtime, secret: secret))) != nil
    }

    /// Why this Mac's host is quiet (#303), once the control plane has listed its hosts.
    /// Nil while the window is connected to it, while the control plane itself is away,
    /// and while the first list is still on its way (that is *Connecting…*).
    var macHostNotice: MacHostNotice? {
        // This Mac's host by an id of its own is reached as the control plane's other hosts
        // are, and is offline as they are; `.mac`'s connection is not its (#1496).
        guard !isConnected, !controlPlaneAway, macHostElsewhere == nil else { return nil }
        guard controlLink != nil else { return hosts.isOffline(.mac) ? .notAnswering : nil }
        guard controlPlaneListed else { return nil }
        return MacHostNotice.decide(planeOnThisMac: controlPlaneMachine == MachineID.current,
                                    macState: macHostState,
                                    join: macHostJoin,
                                    windowMissed: hosts.macDownSince != nil)
    }

    /// The control plane is elsewhere and lists no host on this Mac (#1503): only the window
    /// is paired here, and servers alone are hosts. Nothing then answers for this Mac's own
    /// things (runtimes, settings), and what is aimed at them says there is no host here,
    /// not that one isn't answering. A control plane on this Mac with no host here is
    /// `macHostNotice`'s: the host is not running.
    var noHostOnThisMac: Bool {
        controlLink != nil && controlPlaneListed && controlPlaneMachine != nil
            && controlPlaneMachine != MachineID.current && thisMacHostID == nil
    }

    /// This Mac's row in the control plane's last list, `online` or not.
    private var macHostState: String? { controlPlaneHosts?.first { $0.id == .mac }?.state }

    /// The control plane answers and says this Mac's host is up, so a window that cannot
    /// reach it has lost its own way there, not the host (#445).
    private var macHostUpAtControlPlane: Bool {
        guard controlLink != nil, controlPlaneReachable else { return false }
        if let join = macHostJoin { return join.member && join.connected && DaemonAPI.ControlMachine.answers(macHostState ?? "online") }
        return DaemonAPI.ControlMachine.answers(macHostState)
    }

    /// Tries in a row this Mac's host failed while the control plane said it was up (#445).
    @ObservationIgnored private var missesWithHostUp = 0

    /// A button's tooltip when `host` cannot be asked. This Mac's names the reason (#303).
    func offlineHelp(for host: MachineRef) -> String {
        if host == .mac, let notice = macHostNotice { return notice.tooltip }
        return hosts.offlineHelp(host)
    }

    /// The control plane was reached and then was not, or the first try failed (frame H).
    var controlPlaneAway: Bool { controlLink != nil && controlPlaneMissed && !controlPlaneReachable }

    /// Frame H's sentence, naming where the window expected the control plane.
    /// This Mac's host answers directly, over its local socket: `.mac` through `client`, or,
    /// with a control plane elsewhere, the host of its own id (#1481).
    private var reachesThisMacDirectly: Bool {
        guard let directHost else { return false }
        return directHost == .mac ? isConnected : hosts.controlled[directHost]?.online == true
    }

    var controlPlaneAwayLine: String? {
        guard controlPlaneAway else { return nil }
        switch ControlConfig.endpoint {
        case .remote(let membership):
            return HostProblem.controlPlaneUnreachable(name: membership.name,
                                                       address: membership.url ?? membership.addresses.first ?? "no address",
                                                       thisMacDirect: reachesThisMacDirectly)
        case nil:
            return nil
        }
    }

    /// This Mac's host strip's Try Again: the same as the control plane's (#83).
    /// The host notice's Try Again. With a control plane, the connection to it is let go
    /// first, so the try is on a fresh one with fresh routes at the host: the old one can
    /// answer for the control plane and still carry nothing to or from the host (#445).
    func tryMacHostAgain() {
        if !isConnected { controlLink?.disconnect() }
        missesWithHostUp = 0
        tryControlPlaneAgain()
    }

    /// The away strip's Try Again: one attempt now, then the usual backoff.
    func tryControlPlaneAgain() {
        reconnecting?.cancel()
        reconnecting = nil
        backoff.settle()
        controlWatch?.cancel()
        controlWatch = nil
        Task {
            await connect()
            if !isConnected { await reconnect() }
        }
    }

    /// The text of a file, from its host: `files/read`, or `files/readText` with no agent (R11).
    func textFile(at url: URL, on host: MachineRef, agentID: UUID?) async -> String? {
        if agentID == nil { return await readText(url, on: host) }
        guard let agentID else { return nil }
        guard let reading = try? await serverFiles(host).read(agentID: agentID,
                                                              path: url.path(percentEncoded: false)) else { return nil }
        if case .text(let text, _, _, _) = reading { return text }
        return nil
    }

    private func client(forAgent id: UUID?) -> DaemonClient {
        client(for: host(ofAgent: id))
    }

    /// One of a view's calls (#187), to the host its conversation is on.
    func viewCall(_ agentID: UUID, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await client(forAgent: agentID).call(method, params)
    }

    /// Where a new agent, a draft, a worktree or a session list for the selected
    /// folder goes: that folder's host.
    private var selectedHostClient: DaemonClient { client(for: selectedFolderHost) }
    /// Where a new session's prompt starts it: the folder whose own window it is in
    /// (#1089), or the selected one.
    private var draftHost: MachineRef { composingWindow?.host ?? selectedFolderHost }
    private var draftHostClient: DaemonClient { client(for: draftHost) }
    private var listening: Task<Void, Never>?

    /// The panes listening for shell output, one per shell in this window: an agent
    /// has one per terminal tab (055). Shell notifications are broadcast to every
    /// window, so each one keeps only the shells it is actually showing and ignores
    /// the rest.
    @ObservationIgnored private var shellClients: [ShellKey: ShellClient] = [:]
    /// How many screens show each of those shells (#213).
    @ObservationIgnored private var shellScreens: [ShellKey: Int] = [:]
    /// Shells no screen shows, kept with their emulator for a while, most recent last,
    /// so going back to an agent finds its terminal as it was instead of rebuilding it
    /// and replaying megabytes on the main thread (#401). A few, not all: each holds a
    /// screen's worth of emulator.
    @ObservationIgnored private var parkedShells: [ShellKey] = []
    private static let parkedShellLimit = 6

    /// The host of each folder shell this window has made (#418): it has no agent to
    /// say which.
    @ObservationIgnored private var folderShellHosts: [UUID: MachineRef] = [:]

    struct ShellKey: Hashable {
        var agentID: UUID
        var shell: Int
    }

    /// What each agent had already spent when this window first laid eyes on it.
    ///
    /// An agent's `costToDate` is its whole life, and agents outlive the window, so
    /// adding them up would be an all-time figure wearing the word "session". Taking
    /// away what was spent before we were watching leaves what this sitting cost.
    var selectedAgent: Agent? { work.agent(selection) }

    var permissionsForSelection: [PermissionRequest] { work.permissions(for: selection) }

    /// What a new agent can be started with, on the machine it would start on: the
    /// selected folder's (037). A server's runtimes are the ones installed there.
    var availableRuntimes: [RuntimeStatus] {
        runtimes(on: selectedFolderHost).filter(\.canStart)
    }

    /// Installed there, but not allowed by the organisation's policy (#998): the chooser
    /// lists them, dimmed, with why, and never starts one.
    var refusedRuntimes: [RuntimeStatus] {
        runtimes(on: selectedFolderHost).filter { $0.availability.isAvailable && $0.setBy != nil }
    }

    /// This Mac's, whatever is selected: for saying nothing is installed on this Mac.
    var macRuntimesAvailable: [RuntimeStatus] {
        runtimes.filter { $0.availability.isAvailable }
    }

    /// Each server's runtimes, as it last listed them (037).
    private(set) var serverRuntimes: [MachineRef: [RuntimeStatus]] = [:]

    func runtimes(on host: MachineRef) -> [RuntimeStatus] {
        host == .mac ? runtimes : serverRuntimes[host] ?? []
    }

    func refreshServerRuntimes(_ host: MachineRef) async {
        if let listed = try? await client(for: host).call(DaemonAPI.Method.runtimesList, Optional<String>.none,
                                                          returning: [RuntimeStatus].self) {
            serverRuntimes[host] = RuntimeCatalog.sortedByName(listed)
        }
    }

    // MARK: Folders

    /// The ones the sidebar lists.
    var liveFolders: [DaemonAPI.FolderSummary] { work.liveFolders }

    var archivedFolders: [DaemonAPI.FolderSummary] { work.archivedFolders }

    var selectedFolderSummary: DaemonAPI.FolderSummary? { work.folder(selectedFolderKey) }

    /// A folder's agents in one group, newest first.
    func agents(in key: FolderKey?, group: AgentGroup) -> [Agent] {
        work.agents(in: key, group: group)
    }

    /// How many archived sessions an Archived fold shows: enough to find last week's; the
    /// rest are on the phone's archive and in Events.
    static let archivedShown = SidebarFolderFold.archivedShown

    /// A folder's newest `limit` archived sessions, for its Archived page when it opens
    /// (#164), or the few its Recently archived sessions show (#2731): the window holds the
    /// live agents, and a page of archived ones per open folder. Answers whether the host
    /// did, so the page can tell an empty archive from a silent host (#664).
    @discardableResult
    func loadArchived(in key: FolderKey, limit: Int = archivedShown) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedOnly: true, folder: key.folder,
                                            limit: limit, lean: true)
        guard let listed = try? await client(for: key.host).call(DaemonAPI.Method.agentsList, request,
                                                                  returning: [Agent].self) else { return false }
        work.takeListed(listed.map { var agent = $0; agent.host = key.host; return agent })
        return true
    }

    /// Let go of a folder's archived sessions when its Archived fold closes (#165),
    /// keeping the one being read and any with a window of its own (#2744).
    func letGoOfArchived(in key: FolderKey) {
        let held = work.agents(in: key, group: .archived).map(\.id).filter { !isBeingRead($0) }
        work.forget(held)
    }

    /// Whether a session is open, in the main window or a window of its own: a let-go
    /// keeps it, or its window says it was deleted (#2744).
    private func isBeingRead(_ id: UUID) -> Bool {
        id == selection || popouts[id] != nil
    }

    /// The most a search brings back from each host, a page at a time.
    static let searchShown = 200
    /// Archived sessions a search brought in, let go when the search ends.
    @ObservationIgnored private var searched: Set<UUID> = []
    /// The next page of matches, for each host whose last page was full (#176).
    private var searchNext: [MachineRef: DaemonAPI.ListRequest] = [:]
    /// Whether a host has more matches than it has sent: More matches… asks for them.
    var searchHasMore: Bool { !searchNext.isEmpty }

    /// Ask every host for the sessions matching `words`, archived ones included, a capped
    /// page each (#165): the sidebar holds the live ones and filters those itself.
    func searchSessions(_ words: String) async {
        // Let the last page go before the next is asked, including a refinement.
        // Forgetting only when the field was cleared left every query's matches held (#285).
        let earlier = searched.filter { id in
            !isBeingRead(id) && heldAgent(id)?.state == .archived && !isInOpenArchivedFold(id)
        }
        searched = []
        searchNext = [:]
        work.forget(earlier)
        work.saidLines = [:]
        guard !words.isEmpty else { return }
        let request = DaemonAPI.ListRequest(archivedCommands: false, limit: Self.searchShown, lean: true, query: words)
        let hosts: [MachineRef] = (hasMacHost ? [.mac] : []) + self.hosts.servers.filter { !hostUnreachable($0) }
        for host in hosts {
            await search(request, on: host)
            // What was said (#1585): the sessions whose prompts or replies hold the words. Not
            // asked of a host too old to say (#1748).
            if self.host(host, has: Capability.agentsSaid1),
               let said = try? await client(for: host).call(DaemonAPI.Method.agentsSaid,
                                                            DaemonAPI.SaidSearchRequest(text: words),
                                                            returning: DaemonAPI.SaidSearchResult.self),
               !Task.isCancelled {
                for match in said.matches { work.saidLines[match.agentID] = match.line }
            }
        }
    }

    /// The next page from each host that has more, newest first as the host lists them.
    func searchMore() async {
        let next = searchNext
        searchNext = [:]
        for (host, request) in next { await search(request, on: host) }
    }

    private func search(_ request: DaemonAPI.ListRequest, on host: MachineRef) async {
        guard let page = await ArchiveActions.searchArchived(request, on: host, fetch: {
            try? await self.client(for: host).call(DaemonAPI.Method.agentsList, request, returning: [Agent].self)
        }) else { return }
        let fresh = page.agents.filter { heldAgent($0.id) == nil }.map(\.id)
        searched.formUnion(fresh)
        work.takeListed(page.agents)
        searchNext[host] = page.next
    }

    /// Whether an archived session is on show in its folder's open Archived fold.
    /// Held, without making a cell: a search or a history page asking must not leave
    /// one behind for every id it looked at (#285).
    private func heldAgent(_ id: UUID) -> Agent? {
        work.agents.first { $0.id == id }
    }

    private func isInOpenArchivedFold(_ id: UUID) -> Bool {
        guard let agent = heldAgent(id) else { return false }
        // As the sidebar keeps them: in defaults, read here once per search ended.
        return SidebarFolds().isOpen(FolderKey(host: agent.host, folder: agent.folderPath), .archivedSessions)
    }

    /// A workflow's newest runs, archived ones included, for its History (#164).
    /// Archived runs this page brought in are remembered, so a larger page can let go
    /// of the ones that left it, and closing the page lets go of the rest (#285).
    func loadRuns(of workflowID: String, in folder: URL, on host: MachineRef, limit: Int) async {
        let key = RunsKey(host: host, folder: Folder.standardize(folder), workflowID: workflowID)
        let request = DaemonAPI.ListRequest(archivedCommands: false, folder: folder,
                                            startedByWorkflow: workflowID, limit: limit, lean: true)
        guard let listed = try? await client(for: host).call(DaemonAPI.Method.agentsList, request,
                                                              returning: [Agent].self) else { return }
        guard !Task.isCancelled else { return }
        let stamped = listed.map { var agent = $0; agent.host = host; return agent }
        let previous = runsIntroduced[key] ?? []
        var introduced = Set<UUID>()
        for agent in stamped where agent.state == .archived {
            // Already held by a fold, or live, is not this page's to drop later.
            if previous.contains(agent.id) || heldAgent(agent.id) == nil {
                introduced.insert(agent.id)
            }
        }
        let left = previous.subtracting(introduced).filter { id in
            !isBeingRead(id) && heldAgent(id)?.state == .archived && !isInOpenArchivedFold(id)
        }
        work.forget(left)
        work.takeListed(stamped)
        runsIntroduced[key] = introduced
    }

    /// The archived runs one History page brought in, let go when that page closes.
    func letGoOfRuns(of workflowID: String, in folder: URL, on host: MachineRef) {
        let key = RunsKey(host: host, folder: Folder.standardize(folder), workflowID: workflowID)
        guard let ids = runsIntroduced.removeValue(forKey: key) else { return }
        work.forget(ids.filter { id in
            !isBeingRead(id) && heldAgent(id)?.state == .archived && !isInOpenArchivedFold(id)
        })
    }

    private struct RunsKey: Hashable {
        var host: MachineRef
        var folder: URL
        var workflowID: String
    }

    /// Archived agents a History page introduced, by the workflow they belong to.
    @ObservationIgnored private var runsIntroduced: [RunsKey: Set<UUID>] = [:]

    /// This window's own counts for a folder, from the grouping its panel uses.
    func counts(in key: FolderKey?) -> [AgentGroup: Int] { work.counts(in: key) }
    func unreadCount(in key: FolderKey?) -> Int { work.unreadCount(in: key) }

    /// How many sessions across every folder need the person: Needs you and Blocked,
    /// not unread finishes (#1565). Drives the Dock badge.
    var needsPersonCount: Int {
        liveFolders.reduce(0) { $0 + work.attentionCount(in: $1.key) }
    }

    /// The Blob's mood on the Dock tile (#1317), from the same groups the sidebar shows.
    var iconMood: IconMood {
        IconMood(counts: liveFolders.lazy.map { self.work.counts(in: $0.key) })
    }

    /// Whether the daemon is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

    /// "Started by …" for an agent another agent started, and nil otherwise (028).
    func startedByAgentLabel(_ agent: Agent) -> String? { work.startedByAgentLabel(agent) }

    /// Whether Stop is offered for this chat, in the toolbar and on the card alike.
    func canStop(_ agent: Agent) -> Bool { work.canStop(agent) }
    func blockLines(_ agent: Agent) -> [String] { work.blockLines(agent) }
    func queuedLine(_ agent: Agent) -> String? { work.queuedLine(agent) }
    func isBlocked(_ agent: Agent) -> Bool { work.openBlock(agent) != nil }

    // MARK: Workflows

    func workflows(in folder: URL?) -> [WorkflowSummary] { work.workflows(in: folder) }
    var userWorkflows: [WorkflowSummary] { work.userWorkflows }

    func refreshWorkflows() async {
        do {
            work.replaceWorkflows(try await client.call(DaemonAPI.Method.workflowsList,
                                                        DaemonAPI.WorkflowsListRequest(),
                                                        returning: [WorkflowSummary].self))
        } catch {
            // Same as the folders above: the next notification brings it back.
        }
    }

    func writeUserWorkflow(id: String, content: String) async -> String? {
        do {
            _ = try await client.call(
                DaemonAPI.Method.workflowsWrite,
                DaemonAPI.WorkflowWriteRequest(workflowID: id, content: content),
                returning: WorkflowSummary.self)
            await refreshWorkflows()
            return nil
        } catch {
            await refreshWorkflows()
            return describe(error)
        }
    }

    /// The machine id of the host being looked at, for a workflow pinned to computers
    /// (#317). This Mac's is `MachineID` even before the control plane has listed it.
    func workflowMachineID(on host: MachineRef) -> String? {
        if let id = controlPlaneHosts?.first(where: { $0.id == host })?.machineID, !id.isEmpty {
            return id
        }
        if host == .mac || controlPlaneHosts == nil { return MachineID.current }
        return nil
    }

    /// Keep a workflow the host still runs. A save that pins it elsewhere answers with
    /// the workflow, and putting that answer back would show a row this host does not run.
    func keepWorkflow(_ summary: WorkflowSummary, on host: MachineRef) {
        if !summary.workflow.runs(on: workflowMachineID(on: host)) {
            work.removeWorkflow(summary.workflowID, in: summary.folder)
        } else {
            work.upsert(summary)
        }
    }

    /// The computers the workflow page can pin to, under the names already on screen.
    var workflowHostChoices: [WorkflowHostChoice] {
        var listed = WorkflowHosts.choices(from: controlPlaneHosts ?? [], thisMachine: MachineID.current)
        if !listed.contains(where: { $0.machineID == MachineID.current }) {
            listed.insert(WorkflowHostChoice(machineID: MachineID.current, name: "This Mac"), at: 0)
        }
        return listed
    }

    /// Run one now. The daemon still applies the in-flight, ceiling and archive rules,
    /// and says so on the summary, which is why nothing here second-guesses it first.
    func runWorkflow(_ summary: WorkflowSummary) async {
        // Its refusal is said, not swallowed: a Run now that does nothing looked broken (073).
        await attempt(on: selectedFolderHost) {
            try await self.client(for: self.selectedFolderHost).call(
                DaemonAPI.Method.workflowsRun,
                DaemonAPI.WorkflowRequest(folder: summary.folder, workflowID: summary.workflowID))
        }
    }

    /// Put one away, or bring it back. The person's answer to a workflow an agent
    /// wrote, which is what makes writing one not need asking first.
    @discardableResult
    func setWorkflowArchived(_ summary: WorkflowSummary, _ archived: Bool) async -> Bool {
        await attempt(on: selectedFolderHost) {
            try await self.client(for: self.selectedFolderHost).call(
                DaemonAPI.Method.workflowsArchive,
                DaemonAPI.WorkflowArchiveRequest(folder: summary.folder,
                                                 workflowID: summary.workflowID,
                                                 archived: archived))
        }
    }

    /// Delete a workflow's file from its folder (#605).
    func deleteWorkflow(_ summary: WorkflowSummary, on host: MachineRef? = nil) async -> Bool {
        let host = host ?? selectedFolderHost
        return await attempt(on: host) {
            try await self.client(for: host).call(
                DaemonAPI.Method.workflowsDelete,
                DaemonAPI.WorkflowRequest(folder: summary.folder, workflowID: summary.workflowID))
        }
    }

    /// Turn one on or off, keeping its place on the list (#100). Turning one on when
    /// the total is already running is refused, and said (#506).
    func setWorkflowEnabled(_ summary: WorkflowSummary, _ enabled: Bool) async {
        await attempt(on: selectedFolderHost) {
            try await self.client(for: self.selectedFolderHost).call(
                DaemonAPI.Method.workflowsEnable,
                DaemonAPI.WorkflowEnableRequest(folder: summary.folder,
                                                workflowID: summary.workflowID,
                                                enabled: enabled))
        }
    }

    /// Mute Notifications for every run of one, or Unmute (#2003): `muted: true` in its file.
    func setWorkflowMuted(_ summary: WorkflowSummary, _ muted: Bool, on host: MachineRef? = nil) async {
        let host = host ?? selectedFolderHost
        await attempt(on: host) {
            try await self.client(for: host).call(
                DaemonAPI.Method.workflowsSetMuted,
                DaemonAPI.WorkflowMuteRequest(folder: summary.folder, workflowID: summary.workflowID, muted: muted))
        }
    }

    /// Clear a server's event trigger's missed-events mark (#383).
    func clearMCPMissed(_ summary: WorkflowSummary, _ status: MCPTriggerStatus) async {
        _ = try? await client(for: selectedFolderHost).call(
            DaemonAPI.Method.workflowsClearMCPMissed,
            DaemonAPI.WorkflowMCPClearMissedRequest(folder: summary.folder, workflowID: summary.workflowID,
                                                    name: status.name, server: status.server))
    }

    // MARK: Pinned pages (#159)

    func pins(in folder: URL?) -> [PinView] { work.pins(in: folder) }
    /// The folder's servers' list views (#2032), the hidden ones too.
    func serverViews(in folder: URL?) -> [PinView] { work.serverViews(in: folder) }
    func pageRevision(in folder: URL?) -> Int { work.pageRevision(in: folder) }

    func refreshPins() async {
        guard let listed = try? await client.call(DaemonAPI.Method.pinsList, DaemonAPI.Empty(),
                                                  returning: [FolderPins].self) else { return }
        work.replacePins(listed)
    }

    /// A file of a folder's, for a pinned page, a page tile, or what an HTML page draws.
    func readPage(_ path: String, in key: FolderKey, known: FileStamp? = nil) async throws -> FileReading {
        try await client(for: key.host).call(DaemonAPI.Method.pinsRead,
                                             DaemonAPI.PinReadRequest(folder: key.folder, path: path, knownStamp: known),
                                             returning: FileReading.self)
    }

    /// What the person typed on a pinned Markdown page. Why it was not saved, or nil.
    func writePage(_ path: String, in key: FolderKey, text: String) async -> String? {
        do {
            try await client(for: key.host).call(DaemonAPI.Method.pinsWrite,
                                                 DaemonAPI.PinWriteRequest(folder: key.folder, path: path, text: text))
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Pin to Folder, from the files pane: a path absolute on the folder's host.
    func pin(_ path: String, in key: FolderKey) async {
        await attempt(on: key.host) {
            let pins = try await self.client(for: key.host).call(DaemonAPI.Method.pinsPin,
                                                                 DaemonAPI.PinRequest(folder: key.folder, path: path),
                                                                 returning: [PinView].self)
            self.work.setPins(pins, in: key.folder)
        }
    }

    /// Pin a view under a folder (#189), from its menu in a chat. Why it was not, or nil.
    /// A view's `agents/start-agent` (#834): the folder's page, its bar filled in. Why
    /// not, or nil.
    func offerStart(_ start: AppViewStart, in key: FolderKey) -> String? {
        let wanted = Folder.standardize(key.folder)
        guard let folder = folders.first(where: {
            $0.host == key.host && Folder.standardize($0.folder.folder) == wanted
        }) else {
            return "\(key.folder.lastPathComponent) is not a folder here."
        }
        showFolder(FolderKey(host: key.host, folder: folder.folder.folder))
        offeredStart = OfferedStart(folder: folder.folder.folder, start: start)
        return nil
    }

    /// The session a view's `agents/message-agent` goes to (#837): on the branch, in this folder.
    func recipient(of message: AppViewAgentMessage, in key: FolderKey) -> AppViewRecipient? {
        message.recipient(among: agents, host: key.host, folder: key.folder)
            .map { AppViewRecipient(id: $0.id, name: AppViewAgentMessage.name(of: $0)) }
    }

    func pinView(_ view: ViewPin, in key: FolderKey) async -> String? {
        do {
            let pins = try await client(for: key.host).call(DaemonAPI.Method.pinsPin,
                                                            DaemonAPI.PinRequest(folder: key.folder, view: view),
                                                            returning: [PinView].self)
            work.setPins(pins, in: key.folder)
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    func unpin(_ path: String, in key: FolderKey) async {
        work.setPins(pins(in: key.folder).filter { $0.path != path }, in: key.folder)
        if openPin == path, selectedFolderKey == key { showFolder(key) }
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.pinsUnpin,
                                                      DaemonAPI.PinPathRequest(folder: key.folder, path: path))
        }
    }

    /// Hide or Show on a server's list view (#2032): shown at once, then the host told.
    func setViewHidden(_ uri: String, _ hidden: Bool, in key: FolderKey) async {
        work.setViewHidden(uri, hidden, in: key.folder)
        if hidden, openPin == uri, selectedFolderKey == key { showFolder(key) }
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.pinsHideView,
                                                      DaemonAPI.PinHideViewRequest(folder: key.folder, uri: uri, hidden: hidden))
        }
    }

    /// A drop or a Move item: shown at once, then the whole order sent once.
    func arrangePins(_ paths: [String], in key: FolderKey) async {
        let held = pins(in: key.folder)
        work.setPins(paths.compactMap { path in held.first { $0.path == path } }, in: key.folder)
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.pinsArrange,
                                                      DaemonAPI.PinArrangeRequest(folder: key.folder, paths: paths))
        }
    }

    // MARK: Pinned sessions (#180)

    func pinnedSessions(in folder: URL?) -> [UUID] { work.pinnedSessions(in: folder) }

    func isPinned(_ agent: Agent) -> Bool {
        pinnedSessions(in: agent.folderPath).contains(agent.id)
    }

    /// Pin or Unpin from a session's menu or swipe: shown at once, then the host told.
    func setPinned(_ agent: Agent, _ pinned: Bool) async {
        let folder = agent.folderPath
        let held = pinnedSessions(in: folder).filter { $0 != agent.id }
        work.setSessionPins(pinned ? held + [agent.id] : held, in: folder)
        await attempt(on: agent.host) {
            try await self.client(for: agent.host).call(
                pinned ? DaemonAPI.Method.pinsPinSession : DaemonAPI.Method.pinsUnpinSession,
                DaemonAPI.PinSessionRequest(folder: folder, agentID: agent.id))
        }
    }

    /// A drop or a Move item among the pinned sessions: shown at once, the order sent once.
    func arrangeSessionPins(_ ids: [UUID], in key: FolderKey) async {
        work.setSessionPins(ids, in: key.folder)
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.pinsArrangeSessions,
                                                      DaemonAPI.PinArrangeSessionsRequest(folder: key.folder, agentIDs: ids))
        }
    }

    // MARK: Pinned workflows (#432)

    func pinnedWorkflows(in folder: URL?) -> [String] { work.pinnedWorkflows(in: folder) }

    func isPinned(_ summary: WorkflowSummary) -> Bool {
        pinnedWorkflows(in: summary.folder).contains(summary.workflowID)
    }

    /// Pin or Unpin from a workflow's menu, swipe or page: shown at once, then the host told.
    func setPinned(_ summary: WorkflowSummary, _ pinned: Bool, on host: MachineRef) async {
        let folder = summary.folder
        let held = pinnedWorkflows(in: folder).filter { $0 != summary.workflowID }
        work.setWorkflowPins(pinned ? held + [summary.workflowID] : held, in: folder)
        await attempt(on: host) {
            try await self.client(for: host).call(
                pinned ? DaemonAPI.Method.pinsPinWorkflow : DaemonAPI.Method.pinsUnpinWorkflow,
                DaemonAPI.WorkflowRequest(folder: folder, workflowID: summary.workflowID))
        }
    }

    /// A drop among the pinned workflows: shown at once, the order sent once.
    func arrangeWorkflowPins(_ ids: [String], in key: FolderKey) async {
        work.setWorkflowPins(ids, in: key.folder)
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(
                DaemonAPI.Method.pinsArrangeWorkflows,
                DaemonAPI.PinArrangeWorkflowsRequest(folder: key.folder, workflowIDs: ids))
        }
    }

    /// A folder's plugins, asked for when its page opens; kept current after that by
    /// `plugins/changed`.
    func plugins(in folder: URL?) -> [FolderPlugin] { work.plugins(in: folder) }

    func refreshPlugins(in folder: URL) async {
        guard let list: DaemonAPI.PluginsList = try? await client.call(
            DaemonAPI.Method.pluginsList, DaemonAPI.PluginsListRequest(folder: folder),
            returning: DaemonAPI.PluginsList.self) else { return }
        work.replacePlugins(list)
    }

    /// Approve a plugin's folder as the row showed it. Said when it fails: most likely the
    /// folder changed after the person looked.
    func approvePlugin(_ plugin: FolderPlugin) async {
        guard let waiting = plugin.awaitingApproval else { return }
        do {
            let list: DaemonAPI.PluginsList = try await client.call(
                DaemonAPI.Method.pluginsApprove,
                DaemonAPI.PluginApproveRequest(plugin: plugin.folder, digest: waiting.digest),
                returning: DaemonAPI.PluginsList.self)
            work.replacePlugins(list)
        } catch {
            problem = describe(error)
            await refreshPlugins(in: plugin.folder)
        }
    }

    /// Approve a workflow's file as the row showed it. Said when it fails: the likely
    /// reason is that the file changed after the person looked, and they should look again.
    func approveWorkflow(_ summary: WorkflowSummary) async {
        await answerWorkflow(summary, DaemonAPI.Method.workflowsApprove)
    }

    /// Deny a workflow's file on this host only (#391), as the row showed it: it does not
    /// run here, its file is not touched, and Approve takes it back.
    func denyWorkflow(_ summary: WorkflowSummary) async {
        await answerWorkflow(summary, DaemonAPI.Method.workflowsDeny)
    }

    private func answerWorkflow(_ summary: WorkflowSummary, _ method: String) async {
        guard let waiting = summary.approvable else { return }
        do {
            let host = selectedFolderHost
            let updated: WorkflowSummary = try await client(for: host).call(
                method,
                DaemonAPI.WorkflowApproveRequest(folder: summary.folder, workflowID: summary.workflowID,
                                                 digest: waiting.digest),
                returning: WorkflowSummary.self)
            keepWorkflow(updated, on: host)
        } catch {
            problem = describe(error)
            await refreshWorkflows()
        }
    }

    /// Change what a workflow is allowed to do. The daemon writes the file.
    ///
    /// The one call in this section that does **not** swallow its error, and the
    /// difference matters: every other one here is asking for something the daemon
    /// will do or will not, and the next notification puts the window right either way.
    /// This one is asking for somebody's own file to be changed, and a refusal — front
    /// matter it will not touch, a file it cannot write — has to reach them, or the
    /// app has silently kept a change it never made (FR-025).
    /// `cooldown` is the file's `cooldown:` to write (#103), empty to remove it; left
    /// `nil`, the file's is left as it is.
    func setWorkflowSettings(_ summary: WorkflowSummary, _ settings: WorkflowSettings,
                             cooldown: String? = nil, labels: [String]? = nil,
                             runsOn: [String]? = nil, whenDone: String? = nil,
                             continueWhenBack: Bool? = nil) async {
        let host = selectedFolderHost
        do {
            let updated: WorkflowSummary = try await client(for: host).call(
                DaemonAPI.Method.workflowsSettings,
                DaemonAPI.WorkflowSettingsRequest(folder: summary.folder,
                                                  workflowID: summary.workflowID,
                                                  settings: settings, cooldown: cooldown,
                                                  labels: labels, runsOn: runsOn, whenDone: whenDone,
                                                  continueWhenBack: continueWhenBack),
                returning: WorkflowSummary.self)
            keepWorkflow(updated, on: host)
        } catch {
            problem = describe(error)
            // What the file still says, so the control goes back to the truth rather
            // than sitting on a value that was never written.
            await refreshWorkflows()
        }
    }

    /// What a runtime last advertised for a folder, for the menus on the workflow page.
    ///
    /// Empty is an answer, not a failure: it means nothing has been remembered for this
    /// runtime here yet, and the page says so rather than offering a menu it made up.
    func rememberedOptions(runtimeID: String, cwd: URL) async -> [ConfigOption] {
        (try? await selectedHostClient.call(DaemonAPI.Method.optionsRemembered,
                                DaemonAPI.RememberedOptionsRequest(runtimeID: runtimeID, cwd: cwd),
                                returning: [ConfigOption].self)) ?? []
    }

    /// What today has cost and what the reader will allow. A daemon too old to know
    /// the method answers method-not-found, which leaves `costState` nil and every
    /// surface showing what it showed before this feature.
    /// Whether the Mac is being kept awake, asked once on connecting.
    ///
    /// A window that opens while a hold is already in place has heard no broadcast, and
    /// for a long turn would otherwise say nothing about it for half an hour.
    ///
    /// Tolerates method-not-found exactly as `refreshCostState` does: a daemon too old
    /// to know `wake/state` leaves `wakeState` nil, and the window simply says nothing
    /// about sleep rather than failing to open.
    /// Asked once on connecting, then heard as it changes. A daemon too old to know the
    /// method leaves the list empty, as it would be with nothing to say.
    func refreshStoreNotes() async {
        guard let notes = try? await macClient.call(DaemonAPI.Method.storeNotes,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.StoreNotes.self) else { return }
        work.replaceStoreNotes(notes)
    }

    /// The milestones (#984), asked once on connecting. A host too old to know the method
    /// leaves them nil, and the Time page shows none.
    func refreshMilestones() async {
        guard let milestones = try? await macClient.call(DaemonAPI.Method.milestonesState, Optional<String>.none,
                                                      returning: Milestones.self) else { return }
        takeMilestones(milestones)
    }

    func refreshWakeState() async {
        guard let state = try? await macClient.call(DaemonAPI.Method.wakeState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.WakeState.self) else { return }
        work.replaceWakeState(state)
    }

    /// The switch and the hours. A daemon too old to know the method leaves this nil,
    /// and Settings ▸ Machines ▸ This Mac draws Archived agents alone.
    func refreshWakeSettings() async {
        wakeSettings = try? await macClient.call(DaemonAPI.Method.wakeSettings,
                                              Optional<String>.none,
                                              returning: WakeSettings.self)
    }

    func refreshSelfUpdate() async {
        selfUpdate = try? await macClient.call(DaemonAPI.Method.selfUpdateStatus, Optional<String>.none,
                                               returning: DaemonAPI.SelfUpdate.self)
    }

    /// The person turned updating Agents Host by itself on or off.
    func setAutoUpdate(_ on: Bool) async {
        await attempt {
            self.selfUpdate = try await self.macClient.call(DaemonAPI.Method.selfUpdateSet,
                                                            DaemonAPI.SelfUpdateSet(autoUpdate: on),
                                                            returning: DaemonAPI.SelfUpdate.self)
        }
    }

    /// The person changed Sleep. The daemon clamps the hours and answers with what it kept.
    func setWakeSettings(_ settings: WakeSettings) async {
        await attempt {
            self.wakeSettings = try await self.macClient.call(DaemonAPI.Method.wakeSet, settings,
                                                           returning: WakeSettings.self)
        }
    }

    /// Every resource and who holds it (036). A daemon too old to know the method
    /// leaves `leases` nil, and nothing about leases is drawn.
    func refreshLeases() async {
        guard let snapshot = try? await macClient.call(DaemonAPI.Method.resourcesSnapshot,
                                                    Optional<String>.none,
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    /// The MCP servers this Mac runs for every agent (#488). A daemon too old to know the
    /// method leaves `hostedMCP` nil, and the Resources page draws no such group.
    func refreshHostedMCP() async {
        guard let snapshot = try? await macClient.call(DaemonAPI.Method.mcpHosted, Optional<String>.none,
                                                    returning: DaemonAPI.HostedMCPSnapshot.self) else { return }
        work.replaceHostedMCP(snapshot)
    }

    /// Every MCP server on a host and how each is doing (#753). A daemon too old to know
    /// the method leaves it to the hosted servers alone.
    func refreshMCPHealth(_ host: MachineRef = .mac) async {
        guard let snapshot = try? await client(for: host).call(DaemonAPI.Method.mcpHealth, Optional<String>.none,
                                                               returning: DaemonAPI.MCPHealthSnapshot.self) else { return }
        work.replaceMCPHealth(snapshot, from: host)
    }

    /// Check Now on the person's own servers (no folder) or a folder's (#753).
    func checkMCPHealth(folder: FolderKey?) async {
        let host = folder?.host ?? .mac
        let request = DaemonAPI.MCPHealthCheckRequest(folder: folder?.folder.path)
        guard let snapshot = try? await client(for: host).call(DaemonAPI.Method.mcpHealthCheck, request,
                                                               returning: DaemonAPI.MCPHealthSnapshot.self) else { return }
        work.replaceMCPHealth(snapshot, from: host)
    }

    /// What the work used by hour and by day (#823), for the charts on Cost: this Mac's
    /// and every connected server's, each moved into this Mac's days (#1267). Nil when no
    /// host knows the method, and the charts stay out.
    func usageHistory() async -> UsageHistory? {
        var histories: [UsageHistory] = []
        for host in chartHosts {
            if let history = try? await client(for: host).call(DaemonAPI.Method.usageHistory, Optional<String>.none,
                                                                returning: UsageHistory.self) {
                histories.append(history)
            }
        }
        return histories.isEmpty ? nil : .merged(histories)
    }

    /// Where the time of running chats went (#852), for the Time page, from every host as
    /// `usageHistory` is. The recap is this Mac's. Nil when no host knows the method.
    func timeHistory() async -> TimeHistory? {
        var histories: [TimeHistory] = []
        for host in chartHosts {
            if let history = try? await client(for: host).call(DaemonAPI.Method.timeHistory, Optional<String>.none,
                                                                returning: TimeHistory.self) {
                histories.append(history)
            }
        }
        return histories.isEmpty ? nil : .merged(histories)
    }

    /// This Mac first, then every server that has said what it spends.
    private var chartHosts: [MachineRef] { [.mac] + serverCosts.keys.filter { $0 != .mac } }

    /// Every volume low on space (#195). A daemon too old to know the method leaves it
    /// empty, and no strip is drawn.
    func refreshDisk() async {
        guard let state = try? await macClient.call(DaemonAPI.Method.diskState, Optional<String>.none,
                                                 returning: DiskState.self) else { return }
        work.replaceDisk(state)
    }

    private func refreshServerDisk(_ host: MachineRef) async {
        guard let state = try? await client(for: host).call(DaemonAPI.Method.diskState,
                                                            Optional<String>.none,
                                                            returning: DiskState.self) else { return }
        serverDisks[host] = state
    }

    /// The newest page of events and who is waiting (042), narrowed by `filter`, or as
    /// the page last narrowed it. A daemon too old to know the method leaves the list
    /// empty, and the Events page says there is nothing yet.
    func refreshEvents(_ filter: EventFilter? = nil) async {
        let filter = filter ?? work.eventsFilter
        work.eventsFilter = filter
        guard let page = try? await macClient.call(DaemonAPI.Method.eventsList, DaemonAPI.EventsListRequest(filter),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, for: filter)
    }

    /// The page before the oldest event the window has, for scrolling back.
    func loadOlderEvents() async {
        let filter = work.eventsFilter
        guard work.moreEvents, let oldest = work.recentEvents.last?.position else { return }
        guard let page = try? await macClient.call(DaemonAPI.Method.eventsList,
                                                DaemonAPI.EventsListRequest(before: oldest, filter),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, for: filter, appending: true)
    }

    /// The person cancelling an agent's wait (042 FR-013), on the agent's own host: a
    /// server's or another Mac's agent waits there (#2068). A failure says why.
    func cancelWait(of agentID: UUID) async {
        let host = host(ofAgent: agentID)
        await attempt(on: host) {
            _ = try await self.client(for: host).call(DaemonAPI.Method.eventsCancelWait,
                                                      DaemonAPI.CancelWaitRequest(agentID: agentID),
                                                      returning: [DaemonAPI.WaitingAgent].self)
        }
    }

    /// The person ending a lease (036 US4): one holder's, or with none named, every
    /// one. Never a way to take one.
    func endLease(_ name: ResourceName, holder: UUID? = nil) async {
        guard let snapshot = try? await macClient.call(DaemonAPI.Method.resourcesEnd,
                                                    DaemonAPI.PersonEndRequest(name: name.key,
                                                                               agentID: holder?.uuidString),
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    /// The person adding or changing a declared resource (#116). The host's refusal,
    /// in its words, when it will not keep it.
    func declareResource(_ resource: DeclaredResource, replacing: ResourceName?) async -> String? {
        do {
            let snapshot = try await macClient.call(DaemonAPI.Method.resourcesDeclare,
                                                 DaemonAPI.DeclareResourceRequest(resource: resource,
                                                                                  replacing: replacing?.key),
                                                 returning: DaemonAPI.LeaseSnapshot.self)
            work.replaceLeases(snapshot)
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// The person taking a declaration away (#116). Whoever holds it keeps the lease.
    func removeDeclaredResource(_ name: ResourceName) async {
        guard let snapshot = try? await macClient.call(DaemonAPI.Method.resourcesRemove,
                                                    DaemonAPI.RemoveResourceRequest(name: name.key),
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    /// The person taking one agent out of one line (036 US4).
    func removeFromLine(_ name: ResourceName, agentID: UUID) async {
        guard let snapshot = try? await macClient.call(
            DaemonAPI.Method.resourcesRemoveWaiter,
            DaemonAPI.PersonRemoveRequest(name: name.key, agentID: agentID.uuidString),
            returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    // MARK: The user scope (#1760)

    /// Sets a part at the user scope: nil once done, else why not.
    func setUserPart(_ part: DaemonAPI.UserSettingsPartName, _ value: some Encodable) async -> String? {
        guard let encoded = try? JSONValue.encoding(value) else { return "That could not be written." }
        return await userScope.set(part, to: encoded, on: controlRequests)
    }

    /// After an edit in Agent Configuration or Agent Runtimes: a part that follows the person
    /// is set again from this Mac, when it changed here.
    func keepFollowingParts() async {
        for part in [DaemonAPI.UserSettingsPartName.mcpServers, .agentConfig, .runtimes] {
            guard let here = try? await macClient.call(DaemonAPI.Method.settingsUserPart, DaemonAPI.UserPartRequest(part: part),
                                                       returning: DaemonAPI.UserPartHere.self),
                here.value != userScope.settings?[part] else { continue }
            _ = await userScope.set(part, to: here.value, on: controlRequests)
        }
    }

    func refreshCostState() async {
        guard let state = try? await macClient.call(DaemonAPI.Method.costState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.CostState.self) else { return }
        work.replaceCostState(state)
    }

    /// The reader setting or clearing a limit. Theirs alone: nothing an agent or a
    /// workflow can reach calls this.
    // MARK: Retiring archived agents (051)

    /// A Settings pane to open on, asked for by a link elsewhere (052): read and cleared
    /// by the Settings window.
    var settingsPaneAsked: SettingsPane?

    /// A file for Agent Configuration's editor to open, asked for by a workflow page's Edit
    /// File… (#2803): read and cleared by the editor's page for that kind and folder.
    var agentConfigFileAsked: AgentConfigFileAsk?

    /// Every runtime's state on this Mac (065, US4). Asking also asks Grok what is left.
    func refreshRuntimeAllowances() async {
        guard let allowances = try? await macClient.call(DaemonAPI.Method.runtimesAllowances, Optional<String>.none,
                                                      returning: RuntimeAllowances.self) else { return }
        work.replaceRuntimeAllowances(allowances)
    }

    /// The person says a runtime is back, by its credential (065).
    func markRuntimeAvailable(_ credentialKey: String) async {
        guard let allowances = try? await macClient.call(DaemonAPI.Method.runtimesMarkAvailable,
                                                      DaemonAPI.MarkRuntimeAvailable(credentialKey: credentialKey),
                                                      returning: RuntimeAllowances.self) else { return }
        work.replaceRuntimeAllowances(allowances)
    }

    /// The Mac's word on the plans it relays, to every connected server (052, R6).
    private func sendSharedAllowances(_ allowances: RuntimeAllowances) async {
        let shared = allowances.shared ?? []
        guard !shared.isEmpty else { return }
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(DaemonAPI.Method.poolApplyAllowances,
                                                     DaemonAPI.ApplyAllowances(states: shared), returning: Bool.self)
        }
    }

    func refreshBackupState() async {
        guard let state = try? await macClient.call(DaemonAPI.Method.backupsState, DaemonAPI.Empty(),
                                                 returning: DaemonAPI.BackupState.self) else { return }
        work.replaceBackupState(state)
    }

    /// Settings ▸ Machines ▸ This Mac ▸ Backups (#1810): each throws the host's refusal, for the section to say.
    func configureBackups(_ settings: DaemonAPI.BackupSettings) async throws {
        work.replaceBackupState(try await macClient.call(DaemonAPI.Method.backupsConfigure, settings,
                                                         returning: DaemonAPI.BackupState.self))
    }

    func makeBackup() async throws {
        work.replaceBackupState(try await macClient.call(DaemonAPI.Method.backupsMake, DaemonAPI.BackupMakeRequest(),
                                                         returning: DaemonAPI.BackupState.self))
    }

    func restoreBackup(_ backup: DaemonAPI.Backup) async throws -> DaemonAPI.BackupRestoreResult {
        try await macClient.call(DaemonAPI.Method.backupsRestore, DaemonAPI.BackupRestoreRequest(id: backup.id),
                                 returning: DaemonAPI.BackupRestoreResult.self)
    }

    func refreshRetentionState() async {
        guard let state = try? await macClient.call(DaemonAPI.Method.retentionState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.RetentionState.self) else { return }
        work.replaceRetentionState(state)
    }

    /// The person changing how long archived agents are kept. Unconfirmed, a change that
    /// would delete agents at once comes back unapplied with what it would delete, for
    /// the confirmation; confirmed, it is applied here and then on every server, which
    /// keeps to the Mac's settings the way it keeps to its limits (037 R7).
    func setRetention(_ settings: RetentionSettings, confirmed: Bool) async -> DaemonAPI.RetentionSetResult? {
        guard let result = try? await macClient.call(
            DaemonAPI.Method.retentionSet,
            DaemonAPI.RetentionSetRequest(settings: settings, confirmed: confirmed),
            returning: DaemonAPI.RetentionSetResult.self) else { return nil }
        if let state = result.state { work.replaceRetentionState(state) }
        if result.applied { await pushRetentionToServers(settings) }
        return result
    }

    func pushRetentionToServers(_ settings: RetentionSettings) async {
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(
                DaemonAPI.Method.retentionSet,
                DaemonAPI.RetentionSetRequest(settings: settings, confirmed: true),
                returning: DaemonAPI.RetentionSetResult.self)
        }
    }

    func refreshWorkflowLimit() async {
        workflowLimit = try? await macClient.call(DaemonAPI.Method.workflowsLimit, Optional<String>.none,
                                               returning: WorkflowLimitSettings.self)
    }

    /// The person changing the total (#506): here, then on every server, which keeps to
    /// the Mac's settings the way it keeps to its retention.
    func setWorkflowLimit(_ settings: WorkflowLimitSettings) async {
        await attempt {
            self.workflowLimit = try await self.macClient.call(DaemonAPI.Method.workflowsSetLimit, settings,
                                                            returning: WorkflowLimitSettings.self)
        }
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(DaemonAPI.Method.workflowsSetLimit, settings,
                                                     returning: WorkflowLimitSettings.self)
        }
    }

    func refreshClientPermissions() async {
        guard let settings = try? await macClient.call(DaemonAPI.Method.clientPermissionsState,
                                                    Optional<String>.none,
                                                    returning: ClientPermissionSettings.self) else { return }
        clientPermissions = settings
    }

    /// The person's display choices (#1033): this Mac's host keeps them, and the window's
    /// defaults mirror them so every view reads them where it always did.
    @ObservationIgnored lazy var displayMirror = DisplayPreferenceMirror(defaults: WindowDefaults.store) { [weak self] changes in
        self?.sendDisplayPreferences(changes)
    }

    private func sendDisplayPreferences(_ changes: DaemonAPI.DisplayPreferences) {
        Task { _ = try? await macClient.call(DaemonAPI.Method.preferencesSet, changes,
                                         returning: DaemonAPI.DisplayPreferences.self) }
    }

    func refreshDisplayPreferences() async {
        guard let preferences = try? await macClient.call(DaemonAPI.Method.preferencesGet, Optional<String>.none,
                                                       returning: DaemonAPI.DisplayPreferences.self) else { return }
        displayMirror.hostSaid(preferences)
    }

    func refreshPerson() async {
        guard let settings = try? await macClient.call(DaemonAPI.Method.personState, Optional<String>.none,
                                                    returning: PersonSettings.self) else { return }
        person = settings
    }

    /// Save what agents call the person and copy it to every connected server (#121),
    /// with the name filled in from this Mac's account, so a server's agents call the
    /// person what this Mac's do and not by that server's account name.
    func setPerson(_ settings: PersonSettings) async {
        var saved: PersonSettings?
        await attempt {
            saved = try await self.macClient.call(DaemonAPI.Method.personSet, settings, returning: PersonSettings.self)
        }
        guard let saved else { return }
        person = saved
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(DaemonAPI.Method.personSet, saved.resolved(),
                                                     returning: PersonSettings.self)
        }
    }

    /// Save Cursor/Grok permission mode and copy it to every connected server (061).
    func setClientPermissions(_ settings: ClientPermissionSettings) async {
        var saved: ClientPermissionSettings?
        await attempt {
            saved = try await self.macClient.call(DaemonAPI.Method.clientPermissionsSet, settings,
                                               returning: ClientPermissionSettings.self)
        }
        guard let saved else { return }
        clientPermissions = saved
        await pushClientPermissionsToServers(saved)
    }

    func pushClientPermissionsToServers(_ settings: ClientPermissionSettings) async {
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(DaemonAPI.Method.clientPermissionsSet, settings,
                                                     returning: ClientPermissionSettings.self)
        }
    }

    /// One agent's own sandbox choice, nil to follow its runtime's default (064).
    /// The agent comes back by `agent/changed`, as for any other change to it.
    func setAgentSandbox(_ agentID: UUID, _ choice: SandboxChoice?) async {
        _ = await attempt {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsSetSandbox,
                                                           DaemonAPI.SetSandboxRequest(agentID: agentID, choice: choice))
        }
    }

    /// The sandbox card's answer (064, FR-007a): only this agent is changed.
    func answerSandbox(_ agentID: UUID, carryOn: Bool) async {
        _ = await attempt {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsAnswerSandbox,
                                                           DaemonAPI.AnswerSandboxRequest(agentID: agentID, carryOn: carryOn))
        }
    }

    func refreshPolicyState() async {
        guard let state = try? await macClient.call(DaemonAPI.Method.daemonPolicyState, DaemonAPI.Empty(),
                                                 returning: DaemonAPI.PolicyState.self) else { return }
        policyState = state
    }

    func refreshPassThrough() async {
        guard let state = try? await macClient.call(DaemonAPI.Method.settingsPassThrough, DaemonAPI.Empty(),
                                                 returning: DaemonAPI.PassThroughState.self) else { return }
        passThrough = state
    }

    func refreshSandboxSettings() async {
        guard let settings = try? await macClient.call(DaemonAPI.Method.sandboxState, Optional<String>.none,
                                                    returning: SandboxSettings.self) else { return }
        sandboxSettings = settings
    }

    /// Save a runtime's sandbox default and copy it to every connected server (064): each
    /// server applies it to the runtimes installed there, as the Mac does.
    func setSandboxDefault(_ choice: SandboxChoice, for runtimeID: String) async {
        let before = sandboxSettings
        let wanted = sandboxSettings.setting(choice, for: runtimeID)
        sandboxSettings = wanted
        var saved: SandboxSettings?
        await attempt {
            saved = try await self.macClient.call(DaemonAPI.Method.sandboxSet, wanted,
                                               returning: SandboxSettings.self)
        }
        // Not kept, so not shown: the picker goes back to what the host still has (073).
        guard let saved else { sandboxSettings = before; return }
        sandboxSettings = saved
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(DaemonAPI.Method.sandboxSet, saved,
                                                     returning: SandboxSettings.self)
        }
    }

    /// Delete one archived agent (#398). It leaves the list by `agent/removed`; a refusal
    /// says why it cannot go yet.
    func delete(_ agentID: UUID) async -> Result<Void, JSONRPCError> {
        do {
            _ = try await client(for: work.agent(agentID)?.host ?? .mac).call(
                DaemonAPI.Method.agentsDelete, DaemonAPI.AgentRequest(agentID: agentID),
                returning: DaemonAPI.Empty.self)
            if selection == agentID { selection = nil }
            return .success(())
        } catch let error as JSONRPCError {
            return .failure(error)
        } catch {
            return .failure(JSONRPCError(code: -1, message: error.localizedDescription))
        }
    }

    func setCostLimits(perAgent: Cost?? = nil, daily: Cost?? = nil,
                       perAgentTokens: Int?? = nil, dailyTokens: Int?? = nil) async {
        // Cost limits belong to the person (#2410), so a paired Mac writes the user setting.
        var limits = (try? userScope.settings?.costLimits?.decode(CostLimits.self)) ?? costLimits
        if let perAgent { limits.perAgent = perAgent }
        if let daily { limits.daily = daily }
        if let perAgentTokens { limits.perAgentTokens = perAgentTokens }
        if let dailyTokens { limits.dailyTokens = dailyTokens }
        if controlRequests != nil {
            if let refused = await setUserPart(.costLimits, limits) { problem = refused }
            return
        }
        var set: DaemonAPI.CostState?
        await attempt {
            set = try await self.macClient.call(DaemonAPI.Method.costSetLimits,
                                                DaemonAPI.SetLimitsRequest(perAgent: perAgent, daily: daily,
                                                                           perAgentTokens: perAgentTokens,
                                                                           dailyTokens: dailyTokens),
                                                returning: DaemonAPI.CostState.self)
        }
        guard let state = set else { return }
        work.replaceCostState(state)
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            serverCosts[host.id] = try? await client(for: host.id).call(
                DaemonAPI.Method.costSetLimits,
                DaemonAPI.SetLimitsRequest(copying: state.limits),
                returning: DaemonAPI.CostState.self)
        }
    }

    /// Each server's spending, as it last said (037).
    private(set) var serverCosts: [MachineRef: DaemonAPI.CostState] = [:]
    /// Each server's disk alarms, kept beside the Mac's own disk strip (#263).
    private(set) var serverDisks: [MachineRef: DiskState] = [:]

    /// What the servers have spent today, together, per currency. Empty when nothing.
    /// This Mac's host by an id of its own is this Mac's spending, not a server's (#1496).
    var serversToday: [String: Decimal] {
        serverCosts.filter { $0.key != macHostElsewhere }.values.reduce(into: [:]) { sum, state in
            for (currency, amount) in state.today { sum[currency, default: 0] += amount }
        }
    }

    /// Let one agent that has reached the per-agent limit carry on.
    ///
    /// Raises that agent's own ceiling by the app-wide limit again — a concrete,
    /// bounded allowance rather than removing the cap, so an agent let go on once is
    /// still stopped eventually. Applies to that agent alone, and does not resume it.
    /// Money or tokens, whichever it reached (#838). Does not resume it — continuing
    /// is the reader's second, deliberate act.
    func letThisAgentGoOn(_ agent: Agent) async {
        var changed: Agent?
        await attempt {
            changed = try await self.client(forAgent: agent.id).call(
                DaemonAPI.Method.agentsSetCeiling, agent.goOnRequest(under: self.costLimits),
                returning: Agent.self)
        }
        guard let changed else { return }
        work.upsert(changed)
    }

    func refreshFolders() async {
        do {
            let listed = try await client.call(DaemonAPI.Method.foldersList, DaemonAPI.FoldersListRequest(),
                                               returning: [DaemonAPI.FolderSummary].self)
            work.replaceFolders(listed, from: .mac)
            hasLoadedFolders = true
            settleFolderSelection()
            weighGetStarted()
        } catch {
            // A list that failed is not worth an alert: the notification that follows
            // the next change will bring it back.
        }
    }

    /// Pick a folder when there is none, or when the one we had has gone or been
    /// archived. Falls back to what the sidebar puts at the top.
    private func settleFolderSelection() {
        let live = liveFolders
        if let selectedFolderKey, live.contains(where: { $0.key == selectedFolderKey }) { return }
        // `host|path`.
        let stored = WindowDefaults.store.string(forKey: Self.selectedFolderDefault)
            .flatMap(FolderKey.init(stored:))
            .map { FolderKey(host: $0.host, folder: Folder.standardize($0.folder)) }
        if let stored, live.contains(where: { $0.key == stored }) {
            select(stored)
        } else {
            select(live.first?.key)
        }
        openPending()
    }

    /// With `project`, the folder joins the project picked in the Add Folder sheet (#2671);
    /// with none, a folder that names no project gets one of its own.
    func addFolder(_ folder: URL, on host: MachineRef = .mac, project: String? = nil) async {
        do {
            var summary = try await client(for: host).call(DaemonAPI.Method.foldersAdd,
                                                           DaemonAPI.AddFolderRequest(folder: folder, project: project),
                                                           returning: DaemonAPI.FolderSummary.self)
            summary.host = host
            upsert(summary)
            select(summary.key)
            settleFolderSelection()
        } catch {
            problem = describe(error)
        }
    }

    /// The folders the person picked on a host (#656), added one by one without moving the
    /// window's selection: those that could not be, each with why.
    func addFolders(_ folders: [URL], on host: MachineRef) async -> [URL: String] {
        var failed: [URL: String] = [:]
        for folder in folders {
            do {
                var summary = try await client(for: host).call(DaemonAPI.Method.foldersAdd, DaemonAPI.FolderRequest(folder: folder),
                                                               returning: DaemonAPI.FolderSummary.self)
                summary.host = host
                upsert(summary)
            } catch {
                failed[folder] = describe(error)
            }
        }
        return failed
    }

    /// Files dragged onto a folder's row, or one of its sessions', or chosen in its Drop
    /// Box sheet, put into that folder's drop box (#231): its main folder's, never a
    /// session's worktree, and inside `subfolder` when one is named. Sent to the folder's
    /// host like an attachment, so a server's folder gets them too. The event that fires
    /// is the host's; nothing is said here unless one could not go, and then it is false.
    @discardableResult
    func putInDropbox(_ files: [URL], subfolder: String = "", folder: FolderKey) async -> Bool {
        let folderSubpath = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespaces))
        for file in files {
            let name = file.lastPathComponent
            // Looked at before it is read: a film dragged by mistake is not read whole first.
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= DaemonAPI.dropboxPutLimit else {
                problem = "\(name) is too big to send. Copy it into .agents/dropbox/ in \(folder.folder.lastPathComponent) instead."
                return false
            }
            let data: Data
            do {
                // Off the main thread: up to 25 MB.
                data = try await Task.detached {
                    try Data(contentsOf: file)  // store-ok: a file the person dropped, which the drag lets this window read
                }.value
            } catch {
                problem = "\(name) could not be read to put in the drop box: \(error.localizedDescription)"
                return false
            }
            do {
                _ = try await client(for: folder.host).call(
                    DaemonAPI.Method.dropboxPut,
                    DaemonAPI.DropboxPutRequest(folder: folder.folder, subfolder: folderSubpath.isEmpty ? nil : folderSubpath,
                                                name: name, data: data),
                    returning: DaemonAPI.DropboxPutResponse.self)
            } catch {
                problem = describe(error)
                return false
            }
        }
        return true
    }

    /// Clone a Git URL into the home folder and select the folder it becomes (027).
    ///
    /// Returns as soon as the daemon answers, which is when the clone has finished; the
    /// row the window draws meanwhile comes from `clone/changed`, not from waiting here.
    func cloneFolder(_ url: String, on host: MachineRef = .mac) async {
        do {
            var summary = try await client(for: host).call(DaemonAPI.Method.foldersClone,
                                                DaemonAPI.CloneRequest(url: url),
                                                returning: DaemonAPI.FolderSummary.self)
            summary.host = host
            upsert(summary)
            select(summary.key)
            settleFolderSelection()
        } catch {
            // Written for the person already: which host, which folder, what to do.
            problem = describe(error)
        }
    }

    func refreshClones() async {
        guard let running = try? await client.call(DaemonAPI.Method.foldersClones,
                                                   returning: [DaemonAPI.CloneSummary].self) else { return }
        clones = running
    }

    func archiveFolder(_ key: FolderKey) async {
        await callFolder(DaemonAPI.Method.foldersArchive, key)
    }

    func unarchiveFolder(_ key: FolderKey) async {
        await callFolder(DaemonAPI.Method.foldersUnarchive, key) { [weak self] summary in
            self?.select(summary.key)
        }
    }

    /// Delete an archived folder (#677): every session in it and its record; its folder
    /// stays. Out of the list at once, as `folder/removed` would take it; a refusal says
    /// which sessions hold it.
    func deleteFolder(_ key: FolderKey) async -> Result<Void, JSONRPCError> {
        do {
            _ = try await client(for: key.host).call(DaemonAPI.Method.foldersDelete,
                                                     DaemonAPI.FolderRequest(folder: key.folder),
                                                     returning: DaemonAPI.Empty.self)
            work.removeFolder(key)
            settleFolderSelection()
            return .success(())
        } catch let error as JSONRPCError {
            return .failure(error)
        } catch {
            return .failure(JSONRPCError(code: -1, message: error.localizedDescription))
        }
    }

    /// The person's helper limits for a folder (#64). Through the window only: the
    /// daemon refuses the method to agents and phones.
    func setHelperLimits(_ limits: HelperLimits, for key: FolderKey) async {
        do {
            var summary = try await client(for: key.host).call(
                DaemonAPI.Method.foldersSetHelperLimits,
                DaemonAPI.SetHelperLimitsRequest(folder: key.folder, limits: limits),
                returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            upsert(summary)
        } catch {
            problem = describe(error)
        }
    }

    /// The folder joins a project (#2317): its id written into `.agents/folder.json` by its
    /// own machine. Nil, or why not.
    func setProject(_ project: String, for key: FolderKey) async -> String? {
        do {
            var summary = try await client(for: key.host).call(
                DaemonAPI.Method.foldersSetProject,
                DaemonAPI.SetFolderProjectRequest(folder: key.folder, project: project),
                returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            upsert(summary)
            return nil
        } catch {
            return describe(error)
        }
    }

    /// A folder pinned to the top of the sidebar, or not.
    func setPinned(_ pinned: Bool, for key: FolderKey) async {
        do {
            var summary = try await client(for: key.host).call(
                DaemonAPI.Method.foldersSetPinned,
                DaemonAPI.SetPinnedRequest(folder: key.folder, pinned: pinned),
                returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            upsert(summary)
        } catch {
            problem = describe(error)
        }
    }

    /// The person's disk space lines for a folder (#195), through the window only.
    /// What a guarded file in `.agents` was and is (#502), for the person deciding.
    func readGuardedChange(_ change: GuardedChange, for key: FolderKey) async -> GuardedChangeReading? {
        do {
            return try await client(for: key.host).call(
                DaemonAPI.Method.foldersReadGuardedChange,
                DaemonAPI.GuardedChangeRequest(folder: key.folder, path: change.path),
                returning: GuardedChangeReading.self)
        } catch {
            problem = describe(error)
            return nil
        }
    }

    /// Keep (the change is used from now on) or Undo (the approved copy goes back), of the
    /// file as the person was shown it (#502).
    func settleGuardedChange(_ reading: GuardedChangeReading, keep: Bool, for key: FolderKey) async {
        do {
            var summary = try await client(for: key.host).call(
                keep ? DaemonAPI.Method.foldersKeepGuardedChange : DaemonAPI.Method.foldersUndoGuardedChange,
                DaemonAPI.GuardedChangeRequest(folder: key.folder, path: reading.path, digest: reading.digest),
                returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            upsert(summary)
        } catch {
            problem = describe(error)
        }
    }

    /// What a waiting item in Needs You is (#773), for the person deciding.
    func readApproval(_ approval: Approval, for key: FolderKey) async -> GuardedChangeReading? {
        do {
            return try await client(for: key.host).call(
                DaemonAPI.Method.approvalsRead,
                ApprovalReadRequest(folder: key.folder, kind: approval.kind, key: approval.key),
                returning: GuardedChangeReading.self)
        } catch {
            problem = describe(error)
            return nil
        }
    }

    /// Approve, Deny or Request changes on a waiting item (#773), of the version shown;
    /// nil when it went, else why not, for the sheet to say.
    func answerApproval(_ approval: Approval, _ action: Approval.Action, digest: String?, note: String?,
                        for key: FolderKey) async -> String? {
        var answer = ApprovalAnswer(approval, in: key.folder, action: action, note: note)
        answer.digest = digest ?? approval.digest
        do {
            var summary = try await client(for: key.host).call(
                DaemonAPI.Method.approvalsAnswer, answer, returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            upsert(summary)
            return nil
        } catch {
            return describe(error)
        }
    }

    /// Approve or Deny from a row's menu, of the version the row shows; a refusal is the
    /// window's problem to say, as there is no sheet to say it in.
    func settleApproval(_ approval: Approval, _ action: Approval.Action, for key: FolderKey) async {
        if let why = await answerApproval(approval, action, digest: approval.digest, note: nil, for: key) { problem = why }
    }

    /// Deny a session's ask to be archived (#773): the mark goes and the session stays.
    func keepSession(_ agent: Agent) async {
        let denial = ArchiveActions.denial(for: agent)
        await settleApproval(denial.approval, .deny, for: denial.folder)
    }

    func setDiskSpace(_ lines: DiskThresholds, for key: FolderKey) async {
        do {
            var summary = try await client(for: key.host).call(
                DaemonAPI.Method.foldersSetDiskSpace,
                DaemonAPI.SetDiskSpaceRequest(folder: key.folder, diskSpace: lines),
                returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            upsert(summary)
        } catch {
            problem = describe(error)
        }
    }

    private func callFolder(_ method: String, _ key: FolderKey,
                             then: ((DaemonAPI.FolderSummary) -> Void)? = nil) async {
        do {
            var summary = try await client(for: key.host).call(method, DaemonAPI.FolderRequest(folder: key.folder),
                                                                returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            upsert(summary)
            then?(summary)
            settleFolderSelection()
        } catch {
            // A refusal here is the daemon naming the agents to stop, which is exactly
            // what the user needs to read.
            problem = describe(error)
        }
    }

    func upsert(_ summary: DaemonAPI.FolderSummary) {
        work.upsert(summary)
        // The one thing filing a folder means to a window and to nothing else: the
        // folder being read may have just been archived, or may have just arrived.
        settleFolderSelection()
    }

    // MARK: Connecting

    /// The daemon exits when it has nothing in hand and nobody watching, so a window
    /// that has been sitting idle will outlive it. Noticing and going back is ordinary,
    /// not an error worth showing.
    private func lostConnection() async {
        isConnected = false
        // Let go of on purpose (#344), not lost: nothing to say or go back for.
        guard !needsFirstRun else { return }
        // Said at once, everywhere this Mac's host is the target (#83), rather than
        // when the next action has waited out a connect.
        if hosts.macDownSince == nil { hosts.macDownSince = Date() }
        listening = nil
        // The daemon forgot these screens with the connection. Marked, so they attach
        // again when it comes back rather than looking alive and being dead (#401).
        for shell in shellClients(on: .mac) { shell.lostConnection() }
        await reconnect()
    }

    /// Connect, and keep trying if that fails, which is what the window does when it
    /// opens.
    func stayConnected() async {
        routeSharedFiles()
        // Nothing to connect to, and nothing to start: the first run says where.
        guard !needsFirstRun else { return }
        wakeAndNetwork.start { [weak self] reason in self?.goBackNow(reason) }
        await connect()
        if !isConnected { await reconnect() }
    }

    /// The Mac woke or the network changed (#82): a wait in progress ends now, and a
    /// connection the window still believes in is asked whether it is alive, since a
    /// sleep can leave one dead without a word. A try already in flight is left alone.
    private func goBackNow(_ reason: ReconnectTriggers.Reason) {
        let host = backoff.nudge()
        let control = controlBackoff.nudge()
        WakeAndNetwork.log.info("reconnect: \(reason.rawValue, privacy: .public): host \(String(describing: host), privacy: .public), control plane \(String(describing: control), privacy: .public)")
        guard host == .idle, isConnected, !checkingAfterWake else { return }
        checkingAfterWake = true
        Task {
            // One that does not answer is closed; with a control plane, the connection
            // under every host's goes too, so nothing dials back over the dead one.
            if await !client.answers(within: .seconds(4)) { controlLink?.disconnect() }
            checkingAfterWake = false
        }
    }

    /// The move across (058, US6) is letting the old daemon go: the window does not go
    /// back for it, or it would start it again under the host launchd is starting.
    @ObservationIgnored private var holdingForMove = false

    /// First run has a control plane (058): from here the window is its client, and
    /// this Mac's host is reached through it.

    /// First run has paired with a control plane elsewhere (058, frame C).
    func adopt(_ endpoint: ControlConfig.Endpoint) async {
        guard let link = ControlConfig.link(endpoint) else { return }
        controlLink = link
        client = DaemonClient(link: hostLink(.mac, through: link))
        keptHost = nil
        // Made with the client just replaced, they would ask it for ever (#62).
        serverFilesByHost[.mac] = nil
        serverPicturesByHost[.mac] = nil
        needsFirstRun = false
        await stayConnected()
    }

    /// Forget This Mac has gone through (#344): the control plane no longer knows this
    /// window, and its pairing is gone from disk. Everything dialled through it stops, and
    /// the window asks how to work again, as at first run.
    func leaveControlPlane() {
        needsFirstRun = true
        reconnecting?.cancel()
        reconnecting = nil
        controlWatch?.cancel()
        controlWatch = nil
        listening?.cancel()
        listening = nil
        controlHosts = [:]
        hosts.controlled = [:]
        controlLink?.disconnect()
        controlLink = nil
        controlPlaneHosts = nil
        controlPlaneListed = false
        controlPlaneReachable = false
        controlPlaneMissed = false
        directHost = nil
        keptHost = nil
        KeptThisMacHost.forget(in: WindowDefaults.store)
        client = DaemonClient(link: UnreachableLink())
        isConnected = false
    }

    /// Keep going back until the daemon answers.
    ///
    /// One try used to be all there was, and a daemon slow to come back left a window
    /// that looked alive and never would be again. The same loop as the phone's:
    /// backing off to half a minute, and only one of it at a time.
    private func reconnect() async {
        guard reconnecting == nil else { return }
        let backoff = backoff
        backoff.trying()
        reconnecting = Task { [weak self] in
            while !Task.isCancelled {
                await backoff.wait()
                guard let self else { return }
                if self.isConnected { break }
                // Forgotten (#344): nothing to go back to until first run pairs again.
                if self.needsFirstRun { break }
                WakeAndNetwork.log.info("reconnect: trying")
                await self.connect()
                if self.isConnected {
                    WakeAndNetwork.log.info("reconnect: connected")
                    break
                }
            }
            // Back from the first wait only once this connection has lasted (#172).
            if !Task.isCancelled { backoff.connected() }
            self?.reconnecting = nil
        }
        await reconnecting?.value
    }

    func connect() async {
        if let connecting {
            await connecting.value
            return
        }
        let generation = connectGeneration + 1
        connectGeneration = generation
        let task = Task { @MainActor in
            await self.connectBody()
            // Cleared here, still on this turn, so a waiter ending does not open a
            // second flight beside one that has not finished (#285).
            if self.connectGeneration == generation { self.connecting = nil }
        }
        connecting = task
        await task.value
    }

    private func connectBody() async {
        // Never the old way's daemon while first run is still deciding the new way, or
        // while the move across is handing it to launchd.
        guard !needsFirstRun, !holdingForMove else { return }
        // The control plane's own client, started whether or not this Mac's host
        // answers: a host can be down while the control plane is up (frame H).
        if controlLink != nil { watchControlHosts() }
        // This Mac's host has an id of its own (#1496): `reach` connects it, as the control
        // plane's other hosts, and no host is `.mac` to dial.
        if let mine = macHostElsewhere {
            hosts.macDownSince = nil
            missesWithHostUp = 0
            isConnected = await controlHosts[mine]?.isConnected ?? false
            return
        }
        do {
            try await client.connect()
            isConnected = true
            hosts.macDownSince = nil
            missesWithHostUp = 0
            problem = nil
            await client.setCredentialLender { [weak self] wanted in
                await self?.answerMacCredentialWanted(wanted) ?? false
            }
            await lendToThisMac()
            listen()
            // A new connection watches nothing; what the files pane was watching is asked
            // for again, and what it shows is read again (#62).
            startPresence()
            presence?.connected()
            // With a deadline on each call: this runs inside the reconnect loop, and a reply
            // lost to the host restarting held the loop, and the window, for good (073).
            await DaemonClient.$patience.withValue(.seconds(20)) {
                await serverFilesByHost[.mac]?.reconnected()
                await refreshEverything()
                for shell in shellClients(on: .mac) { await shell.reattachIfLost() }
            }
            // Servers the control plane reaches are its clients. HostSet is the old
            // path, and it stays only while this window has no control plane (R7).
            if controlLink == nil { startHosts() }
            watchControlHosts()
        } catch {
            isConnected = false
            // Neither way reached it: nor is it reached directly any more (#1118).
            wentDirect(.mac, false)
            if hosts.macDownSince == nil { hosts.macDownSince = Date() }
            // A control plane that cannot be reached is the strip, not an alert.
            if controlLink == nil { problem = describe(error) }
            // The control plane answers and says the host is up, and the host still does
            // not: the connection under them is wedged on the way to the host (#445). Let
            // it go, so the next try dials a fresh one rather than waiting on it for good.
            if macHostUpAtControlPlane {
                missesWithHostUp += 1
                if missesWithHostUp >= 2 {
                    missesWithHostUp = 0
                    WakeAndNetwork.log.info("reconnect: this Mac's host is up and not reached; dialling the control plane afresh")
                    controlLink?.disconnect()
                }
            } else {
                missesWithHostUp = 0
            }
        }
    }

    private func listen() {
        listening?.cancel()
        let notifications = client.notifications()
        // Detached, so that reading each notification — the JSON of a tool call's
        // output can be a hundred kilobytes — happens off the main actor, and only
        // what it means is applied there. Each one is applied before the next is
        // read, so the order the daemon said them in is the order they land.
        let shown = work.shown
        listening = Task.detached(priority: .userInitiated) { [weak self] in
            for await notification in notifications {
                let update = AgentsModel.read(notification.method, notification.params, showing: shown.id, alsoShowing: shown.also)
                await self?.received(notification.method, notification.params, update)
            }
            // The daemon went, or the connection did. A list that has quietly stopped
            // being true is worse than an empty one, so the window says so and goes
            // back for another connection, starting the daemon again if it has to.
            await self?.lostConnection()
        }
    }

    private func received(_ method: String, _ params: JSONValue?, _ update: AgentsModel.Update?) async {
        // What every notification about the work means is written once, in the kit,
        // so the window and the phone cannot drift apart. What is left here is the
        // Mac's own: the shells and terminals a phone has no business with.
        if let update {
            // A folder added has workflows no notification brings (#1798).
            let added = work.addsFolder(update)
            work.apply(update)
            applyToPopouts(update)
            if case .folderChanged = update { settleFolderSelection() }
            if added { await refreshWorkflows() }
            // And the other way: every server hears what the Mac learned about a plan it
            // relays (052, R6). Only a newer word changes anything there.
            if case .runtimeAllowancesChanged(let allowances) = update { await sendSharedAllowances(allowances) }
            if case .attention(let change) = update { await notifier.apply(change) }
            return
        }

        switch method {
        case DaemonAPI.Notification.selfUpdateChanged:
            if let state = try? params?.decode(DaemonAPI.SelfUpdate.self) { selfUpdate = state }
        case DaemonAPI.Notification.shellOutput:
            // Read rather than decoded: this one arrives whenever a shell prints, and
            // the general path would re-encode every byte of it here on the main
            // actor before decoding it again. See `ShellOutputNotification`.
            guard let params, let notification = DaemonAPI.ShellOutputNotification(params: params) else { return }
            shellClients[ShellKey(agentID: notification.agentID, shell: notification.shell)]?
                .received(notification.bytes, at: notification.offset)

        case DaemonAPI.Notification.shellStateChanged:
            guard let notification = try? params?.decode(DaemonAPI.ShellStateNotification.self) else { return }
            shellClients[ShellKey(agentID: notification.agentID, shell: notification.shell)]?.received(notification.state)

        case DaemonAPI.Notification.draftOptions:
            guard let notification = try? params?.decode(DaemonAPI.DraftOptionsNotification.self) else { return }
            settleDraft(notification)

        case DaemonAPI.Notification.filesChanged:
            // This Mac's host is read through `files/*` too (058, R11), and says so here
            // when a watched folder changes. Dropped, its pane never followed the agent.
            guard let change = try? params?.decode(DaemonAPI.FilesChangedNotification.self) else { return }
            serverFiles(.mac).apply(change)

        case DaemonAPI.Notification.runtimeChanged:
            await refreshRuntimes()

        case DaemonAPI.Notification.runtimesAccountProfilesChanged:
            guard let list = try? params?.decode([AccountProfile].self) else { return }
            accountProfiles = list

        case DaemonAPI.Notification.runtimeAccountChanged:
            guard let account = try? params?.decode(RuntimeAccount.self) else { return }
            accounts[account.runtimeID] = account
            if account.state == .ready { signInsPutAway.remove(account.runtimeID) }

        case DaemonAPI.Notification.signInNeeded:
            // A turn, a queued prompt or a pick-up refused with nobody waiting on the
            // call, so this is the only place the window hears it.
            guard let needed = try? params?.decode(DaemonAPI.SignInNeeded.self),
                  !signInsPutAway.contains(needed.runtimeID), signInRuntimeID == nil else { return }
            signInRuntimeID = needed.runtimeID

        case DaemonAPI.Notification.cloneChanged:
            guard let change = try? params?.decode(DaemonAPI.CloneNotification.self) else { return }
            clones.removeAll { $0.id == change.clone.id }
            if !change.finished { clones.append(change.clone) }

        case DaemonAPI.Notification.clientPermissionsChanged:
            guard let settings = try? params?.decode(ClientPermissionSettings.self) else { return }
            let changed = clientPermissions != settings
            clientPermissions = settings
            // Remote and web clients set the Mac's host directly. Keep connected servers
            // in step just as the Settings control did before the move under the prompt.
            if changed { Task { await pushClientPermissionsToServers(settings) } }

        case DaemonAPI.Notification.personChanged:
            guard let settings = try? params?.decode(PersonSettings.self) else { return }
            person = settings

        case DaemonAPI.Notification.preferencesChanged:
            guard let preferences = try? params?.decode(DaemonAPI.DisplayPreferences.self) else { return }
            displayMirror.hostSaid(preferences)

        case DaemonAPI.Notification.sandboxChanged:
            guard let settings = try? params?.decode(SandboxSettings.self) else { return }
            sandboxSettings = settings

        case DaemonAPI.Notification.daemonPolicyStateChanged:
            guard let state = try? params?.decode(DaemonAPI.PolicyState.self) else { return }
            policyState = state
            // The marks on the lists change with the policy: read them again (#998).
            Task {
                async let runtimes: Void = refreshRuntimes()
                async let sandbox: Void = refreshSandboxSettings()
                async let cost: Void = refreshCostState()
                async let passThrough: Void = refreshPassThrough()
                _ = await (runtimes, sandbox, cost, passThrough)
            }

        case DaemonAPI.Notification.writeFailed:
            // Something nobody was waiting on was not kept: a full disk, or a folder
            // refusing writes. Said, so it is not found out at the next restart (#88).
            guard let failure = try? params?.decode(WriteFailure.self) else { return }
            problem = failure.message

        default:
            break
        }
    }

    // MARK: Asking

    // MARK: Servers (037)

    @ObservationIgnored private var hostsStarted = false
    /// Each server's end of `files/*`, made when first wanted (037).
    @ObservationIgnored private var serverFilesByHost: [MachineRef: RemoteFiles] = [:]

    @ObservationIgnored private var serverPicturesByHost: [MachineRef: ServerPictures] = [:]

    /// A server's pictures for its live pages, kept while the app runs (037).
    func serverPictures(_ host: MachineRef) -> ServerPictures {
        if let known = serverPicturesByHost[host] { return known }
        let made = ServerPictures(files: serverFiles(host))
        serverPicturesByHost[host] = made
        return made
    }

    /// How the files pane reads a server agent's folder: through that server's daemon,
    /// because the folder is not on this Mac.
    func serverFiles(_ host: MachineRef) -> RemoteFiles {
        if let known = serverFilesByHost[host] { return known }
        let made = RemoteFiles(client: client(for: host))
        serverFilesByHost[host] = made
        return made
    }

    /// Once, after the Mac's own daemon has answered: the servers come after the Mac,
    /// so a slow server never holds up the window's first list.
    private func startHosts() {
        guard !hostsStarted else { return }
        hostsStarted = true
        let shown = work.shown
        hosts.onNotification = { [weak self] host, method, params in
            // Read off the main actor, as the Mac's own are (#203).
            let update = await Task.detached { AgentsModel.read(method, params, showing: shown.id, alsoShowing: shown.also) }.value
            await self?.receivedFromServer(host, method, params, update)
        }
        hosts.offerFor = { [weak self] id in self?.credentialOffer(id) }
        hosts.lenderFor = { [weak self] id in
            { [weak self] wanted in
                guard let model = self else { return false }
                return await model.answerCredentialWanted(wanted, on: id)
            }
        }
        hosts.toolsetWanted = { [weak self] id, runtimeID in
            guard let self else { return false }
            // One that works with no sign-in goes wherever this Mac has it (049: OpenCode's free
            // models); on an "own sign-in only" server too, since nothing is lent to install it.
            if RuntimeLaunchCatalog.launch(for: runtimeID).lentSignIn != nil { return self.hasOnThisMac(runtimeID) }
            guard !(self.hosts.host(id)?.ownSignInOnly ?? false) else { return false }
            // A key in Settings, or this Mac's own sign-in relayed (047).
            return self.credentials.record(runtimeID) != nil
        }
        hosts.onConnected = { [weak self] host in
            await self?.refreshServer(host)
            await self?.reattachShells(on: host)
        }
        hosts.onReachability = { [weak self] server, online in
            guard let self else { return }
            _ = try? await self.client.call(DaemonAPI.Method.eventsServer,
                                            DaemonAPI.ServerReachabilityChange(server: server, online: online),
                                            returning: Event.self)
        }
        hosts.start()
    }

    /// Follow the control plane's hosts: a client for each one other than this Mac's,
    /// listed now and kept as hosts come and go (058, US3).
    private func watchControlHosts() {
        guard let controlLink, controlWatch == nil else { return }
        let backoff = controlBackoff
        controlWatch = Task { [weak self] in
            let control = DaemonClient(link: controlLink.controlLink)
            self?.controlRequests = control
            while !Task.isCancelled {
                // Before the list comes, and while the control plane stays away (#1481).
                await self?.reachKeptHost(controlLink)
                backoff.trying()
                let answered: Bool
                do {
                    try await control.connect(startIfNeeded: false, timeout: .seconds(3))
                    answered = true
                } catch {
                    // Refused as suspended (#1002): the window shows only that, and dials again.
                    self?.signIn.refused(error)
                    answered = false
                }
                if answered {
                    backoff.connected()
                    self?.controlPlaneDidAnswer()
                    await self?.syncControlHosts(control)
                    await self?.loadKept(control)
                    await self?.people.connected(control)
                    await self?.signIn.connected(control)
                    for await note in control.notifications() {
                        if await self?.people.heard(note.method, note.params, on: control) == true { continue }
                        if self?.signIn.heard(note.method, note.params) == true { continue }
                        if await self?.userScope.heard(note.method, note.params, on: control) == true {
                            // The host writes what it is sent a moment later: its panes read again.
                            try? await Task.sleep(for: .milliseconds(500))
                            await self?.refreshCostState()
                            await self?.refreshLeases()
                            continue
                        }
                        switch note.method {
                        case DaemonAPI.Notification.controlKeptChanged, DaemonAPI.Notification.controlKeptDelivered:
                            await self?.heardKept(note.method, note.params)
                        case DaemonAPI.Notification.controlHostChanged:
                            self?.hostCameOnline(note.params)
                            await self?.syncControlHosts(control)
                        case DaemonAPI.Notification.controlThisMacHostChanged:
                            // The join file changed and the host list may not have (#303).
                            await self?.refreshMacHostJoin(control)
                        default:
                            break
                        }
                    }
                    if !Task.isCancelled { self?.controlPlaneWent() }
                } else if !Task.isCancelled {
                    self?.controlPlaneWent()
                }
                await backoff.wait()
            }
        }
    }

    /// A host is back, said by the control plane: a window still waiting out its backoff
    /// goes back now, rather than up to half a minute after the host returned (#172). One
    /// dial each, when there is something to reach, in place of a dial every 100 ms.
    private func hostCameOnline(_ params: JSONValue?) {
        guard !isConnected, DaemonAPI.ControlMachine.answers(params?["state"]?.stringValue) else { return }
        backoff.nudge()
    }

    private func controlPlaneDidAnswer() {
        controlPlaneReachable = true
        controlPlaneMissed = false
    }

    private func controlPlaneWent() {
        guard controlLink != nil else { return }
        people.went()
        signIn.went()
        controlPlaneReachable = false
        controlPlaneMissed = true
    }

    /// The host's own join changed (#303). A host that just connected is dialled now,
    /// rather than at the end of the window's backoff.
    private func refreshMacHostJoin(_ control: DaemonClient) async {
        guard let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self) else { return }
        let connected = status.thisMacHost?.connected == true
        macHostJoin = status.thisMacHost
        controlPlaneMachine = status.machineID
        if connected, !isConnected { backoff.nudge() }
    }

    /// Start on the strip of a host linked to a stopped workspace (#691): the control plane
    /// asks its provider, and says how it goes as `control/hostChanged`.
    func startHost(_ host: MachineRef) async {
        guard let controlRequests, !hostsBeingStarted.contains(host) else { return }
        hostsBeingStarted.insert(host)
        defer { hostsBeingStarted.remove(host) }
        do {
            _ = try await controlRequests.call(DaemonAPI.Method.hostsStart, DaemonAPI.MachineRequest(host: host))
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached, so \(hosts.label(host)) can’t be started."
        }
    }

    /// Approve or Deny on a machine's card (#994): a refusal is the window's alert.
    func answerJoin(_ request: DaemonAPI.JoinRequest, approve: Bool) async {
        if let refused = await people.answer(request, approve: approve, on: controlRequests) {
            problem = refused
        }
    }

    /// Approve or Deny on a GitHub sign-in's card (#995): a refusal is the window's alert.
    func answerSignIn(_ request: DaemonAPI.SignInRequest, approve: Bool, code: String? = nil) async {
        if let refused = await signIn.answer(request, approve: approve, code: code, on: controlRequests) {
            problem = refused
        }
    }

    /// Approve, Deny or Send on a channel link's card (#1762): a refusal is the window's alert.
    func answerLink(_ request: DaemonAPI.ChannelLinkRequest, approve: Bool, to person: String?) async {
        if let refused = await people.answerLink(request, approve: approve, to: person, on: controlRequests) {
            problem = refused
        }
    }

    // MARK: Kept for a stopped workspace (#691 US3)

    /// Whether a prompt or a start for `host` now is kept rather than refused: it is linked
    /// to a workspace that is stopped or starting, and starts when used (FR-020).
    func startsWhenUsed(_ host: MachineRef) -> Bool {
        guard let row = hosts.controlRows[host], row.workspace?.startWhenUsed == true else { return false }
        return row.state == "stopped" || row.state == "starting"
    }

    /// The prompts kept for one agent, oldest first.
    func kept(for agentID: UUID) -> [DaemonAPI.KeptRequest] {
        kept.filter { !$0.isStart && $0.agentID == agentID }
    }

    /// The agent starts kept for one folder.
    func keptStarts(on host: MachineRef, in folder: URL) -> [DaemonAPI.KeptRequest] {
        let folder = Folder.standardize(folder)
        return kept.filter { $0.isStart && $0.host == host && $0.folder.map(Folder.standardize) == folder }
    }

    /// A kept request, as the control plane said it when it answered: shown at once,
    /// before `control/keptChanged` comes.
    @discardableResult
    func noteKept(_ error: JSONRPCError) -> DaemonAPI.KeptRequest? {
        guard let said = try? error.data?.decode(DaemonAPI.KeptRequest.self) else { return nil }
        if !kept.contains(where: { $0.id == said.id }) { kept.append(said) }
        return said
    }

    /// Sends a prompt or a start for a host whose link is closed while it is stopped, to the
    /// control plane, which keeps it. What was kept, or nil with `problem` saying why not.
    private func keepThroughControl(_ host: MachineRef, _ method: String, _ params: some Encodable) async -> DaemonAPI.KeptRequest? {
        guard let controlRequests, let params = try? JSONValue.encoding(params) else {
            problem = "Not sent — the control plane can’t be reached."
            return nil
        }
        do {
            _ = try await controlRequests.call(DaemonAPI.Method.hostsKeep,
                                               DaemonAPI.KeepRequest(host: host, method: method, params: params))
            return nil
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.kept {
            return noteKept(error)
        } catch let error as JSONRPCError {
            problem = error.message
            return nil
        } catch {
            problem = "Not sent — the control plane can’t be reached."
            return nil
        }
    }

    private func loadKept(_ control: DaemonClient) async {
        // A control plane without providers keeps nothing.
        kept = (try? await control.call(DaemonAPI.Method.hostsListKept, returning: DaemonAPI.KeptList.self))?.kept ?? []
    }

    private func heardKept(_ method: String, _ params: JSONValue?) async {
        if method == DaemonAPI.Notification.controlKeptChanged {
            kept = (try? params?.decode(DaemonAPI.KeptList.self))?.kept ?? []
            return
        }
        // A kept start reached its host: the agent it made opens, if this window showed it.
        guard let delivered = try? params?.decode(DaemonAPI.KeptDelivered.self),
              keptStartsShown.remove(delivered.id) != nil, let agentID = delivered.agentID else { return }
        await refreshServer(delivered.host)
        justStarted = agentID
        selection = agentID
    }

    /// × on a kept prompt: it isn't sent, and the workspace keeps starting (US3 AS3).
    func dropKept(_ request: DaemonAPI.KeptRequest) async {
        kept.removeAll { $0.id == request.id }
        await keptCall(DaemonAPI.Method.hostsDropKept, request)
    }

    /// Try Again on one that wasn't sent: kept again, and the workspace started.
    func retryKept(_ request: DaemonAPI.KeptRequest) async {
        await keptCall(DaemonAPI.Method.hostsRetryKept, request)
    }

    private func keptCall(_ method: String, _ request: DaemonAPI.KeptRequest) async {
        guard let controlRequests else { return }
        do {
            _ = try await controlRequests.call(method, DaemonAPI.KeptRequestID(host: request.host, id: request.id))
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached."
        }
    }

    private func syncControlHosts(_ control: DaemonClient) async {
        guard let controlLink,
              let listed = try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlMachine].self),
              let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        else { return }
        controlPlaneHosts = listed
        if let controlKey = Self.controlKey {
            KeptThisMacHost.keep(from: listed, controlKey: controlKey, in: WindowDefaults.store)
            keptHost = KeptThisMacHost.read(controlKey: controlKey, from: WindowDefaults.store)
        }
        // An ask no longer waiting may be asked again later, once taken back (#1122).
        gitAsksAnswered.formIntersection(GitLendAsk.waiting(in: listed))
        controlPlaneListed = true
        controlPlaneName = status.name
        macHostJoin = status.thisMacHost
        controlPlaneMachine = status.machineID
        // `.mac` is `client`, already. Every other host, including another machine's
        // home host, gets a client of its own on the same link.
        // A relay host (`agents-relay`) runs no agents: nothing to reach there.
        let others = listed.filter { $0.id != .mac && $0.runsAgents }
        hosts.controlled = Dictionary(uniqueKeysWithValues: others.map { ($0.id, (label: $0.name, online: $0.answers)) })
        hosts.controlRows = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0) })
        for host in others where host.answers {
            await reach(host, through: controlLink)
        }
        // One offline or stopped when this window started lists what it last did, greyed, as
        // one that went while it ran (#962).
        for host in others where !host.answers && !work.holdsFolders(of: host.id) {
            if let heard = try? await control.call(DaemonAPI.Method.hostsLastHeard, DaemonAPI.MachineRequest(host: host.id),
                                                   returning: DaemonAPI.MachineLastHeard.self) {
                work.takeLastHeard(heard)
            }
        }
        // A host removed from the control plane leaves the window too: its folders and
        // agents are no longer anybody's to show here (FR-014; they carry on where they are).
        for id in controlHosts.keys where !others.contains(where: { $0.id == id }) {
            await controlHosts.removeValue(forKey: id)?.disconnect()
            work.replaceFolders([], from: id)
            work.replaceAgents([], from: id)
        }
    }

    /// A client for one of the control plane's hosts, connected: first directly over its
    /// local socket when it is on this Mac (#1118), else through the control plane.
    private func reach(_ host: DaemonAPI.ControlMachine, through controlLink: ControlLink) async {
        let server = controlHosts[host.id]
            ?? DaemonClient(link: hostLink(host.id, through: controlLink, onThisMac: host.machineID == MachineID.current))
        controlHosts[host.id] = server
        guard await !server.isConnected else { return }
        guard (try? await server.connect(startIfNeeded: false, timeout: .seconds(5))) != nil else { return }
        let id = host.id
        await server.setCredentialLender { [weak self] wanted in
            await self?.answerCredentialWanted(wanted, on: id) ?? false
        }
        _ = try? await server.call(DaemonAPI.Method.credentialsOffer, credentialOffer(id))
        let shown = work.shown
        Task.detached(priority: .userInitiated) { [weak self] in
            for await note in server.notifications() {
                // Read here, off the main actor, and applied there (#203).
                let update = AgentsModel.read(note.method, note.params, showing: shown.id, alsoShowing: shown.also)
                await self?.receivedFromServer(id, note.method, note.params, update)
            }
        }
        await refreshServer(id)
        await reattachShells(on: id)
        // This Mac's host by an id of its own (#1496): what is this Mac's own comes from it.
        if id == macHostElsewhere {
            isConnected = true
            hosts.macDownSince = nil
            await refreshThisMacsOwn()
        }
        // Presence starts with this Mac's host; a control plane with none starts it
        // with its first other host.
        startPresence()
        presence?.connected()
    }

    /// The control plane's key, with a control plane elsewhere.
    private static var controlKey: Data? {
        guard case .remote(let membership)? = ControlConfig.endpoint else { return nil }
        return membership.controlKey
    }

    /// This Mac's host as the control plane last listed it (#1481): reached at launch over
    /// its local socket, before the list comes, so its agents work with the control plane
    /// away. Tried again while the control plane stays away, until it answers.
    private func reachKeptHost(_ controlLink: ControlLink) async {
        guard !controlPlaneListed, let kept = keptHost else { return }
        if let server = controlHosts[kept.id], await server.isConnected { return }
        if hosts.controlled[kept.id] == nil {
            hosts.controlled[kept.id] = (label: kept.name, online: false)
            hosts.controlRows[kept.id] = kept
        }
        await reach(kept, through: controlLink)
        if let server = controlHosts[kept.id], await server.isConnected {
            hosts.controlled[kept.id] = (label: kept.name, online: true)
        }
    }

    /// Whether this Mac's own runtime is installed and can start (049: what puts OpenCode on
    /// its servers).
    func hasOnThisMac(_ runtimeID: String) -> Bool {
        runtimes.first { $0.id == runtimeID }?.availability.isAvailable ?? false
    }

    private func receivedFromServer(_ host: MachineRef, _ method: String, _ params: JSONValue?,
                                    _ update: AgentsModel.Update?) async {
        // This Mac's host by an id of its own (#1496): what it says of this Mac is the
        // window's own, as `.mac`'s is.
        if host == macHostElsewhere, Self.aboutThisMac.contains(method) {
            await received(method, params, update)
            return
        }
        // What is about the whole of a daemon rather than its work is the Mac's alone in
        // the model: a server's spending is kept beside it, and a server's wakefulness,
        // modes and notices have no place in this window (037).
        switch method {
        case DaemonAPI.Notification.runtimesAllowancesChanged:
            // A server's runtimes are its own; this window shows the Mac's (065). What it
            // learned about a plan the Mac relays is the Mac's to know too (052, R6): its
            // Codex spends the Mac's ChatGPT plan, so a refusal there is the Mac's plan out.
            let shared = (try? params?.decode(RuntimeAllowances.self))?.shared ?? []
            if !shared.isEmpty {
                _ = try? await macClient.call(DaemonAPI.Method.poolApplyAllowances,
                                           DaemonAPI.ApplyAllowances(states: shared), returning: Bool.self)
            }
            return
        case DaemonAPI.Notification.costChanged:
            serverCosts[host] = try? params?.decode(DaemonAPI.CostState.self)
            noteServerSpent(host)
            return
        case DaemonAPI.Notification.diskChanged:
            serverDisks[host] = try? params?.decode(DiskState.self)
            return
        case DaemonAPI.Notification.resourcesChanged, DaemonAPI.Notification.eventsChanged,
             DaemonAPI.Notification.mcpHostedChanged:
            // These describe the Mac's shared resources and event feed in this window.
            return
        case DaemonAPI.Notification.credentialRefused:
            // The key in Settings was refused: Settings turns red, and says why (043).
            if let refused = try? params?.decode(DaemonAPI.CredentialRefused.self) {
                if refused.lent { credentials.markRefused(refused.runtime) }
                // This Mac's own sign-in was refused through the relay (056): sign in here.
                if refused.relayed == true { signInRuntimeID = refused.runtime }
                // A key this Mac's sign-in file lent (049): its sheet names the command.
                if refused.borrowed == true { signInRuntimeID = refused.runtime }
            }
            return
        case DaemonAPI.Notification.wakeChanged, DaemonAPI.Notification.modesChanged,
             DaemonAPI.Notification.attentionChanged, DaemonAPI.Notification.storeNotesChanged,
             DaemonAPI.Notification.milestonesChanged, DaemonAPI.Notification.preferencesChanged,
             DaemonAPI.Notification.backupsChanged:
            // The milestones and display choices are the person's, kept on the Mac's own
            // host (#984, #1033). Settings ▸ Machines ▸ This Mac ▸ Backups is this Mac's (#1810).
            return
        default:
            break
        }
        if let update {
            let added = work.addsFolder(update, from: host)
            work.apply(update, from: host)
            applyToPopouts(update)
            if method == DaemonAPI.Notification.folderChanged { settleFolderSelection() }
            if added { await refreshWorkflows() }
            return
        }
        // A server's shells print to this window the same way the Mac's do. Nothing
        // else a server says is about this window: its devices, runtimes and clones
        // are asked for when they are wanted.
        switch method {
        case DaemonAPI.Notification.runtimeChanged:
            await refreshServerRuntimes(host)
        case DaemonAPI.Notification.filesChanged:
            guard let change = try? params?.decode(DaemonAPI.FilesChangedNotification.self) else { return }
            serverFiles(host).apply(change)
        case DaemonAPI.Notification.shellOutput, DaemonAPI.Notification.shellStateChanged,
             DaemonAPI.Notification.draftOptions, DaemonAPI.Notification.writeFailed:
            await received(method, params, nil)
        default:
            break
        }
    }

    /// Everything a server has, after it connects or comes back. Replaces only that
    /// server's own, so the Mac's list is never emptied by a server re-listing, and
    /// whatever happened while the Mac was away is simply what the server now says.
    func refreshServer(_ host: MachineRef) async {
        let server = client(for: host)
        // A new connection watches nothing; what the files pane was watching is asked
        // for again, and everything it shows is read again.
        await serverFilesByHost[host]?.reconnected()
        await refreshServerRuntimes(host)
        await refreshServerDisk(host)
        // And its retention settings (051).
        if let settings = work.retentionState?.settings {
            _ = try? await server.call(DaemonAPI.Method.retentionSet,
                                       DaemonAPI.RetentionSetRequest(settings: settings, confirmed: true),
                                       returning: DaemonAPI.RetentionSetResult.self)
        }
        // And Cursor/Grok permission mode (061).
        _ = try? await server.call(DaemonAPI.Method.clientPermissionsSet, clientPermissions,
                                   returning: ClientPermissionSettings.self)
        // And how many workflows may run (#506).
        if let workflowLimit {
            _ = try? await server.call(DaemonAPI.Method.workflowsSetLimit, workflowLimit,
                                       returning: WorkflowLimitSettings.self)
        }
        // And what agents call the person, as this Mac resolves it (#121).
        if let person {
            _ = try? await server.call(DaemonAPI.Method.personSet, person.resolved(), returning: PersonSettings.self)
        }
        // And each runtime's sandbox default (064).
        _ = try? await server.call(DaemonAPI.Method.sandboxSet, sandboxSettings,
                                   returning: SandboxSettings.self)
        // And what the Mac knows of the plans it relays (052, R6): a server's Codex
        // spends the Mac's ChatGPT plan, so the Mac's word that it is out is the server's.
        if let allowances = work.runtimeAllowances {
            let shared = allowances.shared ?? []
            if !shared.isEmpty {
                _ = try? await server.call(DaemonAPI.Method.poolApplyAllowances,
                                           DaemonAPI.ApplyAllowances(states: shared), returning: Bool.self)
            }
        }
        // The Mac's limits hold on every server too; each keeps to them on its own.
        if let limits = work.costState?.limits {
            serverCosts[host] = try? await server.call(
                DaemonAPI.Method.costSetLimits,
                DaemonAPI.SetLimitsRequest(copying: limits),
                returning: DaemonAPI.CostState.self)
        } else {
            serverCosts[host] = try? await server.call(DaemonAPI.Method.costState, returning: DaemonAPI.CostState.self)
        }
        if let listed = try? await server.listAgents(DaemonAPI.ListRequest(includeArchived: false, lean: true)) {
            let live = Set(listed.map(\.id))
            work.replaceAgents(listed + work.agents.filter { $0.host == host && $0.state == .archived && !live.contains($0.id) },
                               from: host)
        }
        if let listed = try? await server.call(DaemonAPI.Method.foldersList, DaemonAPI.FoldersListRequest(),
                                               returning: [DaemonAPI.FolderSummary].self) {
            work.replaceFolders(listed, from: host)
            hosts.noteFolders(host, listed: listed)
            settleFolderSelection()
        }
        // Its folders' MCP servers, for their rows in the sidebar (#753).
        if let health = try? await server.call(DaemonAPI.Method.mcpHealth, Optional<String>.none,
                                               returning: DaemonAPI.MCPHealthSnapshot.self) {
            work.replaceMCPHealth(health, from: host)
        }
        let theirs = Set(work.agents.filter { $0.host == host }.map(\.id))
        if let listed = try? await server.call(DaemonAPI.Method.permissionsPending,
                                               returning: [PermissionRequest].self) {
            work.replacePermissions(work.permissions.filter { !theirs.contains($0.agentID) } + listed)
        }
        if let listed = try? await server.call(DaemonAPI.Method.elicitationsPending,
                                               returning: [ElicitationRequest].self) {
            work.replaceElicitations(work.elicitations.filter { !theirs.contains($0.agentID) } + listed)
        }
        if let watching = selection, theirs.contains(watching) { await loadTranscript() }
        for chat in popouts.values where theirs.contains(chat.id) { await loadTranscript(of: chat) }
    }

    /// What a host says about the whole of this Mac rather than its work (#1496).
    private static let aboutThisMac: Set<String> = [
        DaemonAPI.Notification.runtimesAllowancesChanged, DaemonAPI.Notification.costChanged,
        DaemonAPI.Notification.resourcesChanged, DaemonAPI.Notification.eventsChanged,
        DaemonAPI.Notification.mcpHostedChanged, DaemonAPI.Notification.wakeChanged,
        DaemonAPI.Notification.selfUpdateChanged, DaemonAPI.Notification.modesChanged, DaemonAPI.Notification.storeNotesChanged,
        DaemonAPI.Notification.milestonesChanged, DaemonAPI.Notification.preferencesChanged,
        DaemonAPI.Notification.runtimeChanged, DaemonAPI.Notification.runtimeAccountChanged,
        DaemonAPI.Notification.signInNeeded, DaemonAPI.Notification.clientPermissionsChanged,
        DaemonAPI.Notification.personChanged, DaemonAPI.Notification.sandboxChanged,
        DaemonAPI.Notification.backupsChanged, DaemonAPI.Notification.runtimesAccountProfilesChanged,
        DaemonAPI.Notification.daemonPolicyStateChanged,
    ]

    /// What is this Mac's own, from this Mac's host by an id of its own (#1496). Its
    /// agents and folders come with `refreshServer`, under that id.
    private func refreshThisMacsOwn() async {
        async let runtimes: Void = refreshRuntimes()
        async let accounts: Void = refreshAccounts()
        async let cost: Void = refreshCostState()
        async let retention: Void = refreshRetentionState()
        async let clientPermissions: Void = refreshClientPermissions()
        async let sandbox: Void = refreshSandboxSettings()
        async let policy: Void = refreshPolicyState()
        async let person: Void = refreshPerson()
        async let runtimeStates: Void = refreshRuntimeAllowances()
        async let wake: Void = refreshWakeState()
        async let storeNotes: Void = refreshStoreNotes()
        async let milestones: Void = refreshMilestones()
        async let leases: Void = refreshLeases()
        async let hostedMCP: Void = refreshHostedMCP()
        async let events: Void = refreshEvents()
        async let modes: Void = refreshModes()
        async let display: Void = refreshDisplayPreferences()
        _ = await (runtimes, accounts, cost, retention, clientPermissions, sandbox, policy, person, runtimeStates, wake,
                   storeNotes, milestones, leases, hostedMCP, events, modes, display)
    }

    func refreshEverything() async {
        await refreshAgents()
        // After the agents, because a folder's counts are worked out from them and a
        // sidebar drawn before them would say every folder is empty.
        await refreshFolders()
        // The rest at once. Each is its own round trip to the daemon and none
        // depends on another, so one after the other was ten waits where the window
        // sat with a list and no conversation.
        async let runtimes: Void = refreshRuntimes()
        async let accounts: Void = refreshAccounts()
        async let workflows: Void = refreshWorkflows()
        async let pinned: Void = refreshPins()
        async let permissions: Void = refreshPermissions()
        async let elicitations: Void = refreshElicitations()
        async let attention: Void = refreshAttention()
        async let resuming: Void = refreshResuming()
        async let cost: Void = refreshCostState()
        async let retention: Void = refreshRetentionState()
        async let clientPermissions: Void = refreshClientPermissions()
        async let sandbox: Void = refreshSandboxSettings()
        async let person: Void = refreshPerson()
        async let runtimeStates: Void = refreshRuntimeAllowances()
        async let cloning: Void = refreshClones()
        async let wake: Void = refreshWakeState()
        async let storeNotes: Void = refreshStoreNotes()
        async let milestones: Void = refreshMilestones()
        async let leases: Void = refreshLeases()
        async let hostedMCP: Void = refreshHostedMCP()
        async let mcpHealth: Void = refreshMCPHealth()
        async let disk: Void = refreshDisk()
        async let events: Void = refreshEvents()
        async let modes: Void = refreshModes()
        async let display: Void = refreshDisplayPreferences()
        async let transcript: Void = loadTranscript()
        async let popped: Void = loadPoppedTranscripts()
        _ = await (popped, runtimes, accounts, workflows, pinned, permissions,
                   elicitations, attention, resuming, cost, retention, clientPermissions, cloning, wake, leases, events, modes,
                   transcript, runtimeStates, sandbox, person, disk, storeNotes, hostedMCP, mcpHealth, milestones,
                   display)
    }

    #if DEBUG
    /// `-open-agent <id>` opens that agent as a banner tapped at launch does: asked at
    /// once, before the lists, and opened once they arrive (#1055). A way to put a screen
    /// in front of a test that no accessibility action reaches, such as a link inside an
    /// event's card. Debug builds only.
    private func openFromLaunchArguments() {
        // Once: a second window opened later is not the launch.
        guard !Self.launchArgumentsOpened else { return }
        Self.launchArgumentsOpened = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-open-agent"), index + 1 < arguments.endIndex,
              let id = UUID(uuidString: arguments[index + 1]) else { return }
        openAgent(id)
    }
    private static var launchArgumentsOpened = false
    #endif

    func refreshElicitations() async {
        guard let list = try? await client.call(DaemonAPI.Method.elicitationsPending,
                                                Optional<Int>.none,
                                                returning: [ElicitationRequest].self) else { return }
        work.replaceElicitations(elicitationsOnServers + list)
    }

    /// What is held for the servers' agents, kept when the Mac's own are re-listed (037).
    private var elicitationsOnServers: [ElicitationRequest] {
        work.elicitations.filter { work.agent($0.agentID).map { $0.host != .mac } ?? false }
    }

    private var permissionsOnServers: [PermissionRequest] {
        work.permissions.filter { work.agent($0.agentID).map { $0.host != .mac } ?? false }
    }

    /// The form waiting for this agent, if there is one. Held by the daemon, so it is
    /// here whether or not this window was open when it was asked.
    var elicitationForSelection: ElicitationRequest? { work.elicitation(for: selection) }

    func refreshAgents() async {
        guard hasMacHost else { return }
        await attempt {
            // Lean: the sessions column reads none of the option and command lists, and
            // they were 4 MB of 200 agents (#107). The open chat's come with `loadWholeAgent`.
            // Live only, a page at a time (#164, #165). Archived agents come a folder at a
            // time when its Archived fold opens, or by search; the ones already here (an
            // open fold, the chat being read) are kept, and the live copy wins.
            let listed = try await self.client.listAgents(DaemonAPI.ListRequest(includeArchived: false, lean: true))
            let live = Set(listed.map(\.id))
            let archived = self.work.agents.filter { $0.host == .mac && $0.state == .archived && !live.contains($0.id) }
            self.work.replaceAgents(listed + archived, from: .mac)
            self.hasLoadedAgents = true
            self.weighGetStarted()
            Perf.sinceLaunch("first-list")
            // Whatever the list already shows was spent before this window opened, so
            // the session total starts from here rather than from the beginning of time.
        }
    }

    /// What every agent shares, for Settings ▸ Agent Configuration (054, #754), or with a
    /// folder what its `.agents` holds, for the same pages in Folder Settings.
    /// Nil when it could not be read; the page then keeps what it last had.
    func sharedSnapshot(folder: URL? = nil) async -> DaemonAPI.SharedSnapshot? {
        var snapshot: DaemonAPI.SharedSnapshot?
        _ = await attempt(quietWhenDown: true) {
            if let folder {
                snapshot = try await self.macClient.call(DaemonAPI.Method.personalShared,
                                                      DaemonAPI.SharedRequest(folder: folder.path),
                                                      returning: DaemonAPI.SharedSnapshot.self)
            } else {
                snapshot = try await self.macClient.call(DaemonAPI.Method.personalShared, Optional<String>.none,
                                                      returning: DaemonAPI.SharedSnapshot.self)
            }
        }
        return snapshot
    }

    // MARK: The catalogue (059)

    /// What a catalogue call said, or why it could not: the sheet shows either, so these
    /// do not go through `attempt`, which would put a failure in the window's banner too.
    func catalogSearch(_ query: String, marketplace: String? = nil,
                       destination: DaemonAPI.SkillDestination? = nil) async -> DaemonAPI.CatalogSearchAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.catalogSearch,
                                         DaemonAPI.CatalogSearchRequest(query: query, marketplace: marketplace,
                                                                        destination: destination),
                                         returning: DaemonAPI.CatalogSearchAnswer.self)
        } catch {
            return .init(results: [], error: Self.catalogError(error))
        }
    }

    func catalogPreview(_ result: DaemonAPI.CatalogResult,
                        for destination: DaemonAPI.SkillDestination) async -> DaemonAPI.CatalogPreviewAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.catalogPreview,
                                         DaemonAPI.CatalogPreviewRequest(result: result, destination: destination),
                                         returning: DaemonAPI.CatalogPreviewAnswer.self)
        } catch {
            return .init(preview: nil, error: Self.catalogError(error))
        }
    }

    func catalogDestinationState(_ previewID: UUID,
                                 for destination: DaemonAPI.SkillDestination) async -> DaemonAPI.DestinationState? {
        try? await macClient.call(DaemonAPI.Method.catalogDestinationState,
                               DaemonAPI.DestinationStateRequest(previewID: previewID, destination: destination),
                               returning: DaemonAPI.DestinationStateAnswer.self).destinationState
    }

    func addSkill(_ previewID: UUID, to destination: DaemonAPI.SkillDestination,
                  replace: Bool) async -> Result<DaemonAPI.ManagedSkill, DaemonAPI.CatalogError> {
        do {
            let answer = try await macClient.call(DaemonAPI.Method.skillsAdd,
                                               DaemonAPI.SkillAddRequest(previewID: previewID, destination: destination,
                                                                         replace: replace),
                                               returning: DaemonAPI.SkillAddAnswer.self)
            return .success(answer.skill)
        } catch {
            return .failure(Self.catalogError(error))
        }
    }

    /// Skills in `~/.agents/skills` or a folder's `.agents/skills`.
    func skills(at destination: DaemonAPI.SkillDestination) async -> [DaemonAPI.ListedSkill]? {
        try? await macClient.call(DaemonAPI.Method.skillsList,
                               DaemonAPI.SkillsListRequest(destination: destination),
                               returning: DaemonAPI.SkillsListAnswer.self).skills
    }

    /// Whether each added skill at a destination has an update (FR-018). Nil when it could
    /// not be asked; the page then shows no marks rather than wrong ones.
    func skillUpdates(at destination: DaemonAPI.SkillDestination) async -> [String: DaemonAPI.UpdateState]? {
        try? await macClient.call(DaemonAPI.Method.skillsCheckUpdates, DaemonAPI.SkillsListRequest(destination: destination),
                               returning: DaemonAPI.SkillUpdatesAnswer.self).updates
    }

    func skillUpdatePreview(_ name: String, at destination: DaemonAPI.SkillDestination)
        async -> Result<DaemonAPI.SkillUpdatePreviewAnswer, DaemonAPI.CatalogError> {
        do {
            return .success(try await macClient.call(DaemonAPI.Method.skillsUpdatePreview,
                                                  DaemonAPI.SkillNameRequest(destination: destination, name: name),
                                                  returning: DaemonAPI.SkillUpdatePreviewAnswer.self))
        } catch {
            return .failure(Self.catalogError(error))
        }
    }

    /// Take out a skill the app or the skills tool added; its folder goes to the Trash.
    func removeSkill(_ name: String, at destination: DaemonAPI.SkillDestination) async -> DaemonAPI.CatalogError? {
        do {
            _ = try await macClient.call(DaemonAPI.Method.skillsRemove,
                                      DaemonAPI.SkillNameRequest(destination: destination, name: name),
                                      returning: DaemonAPI.SkillRemoveAnswer.self)
            return nil
        } catch {
            return Self.catalogError(error)
        }
    }

    /// The daemon's own reason when it gave one, and "can't reach" the daemon otherwise.
    private static func catalogError(_ error: any Error) -> DaemonAPI.CatalogError {
        if let rpc = error as? JSONRPCError, rpc.code == DaemonAPI.Failure.catalogRefused,
           let reason = try? rpc.data?.decode(DaemonAPI.CatalogError.self) {
            return reason
        }
        // The organisation's policy refused it (#998): its own words, as the other clients say them.
        if let refusal = DaemonAPI.PolicyRefusal(error: error) { return .failed(refusal.line) }
        if let rpc = error as? JSONRPCError { return .failed(rpc.message) }
        return .failed(String(describing: error))
    }

    // MARK: Marketplaces (#687)

    /// The marketplaces for a kind, a folder's among them when it is the destination. Nil
    /// when the daemon could not be asked.
    func marketplaces(_ kind: DaemonAPI.CatalogKind,
                      for destination: DaemonAPI.SkillDestination?) async -> DaemonAPI.MarketplacesListAnswer? {
        try? await macClient.call(DaemonAPI.Method.marketplacesList,
                               DaemonAPI.MarketplacesListRequest(kind: kind, destination: destination),
                               returning: DaemonAPI.MarketplacesListAnswer.self)
    }

    /// Nil when added, else the daemon's reason in words.
    func addMarketplace(_ request: DaemonAPI.MarketplaceAddRequest) async -> String? {
        await marketplaceCall(DaemonAPI.Method.marketplacesAdd, request)
    }

    func removeMarketplace(_ id: String) async -> String? {
        await marketplaceCall(DaemonAPI.Method.marketplacesRemove, DaemonAPI.MarketplaceIDRequest(id: id))
    }

    func setMarketplace(_ id: String, enabled: Bool) async -> String? {
        await marketplaceCall(DaemonAPI.Method.marketplacesSetEnabled,
                              DaemonAPI.MarketplaceSetEnabledRequest(id: id, enabled: enabled))
    }

    private func marketplaceCall<P: Encodable & Sendable>(_ method: String, _ params: P) async -> String? {
        do {
            _ = try await macClient.call(method, params, returning: DaemonAPI.MarketplacesListAnswer.self)
            return nil
        } catch let rpc as JSONRPCError {
            return rpc.message
        } catch {
            return String(describing: error)
        }
    }

    // MARK: MCP catalogue (060)

    func mcpSearch(_ query: String, marketplace: String? = nil,
                   destination: DaemonAPI.SkillDestination? = nil) async -> DaemonAPI.MCPSearchAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.catalogSearch,
                                         DaemonAPI.CatalogSearchRequest(query: query, kind: .mcp, marketplace: marketplace,
                                                                        destination: destination),
                                         returning: DaemonAPI.MCPSearchAnswer.self)
        } catch {
            return .init(results: [], error: Self.mcpError(error))
        }
    }

    func mcpPreview(_ result: DaemonAPI.MCPCatalogResult,
                    for destination: DaemonAPI.SkillDestination,
                    run: DaemonAPI.MCPRunKind?) async -> DaemonAPI.MCPPreviewAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.mcpPreview,
                                         DaemonAPI.MCPPreviewRequest(result: result, destination: destination, run: run),
                                         returning: DaemonAPI.MCPPreviewAnswer.self)
        } catch {
            return .init(error: Self.mcpError(error))
        }
    }

    func mcpServers(at destination: DaemonAPI.SkillDestination) async -> DaemonAPI.MCPListAnswer? {
        try? await macClient.call(DaemonAPI.Method.mcpList,
                               DaemonAPI.MCPListRequest(destination: destination),
                               returning: DaemonAPI.MCPListAnswer.self)
    }

    /// Write one name into `secrets.env`. The value is not kept here.
    func mcpSetSecret(name: String, value: String) async -> DaemonAPI.MCPCatalogError? {
        do {
            _ = try await macClient.call(DaemonAPI.Method.mcpSetSecret,
                                     DaemonAPI.MCPSetSecretRequest(name: name, value: value),
                                     returning: DaemonAPI.MCPSetSecretAnswer.self)
            return nil
        } catch {
            return Self.mcpError(error)
        }
    }

    /// Takes a connector out of its mcp.json on `host`: a server folder's on its own
    /// host (#2199), the person's own and this Mac's folders' on this Mac's.
    func mcpRemove(_ name: String, at destination: DaemonAPI.SkillDestination,
                   forgetSecret: String?, on host: MachineRef = .mac) async -> DaemonAPI.MCPCatalogError? {
        do {
            _ = try await (host == .mac ? macClient : client(for: host)).call(DaemonAPI.Method.mcpRemove,
                                     DaemonAPI.MCPRemoveRequest(destination: destination, name: name,
                                                               forgetSecret: forgetSecret),
                                     returning: DaemonAPI.MCPRemoveAnswer.self)
            return nil
        } catch HostProblem.offline {
            // Said as the machine's, not as an add that failed (#2266).
            return .failed("\(hosts.label(host)) is offline")
        } catch let rpc as JSONRPCError where rpc.code == DaemonAPI.Failure.hostOffline {
            return .failed("\(hosts.label(host)) is offline")
        } catch {
            return Self.mcpError(error)
        }
    }

    /// Ask Again for a server's views (#191): forget the person's Show or Don't Show.
    func forgetMCPViews(_ name: String, at destination: DaemonAPI.SkillDestination) async -> Bool {
        do {
            _ = try await macClient.call(DaemonAPI.Method.mcpForgetViews,
                                      DaemonAPI.MCPViewsForgetRequest(destination: destination, name: name),
                                      returning: DaemonAPI.Empty.self)
            return true
        } catch {
            return false
        }
    }

    /// Approve the entry the row showed. A digest that no longer matches comes back as an error.
    func approveFolderMCP(_ name: String, digest: String, in folder: URL) async -> DaemonAPI.MCPCatalogError? {
        do {
            _ = try await macClient.call(DaemonAPI.Method.mcpApprove,
                                      DaemonAPI.MCPApproveRequest(destination: .folder(folder: folder.path),
                                                                  name: name, digest: digest),
                                      returning: DaemonAPI.MCPListAnswer.self)
            return nil
        } catch {
            return Self.mcpError(error)
        }
    }

    func mcpAdd(_ previewID: UUID, to destination: DaemonAPI.SkillDestination,
                secrets: [String: String], plain: [String: String],
                replace: Bool) async -> Result<DaemonAPI.ManagedMCPServer, DaemonAPI.MCPCatalogError> {
        do {
            let answer = try await macClient.call(DaemonAPI.Method.mcpAdd,
                                               DaemonAPI.MCPAddRequest(previewID: previewID, destination: destination,
                                                                       secrets: secrets, plain: plain, replace: replace),
                                               returning: DaemonAPI.MCPAddAnswer.self)
            if let server = answer.server { return .success(server) }
            return .failure(answer.error ?? .failed("no server"))
        } catch {
            return .failure(Self.mcpError(error))
        }
    }

    /// Connect to a server typed on the sheet; nothing is written (#305).
    func mcpVerify(_ server: DaemonAPI.MCPHandServer,
                   for destination: DaemonAPI.SkillDestination) async -> DaemonAPI.MCPVerifyAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.mcpVerify,
                                         DaemonAPI.MCPVerifyRequest(destination: destination, server: server),
                                         returning: DaemonAPI.MCPVerifyAnswer.self)
        } catch {
            return .init(error: Self.mcpError(error))
        }
    }

    func mcpAddByHand(_ verifyID: UUID, to destination: DaemonAPI.SkillDestination)
        async -> Result<DaemonAPI.ManagedMCPServer, DaemonAPI.MCPCatalogError> {
        do {
            let answer = try await macClient.call(DaemonAPI.Method.mcpAddByHand,
                                               DaemonAPI.MCPAddByHandRequest(verifyID: verifyID, destination: destination),
                                               returning: DaemonAPI.MCPAddAnswer.self)
            if let server = answer.server { return .success(server) }
            return .failure(answer.error ?? .failed("no server"))
        } catch {
            return .failure(Self.mcpError(error))
        }
    }

    /// Start signing in to a server that asks for OAuth (#306): the page to open, or the
    /// client the person has to give first.
    func mcpSignIn(_ target: DaemonAPI.MCPSignInTarget,
                   client: DaemonAPI.MCPSignInClient? = nil) async -> DaemonAPI.MCPSignInAnswer {
        do {
            return try await self.macClient.call(DaemonAPI.Method.mcpSignIn,
                                              DaemonAPI.MCPSignInRequest(target: target, client: client),
                                              returning: DaemonAPI.MCPSignInAnswer.self)
        } catch {
            return .init(error: "The sign-in couldn't start: the app could not reach its machine.")
        }
    }

    /// Wait on a sign-in, a while at a time: `waiting` means ask again.
    func mcpSignInWait(_ flowID: UUID) async -> DaemonAPI.MCPSignInStatus {
        do {
            return try await macClient.call(DaemonAPI.Method.mcpSignInWait, DaemonAPI.MCPSignInFlowRequest(flowID: flowID),
                                         returning: DaemonAPI.MCPSignInWaitAnswer.self).status
        } catch {
            return .failed("The app lost touch with its machine while waiting.")
        }
    }

    func mcpSignInCancel(_ flowID: UUID) async {
        _ = try? await macClient.call(DaemonAPI.Method.mcpSignInCancel, DaemonAPI.MCPSignInFlowRequest(flowID: flowID),
                                   returning: DaemonAPI.MCPSignInWaitAnswer.self)
    }

    /// Forget a server's sign-in. Nil, or why it could not.
    func mcpSignOut(_ target: DaemonAPI.MCPSignInTarget) async -> String? {
        do {
            return try await macClient.call(DaemonAPI.Method.mcpSignOut, DaemonAPI.MCPSignOutRequest(target: target),
                                         returning: DaemonAPI.MCPSignOutAnswer.self).error
        } catch {
            return "It couldn't be signed out: the app could not reach its machine."
        }
    }

    private static func mcpError(_ error: any Error) -> DaemonAPI.MCPCatalogError {
        if let rpc = error as? JSONRPCError, rpc.code == DaemonAPI.Failure.mcpCatalogRefused,
           let reason = try? rpc.data?.decode(DaemonAPI.MCPCatalogError.self) {
            return reason
        }
        return .failed(String(describing: error))
    }

    func refreshRuntimes() async {
        let listed = await attempt(quietWhenDown: true) {
            self.runtimes = RuntimeCatalog.sortedByName(try await self.macClient.call(DaemonAPI.Method.runtimesList,
                                                                                   Optional<String>.none,
                                                                                   returning: [RuntimeStatus].self))
        }
        if listed {
            weighGetStarted()
            weighInstallOffer()
        }
    }

    /// Install a missing runtime on this Mac (048). Answers at once; the rest arrives on
    /// `runtime/changed`, which refreshes the list, so every view drawing a runtime moves
    /// with it and the new-agent menu has it the moment it is there.
    func installRuntime(_ runtimeID: String) async {
        await attempt {
            let status = try await self.macClient.call(DaemonAPI.Method.runtimesInstall,
                                                    DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                                                    returning: RuntimeStatus.self)
            if let index = self.runtimes.firstIndex(where: { $0.id == status.id }) {
                self.runtimes[index] = status
            }
        }
    }

    /// The runtimes the start-up sheet is about: not on this Mac, installing, or failed.
    var missingRuntimes: [RuntimeStatus] {
        runtimes.filter { InstallOffer.isMissing($0.availability) }
    }

    /// Whatever is missing now has been offered, whichever way the sheet was closed.
    func rememberInstallOffer() {
        InstallOffer.remember(missingRuntimes.map(\.id))
        isOfferingInstall = false
    }

    func weighInstallOffer() {
        // While the Get started card shows, its Install step is the offer (#982).
        guard !hasWeighedInstallOffer, !runtimes.isEmpty, getStartedCard == .gone else { return }
        hasWeighedInstallOffer = true
        let offered = InstallOffer.offered
        if missingRuntimes.contains(where: { !offered.contains($0.id) }) { isOfferingInstall = true }
    }

    /// What wants a person and where each is showing, on connect and on coming to the
    /// front: the daemon's list is the truth, and a banner it no longer lists is stale.
    func refreshAttention() async {
        let pending: DaemonAPI.AttentionPending
        do {
            pending = try await client.call(DaemonAPI.Method.attentionPending, Optional<String>.none,
                                            returning: DaemonAPI.AttentionPending.self)
        } catch {
            note("attention: pending failed: \(error)")
            return
        }
        work.replaceAttention(pending)
        await notifier.sweep(keeping: pending)
    }

    /// The window's own report of where the person is, started once and kept for the
    /// life of the window. Opening a banner selects the conversation it names.
    private func startPresence() {
        guard presence == nil else { return }
        work.onOversized = { [weak self] agentID, entryID, index in
            Task { await self?.loadOversized(entryID, of: agentID, at: index) }
        }
        let reporter = PresenceReporter { [weak self] watching, active, showing, popped in
            guard let self else { return }
            // Every host hears whether the person is here; only the one the open
            // conversation lives on hears which it is, since that is what marks it read
            // there (058, T093a). A control plane's hosts used to hear nothing, so their
            // finished turns stayed under Needs you however often they were opened. The
            // same host hears which chat is open, in front or not, which is where it sends
            // that agent's entries and output (#203).
            // Chats in windows of their own go to their own hosts the same way (#826).
            let owner = showing.map { self.host(ofAgent: $0) }
            let watcher = watching.map { self.host(ofAgent: $0) }
            let poppedHosts = popped.sorted { $0.uuidString < $1.uuidString }.map { ($0, self.host(ofAgent: $0)) }
            func report(for host: MachineRef) -> DaemonAPI.PresenceReport {
                DaemonAPI.PresenceReport(watching: watcher == host ? watching : nil, active: active,
                                         showing: owner == host ? showing : nil,
                                         alsoShowing: poppedHosts.filter { $0.1 == host }.map(\.0))
            }
            if self.hasMacHost {
                _ = try? await self.client.call(DaemonAPI.Method.presenceReport, report(for: .mac))
            }
            for (id, server) in self.controlHosts {
                _ = try? await server.call(DaemonAPI.Method.presenceReport, report(for: id))
            }
            // Coming to the front is also the moment to drop any banner that has gone
            // stale while nobody was looking.
            if active { await self.refreshAttention() }
        }
        // Windows of their own restored at launch opened before there was a reporter (#826).
        reporter.popped(Set(popouts.keys), inFront: popoutInFront)
        reporter.start()
        presence = reporter
    }

    func refreshPermissions() async {
        await attempt {
            self.work.replacePermissions(self.permissionsOnServers
                + (try await self.client.call(DaemonAPI.Method.permissionsPending,
                                              Optional<String>.none,
                                              returning: [PermissionRequest].self)))
        }
    }

    /// What the daemon is still bringing back after a restart.
    ///
    /// Asked without `attempt`: a daemon too old to know the method answers
    /// method-not-found, and nothing coming back is the right answer to that, not a
    /// connection the window should report as broken.
    func refreshResuming() async {
        let response = try? await client.call(DaemonAPI.Method.agentsResuming,
                                              Optional<String>.none,
                                              returning: DaemonAPI.ResumingResponse.self)
        work.setResuming(response?.agentIDs ?? [])
    }

    /// The open chat's record whole, with the menus and plan a lean list leaves out (#107).
    /// A host too old to know `agentID` lists its newest instead, which is not this one.
    /// Whether its host answered, with it or without it (#2743).
    @discardableResult
    func loadWholeAgent(_ id: UUID) async -> Bool {
        let host = host(ofAgent: id)
        guard let listed = try? await client(for: host).call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest.whole(id),
                                                             returning: [Agent].self) else { return false }
        guard var whole = listed.first(where: { $0.id == id }) else { return true }
        whole.host = host
        work.takeListed([whole])
        return true
    }

    func loadTranscript() async {
        guard let selection else { work.clearTranscript(); return }
        // A failed open ends its timing too, rather than leaving it open (#213).
        defer {
            if let opening = chatOpening, opening.agent == selection {
                chatOpening = nil
                Perf.end(opening.timing, "failed")
            }
        }
        // Only the latest load of this chat puts its answer on screen: it is loaded on
        // opening, on every reconnect and on its host's lists, and these overlap (#400).
        let load = work.beginTranscriptLoad()
        // Beside the transcript rather than before it: neither waits on the other.
        async let whole = loadWholeAgent(selection)
        // The chat's own host, both for the call and for the check that it is up: a
        // server's chat does not fail because this Mac's host is down (#400).
        let host = host(ofAgent: selection)
        var reason: String?
        // Its host answered that it has no such session: an answer, not a failure (#2743).
        var gone = false
        let loaded = await attempt(on: host, quietWhenDown: true) {
            let client = self.client(for: host)
            do {
                // A few turns rather than a full page: a screen holds two or three, the
                // rest come as the reader nears the top, and fifty replies were a quarter
                // of a megabyte to carry and decode before anything could be drawn (#90).
                let opening = try await ChatOpening.load(
                    turns: {
                        try await client.call(DaemonAPI.Method.agentsTurns, DaemonAPI.TurnsRequest.opening(selection),
                                              returning: TurnsPage.self)
                    },
                    transcript: { from, limit in
                        try await client.call(DaemonAPI.Method.agentsTranscript,
                                              DaemonAPI.TranscriptRequest(agentID: selection, limit: limit, from: from),
                                              returning: TranscriptPage.self)
                    },
                    describe: { self.describe($0) })
                // Clicking through chats quickly can have the answer for the last one
                // arrive after the next was picked. It is dropped, not shown under the
                // wrong name.
                guard self.selection == selection else { return }
                let dataIn = self.chatOpening.map { Perf.elapsed($0.timing) }
                guard self.work.takeOpening(opening, load: load) else { return }
                if let why = opening.turnsFailure { Self.chatLog.notice("turns of \(selection) did not load: \(why, privacy: .public)") }
                if let started = self.chatOpening, started.agent == selection {
                    self.chatOpening = nil
                    Perf.endWhenDrawn(started.timing, "\(opening.turns.turns.count) turns, "
                                      + "\(opening.page.entries.count) entries, data in \(dataIn ?? 0) ms")
                }
            } catch {
                // A server that went: the strip says so, and this says what is shown (#963).
                reason = host != .mac && OfflineWords.hostDown(error) ? OfflineWords.lastHeard : self.describe(error)
                gone = ChatOpening.saysGone(error)
                throw error
            }
        }
        // Said in the chat, with Try Again, as well as in the alert: the alert goes and
        // the blank chat stayed (#400).
        if !loaded, self.selection == selection {
            let why = reason ?? (macHostNotice?.action ?? HostSet.macDownProblem)
            Self.chatLog.notice("history of \(selection) did not load from \(host.rawValue, privacy: .public): \(why, privacy: .public)")
            work.failOpening(why, load: load)
        }
        // Looked for once its host has answered both and said it has no such session:
        // only then has a session not in hand gone. A call that failed is no answer, and
        // the chat says it with Try Again rather than calling the session deleted (#2748).
        guard await whole, self.selection == selection else { return }
        if gone {
            lookedForSelection = selection
        } else if loaded, work.agent(selection) == nil {
            // Its host has its history, but no record this Mac could read (#2650): not gone.
            Self.chatLog.notice("record of \(selection) did not load from \(host.rawValue, privacy: .public)")
            work.failOpening("Its host has this session, but this Mac could not read its record.", load: load)
        }
    }

    /// A session's transcript in a window of its own (#826), loaded as the main window's
    /// is, into that window's own page of it.
    func loadTranscript(of chat: PoppedChat) async {
        let id = chat.id
        let load = chat.work.beginTranscriptLoad()
        async let whole = loadWholeAgent(id)
        let host = host(ofAgent: id)
        var reason: String?
        // Its host answered that it has no such session: an answer, not a failure (#2743).
        var gone = false
        let loaded = await attempt(on: host, quietWhenDown: true) {
            let client = self.client(for: host)
            do {
                let opening = try await ChatOpening.load(
                    turns: {
                        try await client.call(DaemonAPI.Method.agentsTurns, DaemonAPI.TurnsRequest.opening(id),
                                              returning: TurnsPage.self)
                    },
                    transcript: { from, limit in
                        try await client.call(DaemonAPI.Method.agentsTranscript,
                                              DaemonAPI.TranscriptRequest(agentID: id, limit: limit, from: from),
                                              returning: TranscriptPage.self)
                    },
                    describe: { self.describe($0) })
                // A window closed while it loaded has nothing to put it in.
                guard self.popouts[id] === chat else { return }
                _ = chat.work.takeOpening(opening, load: load)
            } catch {
                // A server that went: the strip says so, and this says what is shown (#963).
                reason = host != .mac && OfflineWords.hostDown(error) ? OfflineWords.lastHeard : self.describe(error)
                gone = ChatOpening.saysGone(error)
                throw error
            }
        }
        if !loaded, popouts[id] === chat {
            let why = reason ?? (macHostNotice?.action ?? HostSet.macDownProblem)
            Self.chatLog.notice("history of \(id) did not load in its own window from \(host.rawValue, privacy: .public): \(why, privacy: .public)")
            chat.work.failOpening(why, load: load)
        }
        // Looked for once its host has answered both: from here a session not in hand is
        // one that has gone. A call that failed is no answer, and the window says it with
        // Try Again rather than calling the session deleted (#2743).
        guard await whole, loaded || gone else { return }
        chat.looked = true
    }

    /// Every window of its own's transcript again, as on a reconnect (#826).
    func loadPoppedTranscripts() async {
        for chat in popouts.values { await loadTranscript(of: chat) }
    }

    /// An earlier page of a session in a window of its own (#826), as `loadEarlier`.
    func loadEarlier(of chat: PoppedChat) async {
        let id = chat.id
        let work = chat.work
        guard work.hasMoreOfTheConversation else { return }
        if !work.hasMoreBefore {
            await attempt {
                let turns = try await self.client(forAgent: id).call(
                    DaemonAPI.Method.agentsTurns, DaemonAPI.TurnsRequest(agentID: id, before: work.firstTurn),
                    returning: TurnsPage.self)
                guard self.popouts[id] === chat else { return }
                work.prependTurns(turns)
            }
            return
        }
        await attempt {
            let page = try await self.client(forAgent: id).call(
                DaemonAPI.Method.agentsTranscript,
                DaemonAPI.TranscriptRequest(agentID: id, before: work.firstEntryIndex, from: work.openTurnStart),
                returning: TranscriptPage.self)
            guard self.popouts[id] === chat else { return }
            work.prepend(page)
        }
    }

    /// Where a chat that did not open says why (#400).
    nonisolated private static let chatLog = Logger(subsystem: "com.alexecollins.Agents", category: "chat")

    /// An entry its host sent as a stub, too big to send to every chat (#203), read here.
    func loadOversized(_ entryID: UUID, of agentID: UUID, at index: Int?) async {
        guard let page = try? await client(forAgent: agentID).call(
            DaemonAPI.Method.agentsTranscript, DaemonAPI.TranscriptRequest.around(index, of: agentID),
            returning: TranscriptPage.self),
              let entry = page.entries.first(where: { $0.id == entryID }) else { return }
        work.fillOversized(entry, for: agentID)
        popouts[agentID]?.work.fillOversized(entry, for: agentID)
    }

    /// A finished turn's entries, for the chat to open it: the last page of them when
    /// the turn is longer than a host gives in one answer (#200).
    /// Nil when they did not come, which the chat says and asks again for, rather than
    /// a turn with no steps for as long as the chat is open (#400).
    func turnEntries(_ agentID: UUID, _ range: Range<Int>) async -> TranscriptPage? {
        do {
            return try await client(forAgent: agentID).call(
                DaemonAPI.Method.agentsTranscript,
                DaemonAPI.TranscriptRequest(agentID: agentID, before: range.upperBound,
                                            limit: min(range.count, DaemonAPI.TranscriptRequest.limitCeiling),
                                            from: range.lowerBound),
                returning: TranscriptPage.self)
        } catch {
            Self.chatLog.notice("steps of \(agentID) did not load: \(self.describe(error), privacy: .public)")
            return nil
        }
    }

    /// The window only ever asks for a page. A transcript that has been going for hours
    /// is not something to load whole.
    func loadEarlier(turns limit: Int = 50) async {
        guard let selection, work.hasMoreOfTheConversation else { return }
        // Past the start of the turn in progress, the turns before it.
        if !work.hasMoreBefore {
            await attempt {
                let turns = try await self.client(forAgent: selection).call(
                    DaemonAPI.Method.agentsTurns,
                    DaemonAPI.TurnsRequest(agentID: selection, before: self.work.firstTurn, limit: limit),
                    returning: TurnsPage.self)
                guard self.selection == selection else { return }
                self.work.prependTurns(turns)
            }
            return
        }
        await attempt {
            let page = try await self.client(forAgent: selection).call(
                DaemonAPI.Method.agentsTranscript,
                DaemonAPI.TranscriptRequest(agentID: selection, before: self.work.firstEntryIndex,
                                            from: self.work.openTurnStart),
                returning: TranscriptPage.self)
            // The same as `loadTranscript`: an earlier page of a chat no longer open
            // does not belong on top of the one that is.
            guard self.selection == selection else { return }
            self.work.prepend(page)
        }
    }

    // MARK: Doing

    /// Where the draft session is made: in a worktree already there when one is chosen,
    /// so the start can use it (research R2). A new worktree has no folder until the
    /// start makes it, so its draft is the folder's and the start lets it go.
    private var draftOptionsFolder: URL? {
        if case .existing(let root) = draftWorktree { return root }
        return draftCwd
    }

    /// Choose where the next agent works, and make the draft there if that moved it.
    func chooseWorktree(_ choice: WorktreeChoice?) {
        let before = draftOptionsFolder
        draftWorktree = choice
        if draftOptionsFolder != before, draftRuntimeID != nil {
            Task { await loadDraftOptions() }
        }
    }

    /// Every folder's worktrees on this Mac, for Activity ▸ Worktrees (#790). Sizes the
    /// daemon has not measured yet come later, on `worktrees/sized`.
    func loadWorktrees() async {
        guard let listed = try? await macClient.call(DaemonAPI.Method.worktreesAll, DaemonAPI.Empty(),
                                                  returning: [DaemonAPI.FolderWorktrees].self) else { return }
        work.replaceWorktrees(listed)
    }

    /// What removing one of a folder's worktrees would lose, or nil when it could
    /// not be asked (and `problem` says why).
    func checkWorktreeRemoval(_ root: URL, in folder: URL) async -> DaemonAPI.RemovalCheck? {
        do {
            return try await macClient.call(DaemonAPI.Method.worktreesCheck,
                                         DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root),
                                         returning: DaemonAPI.RemovalCheck.self)
        } catch {
            problem = describe(error)
            return nil
        }
    }

    /// Remove one of a folder's worktrees. `confirmed` is the person having seen
    /// what would be lost; the daemon checks again either way.
    func removeWorktree(_ root: URL, in folder: URL, confirmed: Bool) async {
        do {
            _ = try await macClient.call(DaemonAPI.Method.worktreesRemove,
                                      DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root,
                                                                       confirmed: confirmed),
                                      returning: DaemonAPI.WorktreeRemoved.self)
        } catch {
            problem = describe(error)
        }
        await loadWorktrees()
        if draftCwd != nil { await loadDraftWorktrees() }
    }

    /// Delete an idle worktree's build output (#790), and say what it freed; nil when it
    /// could not (and `problem` says why).
    func removeBuildOutput(_ root: URL, in folder: URL) async -> String? {
        defer { Task { await loadWorktrees() } }
        do {
            let removed = try await macClient.call(DaemonAPI.Method.worktreesRemoveBuildOutput,
                                                DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root),
                                                returning: DaemonAPI.BuildOutputRemoved.self)
            return WorktreeTally.freedWords(removed)
        } catch {
            problem = describe(error)
            return nil
        }
    }

    /// Clean up worktrees (030): a new session in the folder, offered the words.
    func offerCleanUp(in folder: URL) {
        showFolder(FolderKey(folder: folder))
        offeredPrompt = PromptOffer(agentID: nil, words: WorktreeTally.cleanUpPrompt)
    }

    /// What an agent changed (035). Asked by the Changes pane on its own triggers —
    /// shown, an edit finished, the turn ended — and never polled.
    func changes(for agentID: UUID) async throws -> ChangesList {
        try await client.call(DaemonAPI.Method.changesList,
                              DaemonAPI.ChangesListRequest(agentID: agentID),
                              returning: ChangesList.self)
    }

    /// One file from `changes(for:)`: its edits, and with `whole` the file as it stands.
    func changeDetail(for agentID: UUID, path: String, whole: Bool = false) async throws -> ChangedFileDetail {
        try await client.call(DaemonAPI.Method.changesFile,
                              DaemonAPI.ChangesFileRequest(agentID: agentID, path: path, whole: whole),
                              returning: ChangedFileDetail.self)
    }

    /// What the draft folder's repository has. Asked once each time the folder
    /// changes or an agent starts, never polled; an answer for a folder since left is
    /// dropped.
    func loadDraftWorktrees() async {
        draftWorktreesGeneration += 1
        let generation = draftWorktreesGeneration
        guard let folder = draftCwd else { return }
        // Each of the form's calls with a deadline (#1096): a reply lost on the way from a
        // server is a failure the form asks again for, not a wait for ever.
        let answer = (try? await draftHostClient.callWithin(StartPageAsks.patience(for: DaemonAPI.Method.worktreesList),
                                                            DaemonAPI.Method.worktreesList,
                                                            DaemonAPI.WorktreesListRequest(folder: folder),
                                                            returning: DaemonAPI.WorktreesListResponse.self))
            ?? .notARepository
        guard generation == draftWorktreesGeneration else { return }
        draftWorktrees = answer
        // A worktree chosen before the answer came, as a view's start does (#834), is no
        // choice in a folder that has none: the chooser is hidden, so it could not be undone.
        if !answer.isRepository { draftWorktree = nil }
    }

    /// The personas the draft folder offers (#760). A host too old to know the method
    /// offers none, and the choice is not drawn.
    func loadDraftPersonas() async {
        guard let folder = draftCwd else { return }
        let listed = (try? await draftHostClient.callWithin(StartPageAsks.patience(for: DaemonAPI.Method.personasList),
                                                            DaemonAPI.Method.personasList,
                                                            DaemonAPI.PersonasListRequest(folder: folder),
                                                            returning: [Persona].self)) ?? []
        guard folder == draftCwd else { return }
        draftPersonas = listed
        if let draftPersona, !listed.contains(where: { $0.id == draftPersona && $0.problem == nil }) {
            self.draftPersona = nil
        }
    }

    func agentConfigEditorFiles(on host: MachineRef, folder: URL?, kind: DaemonAPI.AgentConfigEditorKind)
        async -> [DaemonAPI.AgentConfigEditorFile]? {
        let request = DaemonAPI.AgentConfigEditorRequest(folder: folder, kind: kind)
        return try? await client(for: host).call(DaemonAPI.Method.agentConfigEditorFiles, request,
                                                 returning: [DaemonAPI.AgentConfigEditorFile].self)
    }

    func saveAgentConfigEditorFile(on host: MachineRef, folder: URL?, kind: DaemonAPI.AgentConfigEditorKind,
                                   path: String, content: String, delete: Bool) async -> String? {
        let request = DaemonAPI.AgentConfigEditorSaveRequest(folder: folder, kind: kind, path: path,
                                                               content: content, delete: delete)
        do {
            try await client(for: host).call(DaemonAPI.Method.agentConfigEditorSave, request)
            await refreshWorkflows()
            return nil
        } catch { return describe(error) }
    }

    /// Pick a kind of session (#760): every setting it names is set, and every one it
    /// leaves out stays as the form has it. Nil picks none, and changes nothing else.
    func choosePersona(_ persona: Persona?) {
        draftPersona = persona?.id
        pendingPersona = nil
        guard let persona else { return }
        if let runtimeID = persona.settings.runtimeID, runtimeID != draftRuntimeID,
           availableRuntimes.contains(where: { $0.runtime.id == runtimeID }) {
            draftRuntimeID = runtimeID
            pendingPersona = persona
            Task { await loadDraftOptions() }
            return
        }
        if draftOptions.isEmpty {
            pendingPersona = persona
        } else {
            draftChosen.merge(persona.choices(against: draftOptions)) { _, new in new }
        }
    }

    /// What the open agent's folder has, for the Worktree choice on its page (053).
    func loadAgentWorktrees(of agent: Agent) async {
        let folder = agent.folderPath
        let answer = (try? await client(forAgent: agent.id).call(DaemonAPI.Method.worktreesList,
                                                                DaemonAPI.WorktreesListRequest(folder: folder),
                                                                returning: DaemonAPI.WorktreesListResponse.self))
            ?? .notARepository
        agentWorktrees[folder] = answer
    }

    /// Move an agent, or with no target take back the move that is waiting (053). Made
    /// at once when it is between turns; otherwise when its turn ends.
    func move(_ agent: Agent, to target: MoveTarget?) async {
        moveProblems[agent.id] = nil
        do {
            _ = try await client(forAgent: agent.id).call(DaemonAPI.Method.agentsMove,
                                                          DaemonAPI.MoveRequest(agentID: agent.id, target: target),
                                                          returning: DaemonAPI.MoveAnswer.self)
        } catch let error as JSONRPCError {
            moveProblems[agent.id] = error.message
        } catch {
            moveProblems[agent.id] = "Could not move: \(error.localizedDescription)"
        }
        await loadAgentWorktrees(of: agent)
    }

    /// A session has to exist before its options do, so choosing a folder and a
    /// runtime starts one. It is kept and used by the start that follows.
    func loadDraftOptions() async {
        guard let runtimeID = draftRuntimeID, let cwd = draftOptionsFolder else { return }
        draftOptionsGeneration += 1
        let generation = draftOptionsGeneration
        isLoadingDraftOptions = true
        draftOptionsFailure = nil
        draftOptions = []
        draftCommands = []
        draftChosen = [:]
        letGo(draft: draftID)
        draftID = nil
        do {
            let response = try await draftHostClient.callWithin(StartPageAsks.patience(for: DaemonAPI.Method.agentsOptions),
                                                                DaemonAPI.Method.agentsOptions,
                                                                DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: cwd,
                                                                                         mcpServers: draftServers),
                                                                returning: DaemonAPI.OptionsResponse.self)
            // An answer for a folder or runtime the user has since moved away from is
            // not an answer to the question now being asked — and its runtime is one
            // nobody will talk to.
            guard generation == draftOptionsGeneration else { letGo(draft: response.draftID); return }
            draftID = response.draftID
            show(options: response.options, commands: response.commands, opening: true)
        } catch {
            guard generation == draftOptionsGeneration else { return }
            // Said in the row rather than only in the banner, because the row is where
            // the person is looking and where the retry lives.
            draftOptionsFailure = describe(error)
        }
        if generation == draftOptionsGeneration { isLoadingDraftOptions = false }
    }

    /// A draft this window has replaced is a runtime nobody will talk to. Not waited
    /// on, and a daemon too old to know the method has nothing to be told (029).
    private func letGo(draft: UUID?) {
        guard let draft else { return }
        Task {
            _ = try? await draftHostClient.call(DaemonAPI.Method.agentsDiscardDraft,
                                       DaemonAPI.DiscardDraftRequest(draftID: draft))
        }
    }

    /// Draw the form.
    ///
    /// The first answer may be what the runtime offered last time, with what it
    /// actually offers arriving a few seconds later, so this runs more than once for
    /// one draft and keeps every choice already made that is still on offer.
    private func show(options: [ConfigOption], commands: [SlashCommand], opening: Bool) {
        draftOptions = PromptControlsState.drawable(agentOptions: nil, draftOptions: options)
        draftCommands = commands
        for option in draftOptions {
            // A choice already made stands, as long as it is still one of the choices.
            if let chosen = draftChosen[option.id],
               option.isBoolean || (option.options ?? []).contains(where: { $0.value == chosen }) {
                continue
            }
            draftChosen[option.id] = option.currentValue
        }
        // Options that have gone are not choices anybody can unmake.
        let offered = Set(draftOptions.map(\.id))
        draftChosen = draftChosen.filter { offered.contains($0.key) }
        // The mode you chose last time for this runtime, if it still offers it.
        // Seeding the draft is enough: `startDraft` sends these as `StartOptions`
        // and the daemon applies each one to the session before the first prompt.
        //
        // What the control opens on, so only on the first draw: a correction arriving
        // behind a form drawn from memory must not undo a mode chosen since.
        if opening, let runtimeID = draftRuntimeID,
           let mode = ModeMemory.modeOption(in: draftOptions) {
            draftChosen[mode.id] = ModeMemory.startingValue(
                remembered: rememberedMode(for: runtimeID), for: mode)
        }
        // Over the mode remembered, because the persona was picked after it (#760).
        if let persona = pendingPersona, !draftOptions.isEmpty {
            draftChosen.merge(persona.choices(against: draftOptions)) { _, new in new }
            pendingPersona = nil
        }
    }

    /// The runtime starting behind a form drawn from memory has answered at last, and
    /// either offers something else or will not start at all.
    private func settleDraft(_ notification: DaemonAPI.DraftOptionsNotification) {
        guard notification.draftID == draftID else { return }
        if let failure = notification.failure {
            // Said in the row rather than the banner, the same as a form that failed to
            // load, because the row is where the person is looking and where the retry
            // lives. The controls go with it: they were what this runtime offered last
            // time, and there is no runtime this time.
            draftOptionsFailure = failure
            draftOptions = []
            draftCommands = []
            draftChosen = [:]
            draftID = nil
            return
        }
        show(options: notification.options, commands: notification.commands, opening: false)
    }

    /// Whether the agent was started, so the prompt bar can give back what it sent
    /// when it was not.
    @discardableResult
    /// `voice`: started from voice mode (#2375), so the first reply is short and fit to be
    /// heard; `started` is told the new agent's id.
    func startDraft(prompt: String, attachments: [Attachment] = [], labels: [String] = [],
                    voice: Bool = false, started: (UUID) -> Void = { _ in }) async -> Bool {
        guard !isStarting, let runtimeID = draftRuntimeID, let cwd = draftCwd else { return false }
        isStarting = true
        defer { isStarting = false }
        let request = DaemonAPI.StartRequest(runtimeID: runtimeID,
                                             cwd: cwd,
                                             prompt: prompt,
                                             attachments: attachments,
                                             startOptions: StartOptions(values: draftChosen),
                                             draftID: draftID,
                                             additionalDirectories: draftFolders,
                                             mcpServers: draftServers,
                                             worktree: draftWorktree,
                                             sandbox: draftSandbox, labels: labels, persona: draftPersona,
                                             accountID: draftAccountChoices?.sent(draftAccountID),
                                             voice: voice ? true : nil)
        // A stopped workspace that starts when used: kept, and shown under this prompt (#691 US3).
        if draftHost != .mac, hosts.isOffline(draftHost), startsWhenUsed(draftHost) {
            var kept = request
            kept.draftID = nil
            kept.requestID = UUID()
            guard let said = await keepThroughControl(draftHost, DaemonAPI.Method.agentsStart, kept) else { return false }
            keptStartsShown.insert(said.id)
            return true
        }
        do {
            let id = try await draftHostClient.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            started(id)
            draftID = nil
            // The last folder used is the one a session was started in, from any window (#2160).
            rememberNewSessionFolder(FolderKey(host: draftHost, folder: cwd))
            // Back to the folder, and the list fetched again: the start may
            // have made a worktree, and it has put an agent in one.
            draftWorktree = nil
            Task { await loadDraftWorktrees() }
            if draftHost == .mac {
                await refreshAgents()
                await refreshFolders()
            } else {
                await refreshServer(draftHost)
            }
            // Gone to, as the phone does: what you just asked for is what you want to
            // see start. Once the list has it, so the chat opens on a row that is there.
            // Started in a folder's own window, it opens there (#1089).
            if let window = composingWindow.flatMap({ folderWindows[$0] }) {
                window.show(started: id)
            } else {
                justStarted = id
                selection = id
            }
            draftSandboxRefusal = nil
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.kept {
            // Kept until its stopped workspace is up (#691 US3): shown under this prompt, and
            // the agent it makes opens once the host is up.
            if let kept = noteKept(error) { keptStartsShown.insert(kept.id) }
            draftID = nil
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.sandboxWillNotStart {
            // Said over the prompt, which keeps what was typed, with the way on (064).
            draftSandboxRefusal = try? error.data?.decode(DaemonAPI.SandboxWillNotStart.self)
            if draftSandboxRefusal == nil { fail(error, on: draftHost) }
            return false
        } catch {
            fail(error, on: draftHost)
            return false
        }
    }

    /// Sent now if the agent is free, and queued by the daemon if it is not. Either
    /// way this is the same call: whether there is room for it is not the window's
    /// question to answer.
    @discardableResult
    /// `voice`: sent from voice mode (#2322), so the reply is short and fit to be heard.
    func send(_ text: String, attachments: [Attachment] = [], to agentID: UUID? = nil, voice: Bool = false) async -> Bool {
        // The main window's chat, or the one in a window of its own that sent it (#826).
        guard let selection = agentID ?? selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let host = host(ofAgent: selection)
        // A stopped workspace that starts when used: kept by the control plane (#691 US3).
        if host != .mac, hosts.isOffline(host), startsWhenUsed(host) {
            guard attachments.isEmpty else {
                problem = "Attachments can’t wait for \(hosts.label(host)) to start. Send the words alone, or start it first."
                return false
            }
            return await keepThroughControl(host, DaemonAPI.Method.agentsPrompt,
                                            DaemonAPI.PromptRequest(agentID: selection, text: text, sendID: UUID(), voice: voice ? true : nil)) != nil
        }
        if host != .mac {
            guard let carried = await carry(attachments, to: host, for: selection) else { return false }
            let sendID = UUID()
            return await sendToServer(host) { client in
                try await client.call(DaemonAPI.Method.agentsPrompt,
                                      DaemonAPI.PromptRequest(agentID: selection, text: text,
                                                              attachments: carried, sendID: sendID,
                                                              voice: voice ? true : nil))
            }
        }
        return await attempt {
            do {
                try await self.client(forAgent: selection).call(DaemonAPI.Method.agentsPrompt,
                                           DaemonAPI.PromptRequest(agentID: selection, text: text,
                                                                   attachments: attachments,
                                                                   voice: voice ? true : nil))
            } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.folderGone {
                // Its own alert, with the ways on, carrying what was typed (#119).
                self.folderGone = FolderGoneAsk(agentID: selection, message: error.message,
                                                text: text, attachments: attachments)
                throw SaidAlready()
            }
        }
    }

    // MARK: A folder that has gone (#119)

    /// Start a successor in the folder that reads this session and carries on,
    /// with whatever was typed, and open it.
    @discardableResult
    func continueInFolder(_ agentID: UUID, text: String = "", attachments: [Attachment] = []) async -> Bool {
        var made: UUID?
        let went = await attempt(on: host(ofAgent: agentID)) {
            made = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.agentsContinueInFolder,
                DaemonAPI.ContinueInFolderRequest(agentID: agentID, text: text, attachments: attachments,
                                                   requestID: UUID()),
                returning: UUID.self)
        }
        guard went, let made else { return false }
        let host = host(ofAgent: agentID)
        if host == .mac { await refreshAgents() } else { await refreshServer(host) }
        selection = made
        return true
    }

    /// Why a session on this Mac can no longer reach the model on its account (#999): the
    /// organisation removed it, or its policy refuses it now. Nil when it can.
    func accountMoveReason(_ agent: Agent) -> String? {
        guard host(ofAgent: agent.id) == .mac, agent.state != .archived else { return nil }
        return AccountChoices(runtimeID: agent.runtimeID, profiles: accountProfiles, policy: policyState?.policy)
            .moveReason(accountID: agent.accountID, loaded: accountProfilesRead)
    }

    /// **Continue in New** (#999): a session in the same folder that reads this one and
    /// carries on, on the runtime's account for new sessions, and open it.
    @discardableResult
    func continueInNew(_ agentID: UUID) async -> Bool {
        var made: UUID?
        let went = await attempt(on: host(ofAgent: agentID)) {
            made = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.agentsContinueInNew,
                DaemonAPI.ContinueInNewRequest(agentID: agentID, requestID: UUID()),
                returning: UUID.self)
        }
        guard went, let made else { return false }
        let host = host(ofAgent: agentID)
        if host == .mac { await refreshAgents() } else { await refreshServer(host) }
        selection = made
        return true
    }

    /// Make the worktree again from its branch.
    func recreateWorktree(_ agentID: UUID) async {
        let host = host(ofAgent: agentID)
        let made = await attempt(on: host) {
            _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.agentsRecreateWorktree, DaemonAPI.AgentRequest(agentID: agentID),
                returning: Agent.self)
        }
        guard made else { return }
        if host == .mac { await refreshAgents() } else { await refreshServer(host) }
    }

    /// Carry on when the allowance is back, or no longer (#1859).
    func continueWhenBack(_ agentID: UUID) async { await waitForAllowance(agentID, DaemonAPI.Method.agentsContinueWhenBack) }
    func cancelContinue(_ agentID: UUID) async { await waitForAllowance(agentID, DaemonAPI.Method.agentsCancelContinue) }

    private func waitForAllowance(_ agentID: UUID, _ method: String) async {
        let host = host(ofAgent: agentID)
        let went = await attempt(on: host) {
            _ = try await self.client(forAgent: agentID).call(method, DaemonAPI.AgentRequest(agentID: agentID), returning: Agent.self)
        }
        guard went else { return }
        if host == .mac { await refreshAgents() } else { await refreshServer(host) }
    }

    /// End a block by hand (039): the prompt Carry on sends, as the person, to an agent
    /// that need not be the one selected. A person's prompt is what clears a block, so
    /// this is an ordinary prompt and nothing else.
    func carryOn(_ id: UUID) async {
        await attempt(on: work.agent(id)?.host ?? .mac) {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsPrompt,
                                       DaemonAPI.PromptRequest(agentID: id, text: Block.carryOnPrompt))
        }
    }

    /// Start an agent on this, in this folder.
    ///
    /// What the prompt at the top of a folder does. There is no separate button for
    /// it because there is nothing else the prompt could mean: you are looking at a
    /// folder and saying what you want done in it.
    func startAgent(in folder: URL, prompt: String, labels: [String] = []) async {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let runtimeID = defaultRuntimeID else { return }
        await attempt {
            let id = try await self.selectedHostClient.call(
                DaemonAPI.Method.agentsStart,
                DaemonAPI.StartRequest(runtimeID: runtimeID, cwd: folder, prompt: words,
                                       labels: labels),
                returning: UUID.self)
            self.justStarted = id
            self.selection = id
        }
    }

    func setLabels(on id: UUID, add: [String] = [], remove: [String] = []) async {
        await attempt(on: work.agent(id)?.host ?? .mac) {
            try await self.client(forAgent: id).call(
                DaemonAPI.Method.agentsSetLabels,
                DaemonAPI.SetLabelsRequest(agentID: id, add: add, remove: remove))
        }
    }

    /// A folder's labels as its host keeps them, archived sessions' included, read when
    /// a label input appears and when its session's labels change (#213). Not worked out here from the
    /// agents held: that was a pass over every one of them on each redraw of the chat,
    /// and it missed what only archived sessions carry.
    func labelSuggestions(in folder: URL, on host: MachineRef) -> [String] {
        labelVocabularies[FolderKey(host: host, folder: Folder.standardize(folder))] ?? []
    }

    /// Each folder's label vocabulary, by host and folder, as last read.
    private(set) var labelVocabularies: [FolderKey: [String]] = [:]

    func loadLabelVocabulary(in folder: URL, on host: MachineRef) async {
        let key = FolderKey(host: host, folder: Folder.standardize(folder))
        let values: [String]
        if let read = try? await client(for: host).call(
            DaemonAPI.Method.agentsLabelVocabulary, DaemonAPI.LabelVocabularyRequest(folder: key.folder),
            returning: [String].self) {
            values = read
        } else {
            // A host too old to say: once from what is held, not once per redraw.
            values = SessionLabelPolicy.vocabulary(
                in: key.folder, agents: AgentGroup.allCases.flatMap { work.agents(in: key, group: $0) }).map(\.value)
        }
        if labelVocabularies[key] != values { labelVocabularies[key] = values }
    }

    /// Which runtime a new agent gets: the most recently active agent's runtime on this
    /// folder's host, then the kept form choice, then the first available (#264).
    var defaultRuntimeID: String? {
        work.defaultRuntimeID(available: availableRuntimes.map(\.runtime.id), kept: draftRuntimeID, host: selectedFolderHost)
    }

    /// Take something back off the queue before it goes.
    func unqueue(_ prompt: QueuedPrompt, from agentID: UUID) async {
        await attempt {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsUnqueue,
                                       DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id))
        }
    }

    /// New words for a queued prompt, in its place in the queue (#1552). When it was sent or
    /// taken back first, or the call failed, the words go into the prompt bar, so nothing
    /// typed is lost (#1665).
    func editQueued(_ prompt: QueuedPrompt, text: String, of agentID: UUID) async {
        let reached = await attempt {
            let result = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.agentsEditQueued,
                DaemonAPI.EditQueuedRequest(agentID: agentID, promptID: prompt.id, text: text),
                returning: DaemonAPI.EditQueuedResult.self)
            guard !result.edited else { return }
            self.offeredPrompt = PromptOffer(agentID: agentID, words: text)
            self.problem = QueuedPrompt.sentBeforeEdit
        }
        // The failure is said already; the words are not lost with it, as on the Remote.
        if !reached { offeredPrompt = PromptOffer(agentID: agentID, words: text) }
    }

    /// Send a queued prompt into the turn that is running, where the runtime takes one.
    /// Once: the row shows it going, and a second press is not a second send (#87).
    func sendNow(_ prompt: QueuedPrompt, to agentID: UUID) async {
        await act(.sendNow(prompt.id), on: agentID) {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsSendNow,
                                       DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id))
        }
    }

    /// Something asked of a whole agent, sent once (#87). Held in `work.acting` until the
    /// host has answered, so whichever control sent it shows it on its way, and the menu,
    /// the row, the swipe and the key all refuse a second until it is back. False when it
    /// did not go, or was a second press of something already going.
    @discardableResult
    private func act(_ act: AgentAct, on id: UUID, _ call: () async throws -> Void) async -> Bool {
        guard work.begin(act, on: id) else { return false }
        defer { work.end(act, on: id) }
        return await attempt(on: work.agent(id)?.host ?? .mac, call)
    }

    /// What is on its way to this agent, if anything: for the control that sent it to
    /// show, and the others to hold. Its own cell, so one row's is not every row's (#285).
    func acting(_ id: UUID) -> AgentAct? { work.act(of: id) }

    /// What the runtime behind the current agent, or the draft, says it will take.
    /// Nothing is refused on a guess: this is what the runtime advertised.
    var promptCapabilities: ACP.PromptCapabilities {
        promptCapabilities(for: selectedAgent?.runtimeID ?? draftRuntimeID)
    }

    func promptCapabilities(for runtimeID: String?) -> ACP.PromptCapabilities {
        runtimeID.flatMap { accounts[$0]?.promptCapabilities } ?? ACP.PromptCapabilities()
    }

    func refreshAccounts() async {
        guard let list = try? await macClient.call(DaemonAPI.Method.runtimesAccounts,
                                                Optional<Int>.none,
                                                returning: [RuntimeAccount].self) else { return }
        accounts = Dictionary(uniqueKeysWithValues: list.map { ($0.runtimeID, $0) })
        await refreshAccountProfiles()
    }

    func refreshAccountProfiles() async {
        guard let list = try? await macClient.call(DaemonAPI.Method.runtimesAccountProfiles, Optional<Int>.none,
                                                returning: [AccountProfile].self) else { return }
        accountProfiles = list
    }

    /// Add an account to a runtime (#840). Nil when it was added; else why not, for the sheet.
    func addAccount(runtimeID: String, name: String) async -> String? {
        do {
            let added = try await macClient.call(DaemonAPI.Method.runtimesAddAccount,
                                              DaemonAPI.AddAccountRequest(runtimeID: runtimeID, name: name),
                                              returning: AccountProfile.self)
            accountProfiles.removeAll { $0.id == added.id }
            accountProfiles.append(added)
            await refreshRuntimeAllowances()
            return nil
        } catch {
            return describe(error)
        }
    }

    func removeAccount(_ account: AccountProfile) async {
        await attempt {
            _ = try await self.macClient.call(DaemonAPI.Method.runtimesRemoveAccount,
                                           DaemonAPI.AccountRequest(runtimeID: account.runtimeID, accountID: account.id),
                                           returning: [UUID].self)
        }
        await refreshAccountProfiles()
        await refreshRuntimeAllowances()
        await refreshAgents()
    }

    /// **Reaches the Model By** (#999): the runtime's account for new sessions, nil for its own
    /// sign-in. Nil when it was set; else why not.
    func setDefaultAccount(runtimeID: String, accountID: String?) async -> String? {
        do {
            _ = try await macClient.call(DaemonAPI.Method.runtimesSetDefaultAccount,
                                         DaemonAPI.DefaultAccountRequest(runtimeID: runtimeID,
                                                                         accountID: accountID ?? AccountProfile.ownSignInID),
                                         returning: DaemonAPI.Empty.self)
            await refreshAccountProfiles()
            return nil
        } catch {
            return describe(error)
        }
    }

    /// The agents an added account is running, which removing it stops.
    func agentsHolding(account: AccountProfile) -> [Agent] {
        agentsHolding(runtimeID: account.runtimeID).filter { $0.accountID == account.id }
    }

    func stop(_ id: UUID) async {
        await act(.stop, on: id) {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsStop, DaemonAPI.AgentStopRequest(agentID: id))
        }
    }

    /// Stop one shell an agent left running, and nothing else it is doing (057).
    func stopBackground(_ item: BackgroundItem, of agentID: UUID) async {
        await attempt {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsStopBackground,
                                                           DaemonAPI.StopBackgroundRequest(agentID: agentID, itemID: item.id))
        }
    }

    /// Stop a session and every session it started that is running (#835).
    func stopAll(_ id: UUID) async {
        for agent in [work.agent(id)].compactMap({ $0 }) + work.liveDescendants(of: id) where work.canStop(agent) {
            await stop(agent.id)
        }
    }

    func archive(_ id: UUID, andLeave: Bool = false) async {
        guard let undo = await ArchiveActions.archiveWithChildren(id, in: work, andLeave: andLeave,
                                                                   archiveOne: archiveOne) else { return }
        // Undo for a few seconds, at the foot of the list (#1534).
        archiveUndo = undo
    }

    /// ⌫ over a selection in the sidebar: every session and workflow in it, with one Undo
    /// for all of them, "Archived 3 sessions" (#1664). Workflows go after the sessions.
    func archive(sessions: [UUID], workflows: [WorkflowSummary]) async {
        var agentIDs: [UUID] = []
        var title: String?
        var stopped = false
        var count = 0
        for id in sessions where work.agent(id)?.state != .archived {
            guard let one = await ArchiveActions.archiveWithChildren(id, in: work, andLeave: false,
                                                                     archiveOne: archiveOne) else { continue }
            agentIDs += one.agentIDs.filter { !agentIDs.contains($0) }
            title = title ?? one.title
            stopped = stopped || one.stopped
            count += 1
        }
        var flows: [WorkflowSummary] = []
        for summary in workflows {
            guard await setWorkflowArchived(summary, true) else { continue }
            flows.append(summary)
            title = title ?? summary.workflow.name
        }
        guard count + flows.count > 0 else { return }
        archiveUndo = ArchiveUndo(agentIDs: agentIDs, title: title, stopped: stopped,
                                  sessions: count, workflows: flows)
    }

    /// The last Archive, while Undo is offered for it (#1534).
    var archiveUndo: ArchiveUndo?

    /// Undo after Archive (#1534): Unarchive what that Archive put away. One that Archive
    /// stopped stays stopped.
    func undoArchive() async {
        guard let undo = archiveUndo else { return }
        archiveUndo = nil
        for id in undo.agentIDs { await unarchive(id) }
        for summary in undo.workflows { await setWorkflowArchived(summary, false) }
    }

    /// The strip's seconds are over.
    func dismissArchiveUndo(_ undo: ArchiveUndo) {
        if archiveUndo?.id == undo.id { archiveUndo = nil }
    }

    @discardableResult
    private func archiveOne(_ id: UUID, andLeave: Bool) async -> Bool {
        let archived = await act(.archive, on: id) {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsArchive, DaemonAPI.AgentRequest(agentID: id))
        }
        // One path for menu, strip, swipe, ⌫ and the row: leave the chat when asked,
        // so Archive always means the same thing wherever it is pressed. Not when it
        // failed: the chat stays in front, under the reason why (073).
        if archived, andLeave, selection == id { selection = nil }
        return archived
    }

    func unarchive(_ id: UUID) async {
        await attempt { try await self.client(forAgent: id).call(DaemonAPI.Method.agentsUnarchive, DaemonAPI.AgentRequest(agentID: id)) }
    }

    /// Mark as Unread / Mark as Read, from the row's menu (#70).
    /// Ask the session's host to start its runtime ahead of a prompt (#183): the session
    /// was opened, or somebody is typing in its box. Once per session and reason in a
    /// while, however many keys are pressed; the host debounces too. Silent either way:
    /// an older host that does not know the call is simply not warmed.
    func prewarm(_ id: UUID, _ why: DaemonAPI.PrewarmRequest.Why) async {
        guard let agent = work.agent(id), agent.state == .finished || agent.state == .stopped else { return }
        let key = "\(id) \(why.rawValue)"
        if let last = prewarmed[key], Date().timeIntervalSince(last) < 15 { return }
        prewarmed[key] = Date()
        if prewarmed.count > 64 { prewarmed = prewarmed.filter { Date().timeIntervalSince($0.value) < 15 } }
        _ = try? await client(forAgent: id).call(DaemonAPI.Method.agentsPrewarm,
                                                 DaemonAPI.PrewarmRequest(agentID: id, why: why))
    }

    /// The person's title for a session (#751), or with an empty one the runtime's again.
    func rename(_ id: UUID, to title: String) async {
        await attempt(on: work.agent(id)?.host ?? .mac) {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsRename,
                                                     DaemonAPI.RenameRequest(agentID: id, title: title))
        }
    }

    func setUnread(_ id: UUID, _ unread: Bool) async {
        await attempt {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsSetUnread,
                                                     DaemonAPI.SetUnreadRequest(agentID: id, unread: unread))
        }
    }

    /// Mute Notifications, or Unmute, from the row's or the Session menu (#2003).
    func setMuted(_ id: UUID, _ muted: Bool) async {
        await attempt(on: work.agent(id)?.host ?? .mac) {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsSetMuted,
                                                     DaemonAPI.SetMutedRequest(agentID: id, muted: muted))
        }
    }

    /// Whether the host of this session can mute it: one from before #2003 cannot.
    func canMute(_ agent: Agent) -> Bool {
        agent.state != .archived && host(agent.host, has: Capability.mute1)
    }

    /// Whether the answer went, so the card can give its buttons back when it did not.
    /// One `sendID` for every try, so the retry through a fresh connection is the same
    /// answer and not a second one (#86).
    @discardableResult
    func answer(_ request: PermissionRequest, optionID: String) async -> Bool {
        let host = work.agent(request.agentID)?.host ?? .mac
        let sendID = UUID()
        if host != .mac {
            return await sendToServer(host) { client in
                try await client.call(DaemonAPI.Method.permissionsAnswer,
                                      DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID,
                                                              sendID: sendID))
            }
        }
        return await attempt {
            try await self.client(forAgent: request.agentID).call(DaemonAPI.Method.permissionsAnswer,
                                       DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID,
                                                               sendID: sendID))
        }
    }

    /// What an option control should read: the choice just made, else what is in
    /// force, else what the runtime says is current. The bookkeeping is the kit's, so a
    /// phone's control settles the same way (033).
    func chosenOption(_ optionID: String, for agent: Agent, advertised: ConfigOption) -> JSONValue? {
        work.chosenOption(optionID, for: agent, advertised: advertised)
    }

    /// Set an option on a live agent, and show the choice at once.
    ///
    /// Deliberately not `async`. The optimistic value has to be written on the same
    /// turn as the click, and the body of a `Task` does not start until the next one.
    func setOption(agentID: UUID, optionID: String, value: JSONValue) {
        let sequence = work.beginOption(agentID: agentID, optionID: optionID, value: value)
        Task {
            await attempt {
                try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsSetOption,
                                           DaemonAPI.SetOptionRequest(agentID: agentID, optionID: optionID, value: value))
            }
            work.settleOption(agentID: agentID, optionID: optionID, sequence: sequence)
        }
    }

    // MARK: The mode you keep choosing

    /// What was last chosen for this runtime, on this Mac or a phone. The daemon keeps
    /// it now — it writes on a start and on a conversation's mode changing — and this
    /// reads the copy `modes/changed` keeps current (029).
    func rememberedMode(for runtimeID: String) -> JSONValue? {
        work.rememberedMode(for: runtimeID)
    }

    /// The daemon's memory. A daemon too old to know the method leaves the form opening
    /// on the runtime's own current mode, which is what it did before anything was
    /// remembered.
    func refreshModes() async {
        let modes = try? await macClient.call(DaemonAPI.Method.modesRemembered, Optional<Int>.none,
                                           returning: DaemonAPI.RememberedModes.self)
        if let modes { work.replaceRememberedModes(modes) }
    }

    // MARK: Language servers

    /// A source file's problems, from its language server on the agent's host (#844). A
    /// failure is thrown, for the editor to say (#1687).
    func diagnose(path: String, text: String, of agentID: UUID) async throws -> DaemonAPI.FileDiagnostics {
        try await client(forAgent: agentID).call(
            DaemonAPI.Method.filesDiagnostics,
            DaemonAPI.FileDiagnosticsRequest(agentID: agentID, path: path, text: text),
            returning: DaemonAPI.FileDiagnostics.self)
    }

    /// What the file's language server would write at a line and column (#844), or why
    /// there is nothing: the host's reason, or the failure (#1688).
    func complete(path: String, text: String, line: Int, column: Int, of agentID: UUID) async -> DaemonAPI.FileCompletions {
        do {
            return try await client(forAgent: agentID).call(
                DaemonAPI.Method.filesComplete,
                DaemonAPI.FileCompletionRequest(agentID: agentID, path: path, text: text, line: line, column: column),
                returning: DaemonAPI.FileCompletions.self)
        } catch {
            return DaemonAPI.FileCompletions(items: [], reason: DaemonAPI.FileCompletions.failure(error))
        }
    }

    // MARK: Simulators

    /// The Simulator pane's calls (#842), to the session's host.
    func simulatorCalls(for agentID: UUID) -> SimulatorCalls {
        SimulatorCalls(
            list: { try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsList, Optional<String>.none, returning: DaemonAPI.SimulatorList.self) },
            boot: { udid in _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsBoot, DaemonAPI.SimulatorRequest(udid: udid)) },
            shutdown: { udid in _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsShutdown, DaemonAPI.SimulatorRequest(udid: udid)) },
            screen: { udid, maxHeight in try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsScreen, DaemonAPI.SimulatorScreenRequest(udid: udid, maxHeight: maxHeight),
                returning: DaemonAPI.SimulatorScreen.self) },
            tap: { udid, x, y in _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsTap, DaemonAPI.SimulatorTapRequest(udid: udid, x: x, y: y)) },
            home: { udid in _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsHome, DaemonAPI.SimulatorRequest(udid: udid)) })
    }

    // MARK: The user's shells

    /// Run a command from a reply in the session's shell (#1533), once the shell's pane has
    /// it attached: a few seconds at most. What it prints is kept for Tell the Agent.
    func runCommand(_ command: String, in agentID: UUID) async {
        let shell = shellClient(for: agentID)
        guard await ShellCommandActions.run(command, in: shell) else {
            problem = ShellCommandActions.unavailableMessage
            return
        }
    }

    /// Tell the Agent (#1533): the command run from a reply and the end of what it printed,
    /// sent to the session as the person's prompt.
    func tellAgent(about command: String, in agentID: UUID) async {
        let report = ShellCommandActions.report(command, recent: shellClient(for: agentID).recent)
        _ = await send(report, to: agentID)
    }

    /// The pane's end of one of an agent's shells, made once per shell per window.
    func shellClient(for agentID: UUID, shell: Int = 0) -> ShellClient {
        let key = ShellKey(agentID: agentID, shell: shell)
        if let existing = shellClients[key] { return existing }
        let fresh = ShellClient(agentID: agentID, shell: shell, client: client(forAgent: agentID),
                                describe: { [weak self] error in self?.describeForShell(error) ?? "\(error)" })
        shellClients[key] = fresh
        return fresh
    }

    /// One of the folder's own shells (#418), on the folder's host, made once per
    /// folder and tab per window and held by the same count as an agent's.
    func acquireFolderShell(_ folder: FolderKey, shell: Int = 0) -> ShellClient {
        let id = FolderShell.id(for: folder.folder)
        let key = ShellKey(agentID: id, shell: shell)
        folderShellHosts[id] = folder.host
        if shellClients[key] == nil {
            shellClients[key] = ShellClient(agentID: id, shell: shell, folderContext: folder.folder,
                                            client: client(for: folder.host),
                                            describe: { [weak self] error in self?.describeForShell(error) ?? "\(error)" })
        }
        return acquireShell(for: id, shell: shell)
    }

    /// The shells the folder's host holds for the folder, so the panel opens with the
    /// tabs it had. Nil from a host too old to list them.
    func folderShellNumbers(_ folder: FolderKey) async -> [Int]? {
        let id = FolderShell.id(for: folder.folder)
        folderShellHosts[id] = folder.host
        return await shellNumbers(for: id)
    }

    /// A new tab in the folder's panel, numbered by its host. Nil from a host too old to
    /// open one for a folder, and the panel numbers it itself.
    func openFolderShell(_ folder: FolderKey) async -> Int? {
        let id = FolderShell.id(for: folder.folder)
        folderShellHosts[id] = folder.host
        return await ShellClient.open(agentID: id, folder: folder.folder, on: client(for: folder.host))
    }

    /// This window's ends of the shells one host holds.
    private func shellClients(on host: MachineRef) -> [ShellClient] {
        shellClients.values.filter { (folderShellHosts[$0.agentID] ?? self.host(ofAgent: $0.agentID)) == host }
    }

    /// A server's new connection knows none of this window's screens: they attach
    /// again, and are given only what they missed (#401).
    private func reattachShells(on host: MachineRef) async {
        for shell in shellClients(on: host) {
            shell.lostConnection()
            await shell.reattachIfLost()
        }
    }

    /// The shells the daemon holds for an agent, so the pane opens with the tabs it
    /// had (055). Nil from a daemon too old to hold more than one — a server not yet
    /// updated — and the pane then offers only the one.
    func shellNumbers(for agentID: UUID) async -> [Int]? {
        let response = try? await client(forAgent: agentID).call(
            DaemonAPI.Method.shellList, DaemonAPI.AgentRequest(agentID: agentID),
            returning: DaemonAPI.ShellListResponse.self)
        return response?.shells
    }

    /// A new terminal tab: the daemon starts the shell and says its number (#401). Nil
    /// from a host too old to, and the pane numbers it itself.
    func openShell(for agentID: UUID) async -> Int? {
        await ShellClient.open(agentID: agentID, on: client(forAgent: agentID))
    }

    /// A shell's screen took this window's end of it: counted, so the end is let go of
    /// when the last screen showing it goes (#213).
    func acquireShell(for agentID: UUID, shell: Int) -> ShellClient {
        let key = ShellKey(agentID: agentID, shell: shell)
        parkedShells.removeAll { $0 == key }
        let client = shellClient(for: agentID, shell: shell)
        shellScreens[key, default: 0] += 1
        return client
    }

    /// A shell's screen went (another agent chosen, the inspector closed). With no other
    /// screen on it, this window lets go of its end, so it holds one only for a screen
    /// there is (#213). The shell runs on (FR-026), and the next screen attaches again
    /// and replays what it printed.
    func releaseShell(_ client: ShellClient) {
        let key = ShellKey(agentID: client.agentID, shell: client.shell)
        guard shellClients[key] === client else { return }
        let left = (shellScreens[key] ?? 1) - 1
        guard left <= 0 else { shellScreens[key] = left; return }
        shellScreens[key] = nil
        // Detached, so the shell is not counted as on the Mac's screen, but kept with
        // its emulator: coming back asks only for what it missed (#401).
        Task { await client.detach() }
        parkedShells.append(key)
        while parkedShells.count > Self.parkedShellLimit {
            let oldest = parkedShells.removeFirst()
            guard let parked = shellClients.removeValue(forKey: oldest) else { continue }
            parked.onOutput = nil
            parked.screen = nil
        }
    }

    /// The user closed a terminal tab: the shell ends, and this window forgets it.
    func closeShell(agentID: UUID, shell: Int) async {
        let client = shellClient(for: agentID, shell: shell)
        shellClients[ShellKey(agentID: agentID, shell: shell)] = nil
        shellScreens[ShellKey(agentID: agentID, shell: shell)] = nil
        parkedShells.removeAll { $0 == ShellKey(agentID: agentID, shell: shell) }
        await client.close()
    }

    /// Files under the session's folders whose name or path holds `term`, found by the
    /// host the session is on (#415): Open File… on a server searches the server.
    /// Empty when it does not answer, which the search shows as nothing found.
    func findFiles(_ term: String, for agentID: UUID) async -> [FileMention] {
        guard !term.isEmpty else { return [] }
        let found = try? await client(forAgent: agentID).call(DaemonAPI.Method.filesMention,
                                                              DaemonAPI.FileMentionRequest(agentID: agentID, term: term),
                                                              returning: [DaemonAPI.FileMentionDTO].self)
        return (found ?? []).map(\.mention)
    }

    /// What the person typed on a live page, sent to the daemon to put on disk (022).
    /// The daemon writes rather than the window so that it knows the person did. Nil
    /// on success; on failure, the sentence to show beside the passage, with the draft
    /// kept.
    /// The editor's save that checks the file first (#1858).
    func writeArtifact(agentID: UUID, path: String, text: String, base: String) async -> SaveOutcome {
        do {
            try await client(forAgent: agentID).call(DaemonAPI.Method.artifactWrite,
                                  DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text, base: base))
            return .saved
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.fileChanged {
            return .changedOnDisk
        } catch let error as JSONRPCError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func writeArtifact(agentID: UUID, path: String, text: String) async -> String? {
        do {
            try await client(forAgent: agentID).call(DaemonAPI.Method.artifactWrite,
                                  DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text))
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// A shell that will not start is shown inside the pane, not in the window's alert:
    /// it is about that pane, and an alert over the whole window would be out of
    /// proportion to it.
    func describeForShell(_ error: any Error) -> String {
        describe(error)
    }

    /// Which transcript entry the conversation should bring into view.
    ///
    /// Set by the artifacts pane so that getting from a thing back to the message it
    /// came from is one tap (FR-042). Cleared once the transcript has scrolled to it.
    var focusedEntry: UUID?

    /// Where `focusedEntry` is in the transcript, when Find knows it (#1532).
    var focusedIndex: Int?

    func focusEntry(_ id: UUID, at index: Int? = nil) {
        focusedIndex = index
        focusedEntry = id
    }

    func clearFocus() {
        focusedEntry = nil
        focusedIndex = nil
    }

    /// Find in Chat (#1532): what was said in a chat that holds `text`, found by its host.
    func find(_ text: String, in agentID: UUID) async -> DaemonAPI.FindResult? {
        try? await client(forAgent: agentID).call(DaemonAPI.Method.agentsFind,
                                                   DaemonAPI.FindRequest(agentID: agentID, text: text),
                                                   returning: DaemonAPI.FindResult.self)
    }

    /// Go to a match in the open chat: earlier pages come in until its turn is in hand
    /// (`AgentsModel.reveal`, bounded), then the chat goes to it, or as near as it can.
    func reveal(_ match: DaemonAPI.FindMatch) async {
        await work.reveal(index: match.index) { await self.loadEarlier(turns: $0) }
        focusEntry(match.entryID, at: match.index)
    }

    /// What this agent last asked the user to look at, taken rather than read: a file
    /// that has been put in front of somebody is not still waiting to be.
    func takeFileToShow(for agentID: UUID) -> ShownFile? {
        work.takeFileToShow(for: agentID)
    }

    // MARK: Runtimes

    /// Sign the runtime in, or one of its added accounts (#840) when `accountID` is set.
    func signIn(runtimeID: String, methodID: String, accountID: String? = nil) async -> String? {
        do {
            let account = try await macClient.call(DaemonAPI.Method.runtimeAuthenticate,
                                                DaemonAPI.AuthenticateRequest(runtimeID: runtimeID,
                                                                              methodID: methodID, accountID: accountID),
                                                returning: RuntimeAccount.self)
            if accountID == nil { accounts[runtimeID] = account }
            await refreshRuntimes()
            if accountID != nil { await refreshAccountProfiles() }
            return nil
        } catch let error as JSONRPCError {
            // A method that needs a terminal comes back as the command to run, which is
            // the runtime's own advice rather than ours.
            if let command = error.data?["command"]?.stringValue { return command }
            problem = describe(error)
            return nil
        } catch {
            problem = describe(error)
            return nil
        }
    }

    func signOut(runtimeID: String) async {
        await attempt {
            _ = try await self.macClient.call(DaemonAPI.Method.runtimeLogOut,
                                           DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                                           returning: [UUID].self)
        }
        await refreshAccounts()
        await refreshAgents()
    }

    func setProvider(runtimeID: String, providerID: String) async {
        await attempt {
            _ = try await self.macClient.call(DaemonAPI.Method.runtimeSetProvider,
                                           DaemonAPI.SetProviderRequest(runtimeID: runtimeID,
                                                                        providerID: providerID),
                                           returning: RuntimeAccount.self)
        }
        await refreshAccounts()
    }

    func disableProvider(runtimeID: String, providerID: String) async {
        await attempt {
            _ = try await self.macClient.call(DaemonAPI.Method.runtimeDisableProvider,
                                           DaemonAPI.SetProviderRequest(runtimeID: runtimeID,
                                                                        providerID: providerID),
                                           returning: RuntimeAccount.self)
        }
        await refreshAccounts()
    }

    /// Which agents a sign-out would stop, so the user is told before it happens.
    func agentsHolding(runtimeID: String) -> [Agent] {
        agents.filter { $0.runtimeID == runtimeID && $0.state.holdsRuntime }
    }

    // MARK: Sessions the app did not start

    func runtimeSessions(runtimeID: String, cwd: URL) async -> [RuntimeSession] {
        do {
            return try await selectedHostClient.call(DaemonAPI.Method.sessionsList,
                                         DaemonAPI.SessionsListRequest(runtimeID: runtimeID, cwd: cwd),
                                         returning: [RuntimeSession].self)
        } catch {
            problem = describe(error)
            return []
        }
    }

    func adopt(runtimeID: String, session: RuntimeSession) async {
        do {
            let id = try await selectedHostClient.call(DaemonAPI.Method.sessionsAdopt,
                                           DaemonAPI.AdoptRequest(runtimeID: runtimeID,
                                                                  sessionID: session.sessionID,
                                                                  cwd: session.cwd),
                                           returning: UUID.self)
            await refreshAgents()
            selection = id
        } catch {
            fail(error, on: selectedFolderHost)
        }
    }

    func deleteRuntimeSession(runtimeID: String, sessionID: String) async {
        await attempt {
            try await self.selectedHostClient.call(DaemonAPI.Method.sessionsDelete,
                                       DaemonAPI.DeleteSessionRequest(runtimeID: runtimeID,
                                                                      sessionID: sessionID,
                                                                      confirmed: true))
        }
    }

    func fork(_ id: UUID) async {
        do {
            let branch = try await client(forAgent: id).call(DaemonAPI.Method.agentsFork,
                                               DaemonAPI.AgentRequest(agentID: id),
                                               returning: UUID.self)
            await refreshAgents()
            selection = branch
        } catch {
            problem = describe(error)
        }
    }

    /// Branch from Here (#1658): a new session from just before one of the person's prompts,
    /// opened as Branch opens one, with that prompt in its bar to change and send. The words
    /// go in as the new session's draft, so its bar has them however it comes on screen.
    func branch(from entryID: UUID, of agentID: UUID, text: String) async {
        do {
            let branch = try await client(forAgent: agentID).call(DaemonAPI.Method.agentsBranchFrom,
                                               DaemonAPI.BranchFromRequest(agentID: agentID, entryID: entryID),
                                               returning: UUID.self)
            DraftKeeper.shared.note(text, [], for: .agent(branch))
            await refreshAgents()
            selection = branch
        } catch {
            problem = describe(error)
        }
    }

    /// An answer pressed on a banner (#1170): the card's own answer, through the same call.
    /// A question no longer held was answered somewhere else, and nothing is sent: the
    /// daemon would refuse it, and its banner goes with the next sweep.
    func answerFromBanner(_ token: String, _ quick: QuickAnswer, typed: String?) async {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let sent: Bool
        switch parts[0] {
        case "permission":
            guard let request = permissions.first(where: { $0.id.uuidString == parts[1] }) else {
                note("banner: \(token) is over, nothing sent")
                return
            }
            sent = await answer(request, optionID: quick.id)
        case "elicitation":
            guard let request = elicitations.first(where: { $0.id.uuidString == parts[1] }),
                  let content = quick.content(typed: typed) else {
                note("banner: \(token) is over, or nothing typed; nothing sent")
                return
            }
            sent = await answerElicitation(request, action: .accept, content: content)
        default:
            return
        }
        note("banner: \(token) \(quick.kind.rawValue) \(sent ? "answered" : "not sent")")
    }

    // MARK: Forms

    /// Whether the answer went, as `answer(_:optionID:)` (#86).
    @discardableResult
    func answerElicitation(_ request: ElicitationRequest,
                           action: DaemonAPI.AnswerElicitationRequest.Action,
                           content: [String: JSONValue] = [:]) async -> Bool {
        let sendID = UUID()
        let sent = await attempt {
            try await self.client(forAgent: request.agentID).call(DaemonAPI.Method.elicitationsAnswer,
                                       DaemonAPI.AnswerElicitationRequest(requestID: request.id,
                                                                          action: action,
                                                                          content: content,
                                                                          sendID: sendID))
        }
        await refreshElicitations()
        return sent
    }

    func dismissProblem() { problem = nil }

    /// Something the window worked out for itself, said the same way as anything the
    /// daemon says.
    func show(problem: String) { self.problem = problem }

    /// Whether the work went through, for the callers that must undo something when
    /// it did not.
    @discardableResult
    /// Files attached from this Mac, copied to the server first (037, FR-015). A path
    /// on the Mac means nothing to an agent on a server, so each file that exists here
    /// is written into the agent's folder there, and the attachment points at that
    /// copy. Pictures already travel as bytes, and a file named from the server's own
    /// files pane is already a path there. Nil, with the reason said, when a file
    /// cannot go: the prompt then stays in the field.
    private func carry(_ attachments: [Attachment], to host: MachineRef, for agentID: UUID) async -> [Attachment]? {
        var carried: [Attachment] = []
        for attachment in attachments {
            guard case .resourceLink(let uri, let name, let mimeType, _, _) = attachment.block,
                  let url = URL(string: uri), url.isFileURL,
                  let agent = work.agent(agentID),
                  !url.path.hasPrefix(agent.cwd.path),
                  FileManager.default.fileExists(atPath: url.path) else {  // store-ok: a file the person attached: picked or dropped, so the sandbox lets it be read
                carried.append(attachment)
                continue
            }
            // Looked at before it is read, and read off the main thread (#930): a film
            // attached by mistake is refused at once, not after it is read whole.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= DaemonAPI.attachmentLimit else {
                problem = "\(name) is too big to send to \(hosts.label(host))."
                return nil
            }
            let data: Data
            do {
                data = try await Task.detached {
                    try Data(contentsOf: url)  // store-ok: a file the person attached: picked or dropped
                }.value
            } catch {
                // Not "too big": a file this window may not read, or one gone, says so (073).
                problem = "\(name) could not be read to send to \(hosts.label(host)): \(error.localizedDescription)"
                return nil
            }
            guard data.count <= DaemonAPI.attachmentLimit else {
                problem = "\(name) is too big to send to \(hosts.label(host))."
                return nil
            }
            do {
                let written = try await client(for: host).call(
                    DaemonAPI.Method.filesWrite, DaemonAPI.FilesWriteRequest(agentID: agentID, name: name, data: data),
                    returning: DaemonAPI.FilesWriteResponse.self)
                carried.append(Attachment(block: .resourceLink(uri: URL(filePath: written.path).absoluteString,
                                                               name: name, mimeType: mimeType, size: data.count),
                                          displayName: attachment.displayName, byteCount: data.count))
            } catch {
                problem = "\(name) could not be sent to \(hosts.label(host))."
                return nil
            }
        }
        return carried
    }

    /// A send to a server, delivered once or reported as not sent (037, FR-020).
    ///
    /// The caller makes the `sendID` once, so every retry here is the same send: a
    /// daemon that acted on the first try and lost its reply with the connection answers
    /// the retry as it did, and acts once. A transport error is retried as the server
    /// comes back, for up to 30 seconds; a refusal from the daemon is its answer and is
    /// not retried.
    private func sendToServer(_ host: MachineRef,
                              _ work: @escaping (DaemonClient) async throws -> Void) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            do {
                try await work(client(for: host))
                return true
            } catch let refused as JSONRPCError where refused.code == DaemonAPI.Failure.kept {
                // Kept for a stopped workspace (#691 US3): its bubble says so; it goes when the host is up.
                noteKept(refused)
                return true
            } catch let refused as JSONRPCError {
                fail(refused, on: host)
                return false
            } catch {
                guard ContinuousClock.now < deadline else {
                    problem = "Not sent — \(hosts.label(host)) went offline."
                    return false
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @discardableResult
    /// `quietWhenDown`: a server the offline strip already explains raises no alert (#963),
    /// and neither does this Mac's own refresh with no host on this Mac (#1503).
    func attempt(on host: MachineRef = .mac, quietWhenDown: Bool = false, _ work: () async throws -> Void) async -> Bool {
        // Already known to be quiet: said now, naming why, not after waiting out a
        // connect the reconnect loop is already making (#83, #303). The strip has Try Again.
        // With no host on this Mac, nothing is asked: a pane's own refresh (quiet) says
        // nothing, as the pane says it; what a person asked for says there is none (#1503).
        if host == .mac, noHostOnThisMac {
            if !quietWhenDown { problem = HostSet.noMacHostProblem }
            return false
        }
        if host == .mac, !controlPlaneAway, hosts.isOffline(macHostElsewhere ?? .mac) || macHostNotice != nil {
            problem = macHostNotice?.action ?? HostSet.macDownProblem
            return false
        }
        do {
            try await work()
            return true
        } catch {
            // One retry through a fresh connection: the daemon having gone idle is not
            // something the user should have to know about.
            if !isConnected {
                await connect()
                if isConnected, (try? await work()) != nil { return true }
            }
            if quietWhenDown, host != .mac, hosts.isOffline(host) || OfflineWords.hostDown(error) { return false }
            fail(error, on: host)
            return false
        }
    }

    /// A failure put in front of the person. A runtime of this Mac's that needs signing
    /// in gets its sign-in sheet; everything else is said in words. A server's runtime
    /// is signed in on the server, which this sheet cannot do, so it stays words.
    private func fail(_ error: any Error, on host: MachineRef) {
        if error is SaidAlready { return }
        if host == .mac, let error = error as? JSONRPCError, error.code == DaemonAPI.Failure.needsSignIn,
           let runtimeID = error.data?["runtimeID"]?.stringValue {
            signInRuntimeID = runtimeID
            return
        }
        // A server's Claude signs in through this Mac's own sign-in (056): with none to
        // relay, the sheet that signs it in on this Mac, and a sentence saying so.
        if host != .mac, let error = error as? JSONRPCError, error.code == DaemonAPI.Failure.signInWanted,
           let wanted = try? error.data?.decode(DaemonAPI.SignInWanted.self) {
            problem = error.message + " Sign it in on this Mac, or use \(hosts.label(host))’s own sign-in in Settings ▸ Machines."
            signInRuntimeID = wanted.runtime
            return
        }
        problem = describe(error)
    }

    /// The sign-in sheet, put away. Signed in or not, it does not come back for this
    /// runtime by itself until the runtime has been signed in once more.
    func putAwaySignIn() {
        if let runtimeID = signInRuntimeID, accounts[runtimeID]?.state != .ready {
            signInsPutAway.insert(runtimeID)
        }
        signInRuntimeID = nil
    }

    /// What a person can read. The daemon's errors are already written for someone
    /// looking at a screen, so they are shown as they are.
    func describe(_ error: any Error) -> String {
        if let error = error as? JSONRPCError {
            // A runtime that needs signing in says so, and says how. The command is
            // the runtime's own, which is better advice than any we could invent.
            if error.code == DaemonAPI.Failure.needsSignIn,
               let methods = try? error.data?["authMethods"]?.decode([ACP.AuthMethod].self),
               let command = methods.compactMap(\.terminalCommand).first {
                return "\(error.message). Run: \(command)"
            }
            return error.message
        }
        if let error = error as? DaemonClient.ConnectError {
            switch error {
            case .couldNotConnect:
                return macHostNotice?.action ?? HostSet.macDownProblem
            case .socketPathTooLong(let path):
                // Only ever seen by somebody who passed `--root`, and the fix is in
                // their hands: a shorter path.
                return "That folder is too deep to run a daemon in: \(path) is past the 104 bytes a socket may be named with."
            }
        }
        // This window's own writes: a full disk or a refused folder, in words (#88).
        if let failure = WriteFailure(error, keeping: "that") { return failure.message }
        return String(describing: error)
    }
}

/// A failure already put in front of the person in its own way, so `fail` says nothing more.
struct SaidAlready: Error {}

/// A new agent a view filled in, for the bar on `folder`'s page (#834).
struct OfferedStart: Equatable {
    var folder: URL
    var start: AppViewStart
}

/// A send refused because the agent's folder has gone (#119): what the daemon said, and
/// what was typed, for Continue in the folder to carry on with.
struct FolderGoneAsk: Identifiable, Equatable {
    let id = UUID()
    let agentID: UUID
    let message: String
    let text: String
    let attachments: [Attachment]
}
