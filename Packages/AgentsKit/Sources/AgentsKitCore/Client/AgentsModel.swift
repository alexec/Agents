import Foundation
import Observation

/// What the work looks like to anything watching it: the Mac's window, and a phone on
/// a train.
///
/// Neither of them owns any of this. The daemon does. This is the view of it a client
/// keeps in hand — the agents, the projects, the questions waiting, and the page of
/// transcript being read — together with what each notification means, which is the
/// part that must not be written twice. Two clients that disagreed about what
/// `agent/permission` with a nil request means would be two clients that disagree
/// about whether the user has already answered, which is the one thing this feature
/// cannot get wrong.
///
/// Nothing is decided here. Every method either files what arrived or replaces what
/// was there. Anything that needs a decision belongs to the daemon.
@MainActor
@Observable
public final class AgentsModel {
    /// Every agent held, newest activity first. Read by pages about all the work; a
    /// sidebar fold or a row reads its project's `shelf` or its agent instead, so one
    /// agent changing does not redraw them all (#165).
    public private(set) var agents: [Agent] = []
    /// How many agents are held: moves only when one comes or goes, for a view that
    /// wants to know that and not every change to every one of them.
    public private(set) var agentCount = 0
    /// Moves each time an agent held here becomes archived: what lets the window let go
    /// of that agent's draft without looking at everything (#176).
    public private(set) var archivals = 0
    public private(set) var projects: [DaemonAPI.ProjectSummary] = []
    public private(set) var permissions: [PermissionRequest] = []
    public private(set) var elicitations: [ElicitationRequest] = []
    /// What wants a person and where each is showing, as the daemon last said (021).
    /// The model stores the fact; it posts nothing and decides nothing.
    public private(set) var needs: [NeedID: Need] = [:]
    public private(set) var deliveries: [NeedID: Surface] = [:]

    /// Every project's workflows, newest state winning. Here rather than in the Mac's
    /// own model because a workflow is about the work, and the phone will want them.
    public private(set) var workflows: [WorkflowSummary] = []

    /// Each project's Dashboard row (074), by its standardized folder: kept current by
    /// `dashboard/changed`, which carries it.
    public private(set) var dashboardSummaries: [URL: DashboardSummary] = [:]
    /// The Dashboards a screen has asked for, by folder. Refetched by whoever shows one
    /// when `dashboardRevisions` moves: the notification says only that it changed.
    public var dashboards: [URL: DashboardSnapshot] = [:]
    public private(set) var dashboardRevisions: [URL: Int] = [:]

    /// Each project's pinned pages (#159), by its standardized folder: kept current by
    /// `pins/changed`, which carries them. A project with none is absent.
    public private(set) var pins: [URL: [PinView]] = [:]
    /// Each project's pinned sessions (#180), by its standardized folder, in their order:
    /// kept current by `pins/changed` as the pages are. A project with none is absent.
    public private(set) var sessionPins: [URL: [UUID]] = [:]
    /// Bumped by `pages/changed`: a page a screen may be showing changed on disk. Whoever
    /// shows one reads it again, with its stamp, so an unchanged file costs nothing.
    public private(set) var pageRevisions: [URL: Int] = [:]

    /// Each project's plugins, by its standardized folder, as the daemon last listed them:
    /// which are waiting for the person's OK (security review, S2).
    public private(set) var plugins: [URL: [ProjectPlugin]] = [:]

    /// The transcript of the agent being read, and only that one. A client holds one
    /// page of one conversation, because an hour of transcript is not something to
    /// carry around, least of all over a mobile connection.
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var firstEntryIndex = 0
    /// Whether there is more of the turn in progress before `entries`.
    public private(set) var hasMoreBefore = false
    /// The finished turns before `entries`, each as its ask and last block: what the
    /// chat draws of them until one is opened. `entries` start at `openTurnStart`.
    public private(set) var turns: [TurnSummary] = []
    public private(set) var firstTurn = 0
    public private(set) var openTurnStart = 0
    public var hasMoreTurns: Bool { firstTurn > 0 }
    /// Whether anything at all of the conversation comes before what is in hand.
    public var hasMoreOfTheConversation: Bool { hasMoreBefore || hasMoreTurns }
    /// The page as the chat draws it: chunks joined, tool calls folded into runs.
    ///
    /// Kept here, folded once as each entry lands, rather than folded by the view on
    /// every redraw. A reply arrives several chunks a second and the fold grows with
    /// the page, so folding per redraw was the page's whole length of work, again,
    /// for every word.
    public private(set) var transcriptItems: [TranscriptItem] = []
    @ObservationIgnored private var display = TranscriptDisplayBuilder()
    /// Every entry in hand, by id, so one that reaches us twice is kept once.
    @ObservationIgnored private var entryIDs: Set<UUID> = []
    /// Entries heard as they happened since the last page arrived.
    ///
    /// A page and the entries streaming past it come by two different doors — a reply
    /// and a notification — and nothing orders one against the other. An entry written
    /// after the daemon read the page can be applied before the page lands, and the
    /// page would then replace it: a chunk of a reply gone from the middle of the chat
    /// until it was next opened. These are laid back on top of the page. Bounded,
    /// because a chat watched for hours hears thousands between pages.
    @ObservationIgnored private var heardSincePage: [TranscriptEntry] = []
    private static let heardSincePageLimit = 1_000

    /// Whether the chat is following the end of the conversation, as the chat says.
    ///
    /// The page is trimmed at the front only while it is. A window left on a busy agent
    /// for an afternoon heard every entry of it, and transcripts run to tens of
    /// megabytes, so what streams in cannot simply pile up. But the rows at the top are
    /// the ones somebody who scrolled up is reading, and taking them away would move
    /// the page under them, so while they are away from the end nothing goes.
    @ObservationIgnored public var isFollowingEnd = true
    /// How many entries a followed page keeps: three of the daemon's 200-entry pages,
    /// many screens more than a pane shows. Trimmed only once a further page has
    /// piled up past it, so the fold is done again once a page rather than per entry.
    static let entriesKept = 600
    static let entriesTrimmedAt = 800
    /// And never fewer rows than this, whatever the entries come to. A run of tool
    /// calls is one row however many entries it took, and a page trimmed to a few rows
    /// would not fill the pane: the chat would ask for the page before straight back.
    static let itemsKept = 100
    /// Told the entries that go when the front of the page is trimmed, for anything
    /// that folds the whole conversation into something (the phone's marks on the
    /// files the agent touched) and would lose them otherwise.
    @ObservationIgnored public var onTrimmed: ([TranscriptEntry]) -> Void = { _ in }
    /// When to look at trimming next. Not every entry past the mark: a page that could
    /// not be trimmed (too few rows) would otherwise be measured again for every chunk.
    @ObservationIgnored private var nextTrimAt = entriesTrimmedAt
    /// Each agent by id, and where it was filed: its folder and group as they were.
    @ObservationIgnored private var byID: [UUID: Agent] = [:]
    @ObservationIgnored private var filedAs: [UUID: (folder: URL, host: HostID, group: AgentGroup)] = [:]
    /// Each project's agents, by folder and host, and again by folder alone (#165).
    @ObservationIgnored private var shelves: [ShelfKey: ProjectShelf] = [:]
    @ObservationIgnored private var folderShelves: [URL: ProjectShelf] = [:]
    /// One per agent a view has looked up by id.
    @ObservationIgnored private var cells: [UUID: AgentCell] = [:]
    /// Every agent's title by id, and a count that moves only when one of them does.
    @ObservationIgnored private var titles: [UUID: String] = [:]
    private var titlesRevision = 0

    /// Which agent's transcript is in hand. Entries for anything else are not ours to
    /// keep: the reader is not looking at them and the next selection reloads anyway.
    public var watching: UUID? {
        didSet {
            guard watching != oldValue else { return }
            clearTranscript()
            // A chat opens at its end, whatever the last one was left at.
            isFollowingEnd = true
        }
    }

    /// Files an agent has asked be put in front of the user, one per agent, newest
    /// winning. Held rather than acted on, because the client hearing this may be
    /// showing another conversation.
    public private(set) var filesToShow: [UUID: ShownFile] = [:]

    /// Chats the daemon is queueing to pick back up after a restart, held only while
    /// it is doing it. Not on any record: the queue lives and dies with the daemon
    /// that made it, and a client that was not listening asks `agents/resuming` on
    /// connect rather than inferring it.
    public private(set) var resuming: Set<UUID> = []

    /// What the reader will allow, what today has cost, and which local day that is.
    ///
    /// Seeded by `cost/state` on connect and kept current by `cost/changed`, the way
    /// projects are seeded by `projects/list` and kept current by `project/changed`.
    /// Nil until the daemon has said, so a window shows nothing rather than a zero
    /// it invented. Everything derived from it — whether the day's limit is reached,
    /// what is left, whether it is close — is computed on `CostState` and never sent.
    ///
    /// A window notices the day rolling over by `day` changing here. It must never
    /// consult its own clock: it may be in a different time zone from the daemon's,
    /// and the daemon's is the one the limit uses.
    public private(set) var costState: DaemonAPI.CostState?
    /// How long archived agents are kept and what the archive holds (051). Nil until the
    /// daemon has said, which leaves the settings section out.
    /// Every runtime's state on the Mac (065, US4): Agent Runtimes, the prompt bar's
    /// warning, and the phone's Runtimes list.
    public private(set) var runtimeAllowances: RuntimeAllowances?
    public private(set) var retentionState: DaemonAPI.RetentionState?
    /// What is left of retired agents this client has asked about, by id (051).
    public private(set) var tombstones: [UUID: Tombstone] = [:]
    /// Every resource an agent can lease, who holds it and who is waiting (036), as
    /// the daemon last said. Replaced whole by each `leases/changed`, never merged. Nil
    /// from a daemon too old to have leases, which draws nothing.
    public private(set) var leases: DaemonAPI.LeaseSnapshot?
    /// Every volume that is low on space (#195), as the daemon last said. Replaced whole
    /// by each `disk/changed`. Empty from a daemon too old to say, which draws nothing.
    public private(set) var disk = DiskState()
    /// The newest events (042), newest first, as far back as has been paged in. A new
    /// or changed event from `events/changed` is put in by its position. Empty until a
    /// page has been asked for, and on a daemon too old to have events.
    public private(set) var recentEvents: [Event] = [] {
        didSet { eventsRevision &+= 1 }
    }
    /// The last `shownEvents` worked out, and for what (#137).
    @ObservationIgnored private var eventsRevision = 0
    @ObservationIgnored private var shownMemo: (revision: Int, filter: EventFilter, calendar: Calendar,
                                                shown: ShownEvents)?
    /// Whether the daemon has older events than `recentEvents` reaches.
    public private(set) var moreEvents = false
    /// What `recentEvents` is narrowed to. Set by whoever asks for a page, before it
    /// asks, so a page that comes back for a filter since left is dropped.
    public var eventsFilter = EventFilter()
    /// The time of the newest event heard of, whatever the filter, for the sidebar's
    /// "Last 07:40".
    public private(set) var lastEventAt: Date?
    /// Every agent waiting on something, for the Waiting now strip.
    public private(set) var waitingAgents: [DaemonAPI.WaitingAgent] = []
    /// Whether a page of events has arrived at all, so an empty list can say "nothing
    /// yet" rather than "loading".
    public private(set) var eventsLoaded = false
    /// The mode last chosen for each runtime, as the Mac holds it (029). A copy, kept
    /// current by `modes/changed`, so a start form can open on it without a round trip.
    public private(set) var rememberedModes: DaemonAPI.RememberedModes = [:]
    /// Why the Mac is, or is not, being kept awake (024).
    ///
    /// Nil means *not yet heard from*, which is a different fact from *not holding* and
    /// is drawn the same way — as nothing. It stays nil against a daemon too old to
    /// know `wake/state`, which is what lets a new window work against an old daemon.
    public private(set) var wakeState: DaemonAPI.WakeState?
    /// Files the host could not read in this run (#205); empty when all read.
    public private(set) var storeNotes: [String] = []

    /// What each command an agent ran has printed, as far as this client heard it (033).
    ///
    /// Here rather than in the Mac's own model so a phone shows the same output in a
    /// call's detail. Only what arrived while this client was listening: the output is
    /// streamed, not kept in the transcript.
    ///
    /// Bounded as a whole as well as per terminal. Every agent's output reaches every
    /// window, so a window left open for days heard every command every agent ran, and
    /// until 2026-09-25 kept all of it. The terminals written to least recently go
    /// first, the agent on screen's last.
    public private(set) var terminalOutput: [String: String] = [:]
    public static let terminalOutputLimit = 200_000
    /// Bytes of output kept across all terminals, and how many terminals.
    public static let terminalOutputBudget = 4_000_000
    public static let terminalsKept = 256
    /// Whose each kept terminal is, and the order they were last written to, oldest first.
    @ObservationIgnored private var terminalAgents: [String: UUID] = [:]
    @ObservationIgnored private var terminalsByWrite: [String] = []
    @ObservationIgnored private var terminalOutputBytes = 0

    /// A choice made on a control that the daemon has not yet confirmed (033).
    ///
    /// The sequence is which write this was. A call that completes clears the entry
    /// only if it is still the one it wrote, so two taps in a row settle on the later
    /// choice whatever order the answers come back in.
    public struct PendingOption: Equatable, Sendable {
        public var value: JSONValue
        public var sequence: Int
    }

    /// Held only while the change is in flight, and never written into
    /// `agent.startOptions`: that is the daemon's record mirrored here, and a client
    /// that edits it is a client that can disagree with the daemon with no way to
    /// notice.
    public private(set) var pendingOptions: [UUID: [String: PendingOption]] = [:]
    @ObservationIgnored private var pendingOptionSequence = 0

    /// What each agent has been asked to do and has not yet answered (#87): the control
    /// that sent it shows it is on its way, and every control that would send another is
    /// held. Kept here, not in a view, so the menu, the row, the swipe and the strip all
    /// hold together, and both apps the same way.
    public private(set) var acting: [UUID: AgentAct] = [:]

    public init() {}

    // MARK: What each notification means

    /// One notification from the daemon, read.
    ///
    /// Reading is the expensive half of applying one — a tool call's output can be
    /// a hundred kilobytes of JSON — and it needs nothing of the model, so a client
    /// may read off the main actor and hand over the result. What each one *means*
    /// is still written once, in `apply`.
    public enum Update: Sendable {
        case agentChanged(Agent)
        case projectChanged(DaemonAPI.ProjectSummary)
        case entry(DaemonAPI.EntryNotification)
        case permission(DaemonAPI.PermissionNotification)
        case elicitation(DaemonAPI.ElicitationNotification)
        case attention(DaemonAPI.AttentionNotification)
        case usage(DaemonAPI.UsageNotification)
        case workflowChanged(WorkflowSummary)
        case workflowRemoved(DaemonAPI.WorkflowRemovedNotification)
        case dashboardChanged(DaemonAPI.DashboardChangedNotification)
        case pinsChanged(DaemonAPI.PinsChangedNotification)
        case pagesChanged(DaemonAPI.PagesChangedNotification)
        case pluginsChanged(DaemonAPI.PluginsList)
        case costChanged(DaemonAPI.CostState)
        case retentionChanged(DaemonAPI.RetentionState)
        case runtimeAllowancesChanged(RuntimeAllowances)
        case agentRemoved(DaemonAPI.AgentRemovedNotification)
        case leasesChanged(DaemonAPI.LeaseSnapshot)
        case diskChanged(DiskState)
        case eventsChanged(DaemonAPI.EventsChange)
        case modesChanged(DaemonAPI.RememberedModes)
        case wakeChanged(DaemonAPI.WakeState)
        case storeNotesChanged(DaemonAPI.StoreNotes)
        case showFile(DaemonAPI.ShowFileNotification)
        case resuming(DaemonAPI.ResumingNotification)
        case terminalOutput(DaemonAPI.TerminalOutputNotification)
        /// Ours, and unreadable. Claimed, so nobody else guesses at it, and skipped.
        case unreadable
    }

    /// Read a notification, anywhere. Nil for anything this model does not know, so
    /// a client with notifications of its own — the Mac has shells and terminals —
    /// can go on and handle them.
    public nonisolated static func read(_ method: String, _ params: JSONValue?) -> Update? {
        func decode<T: Decodable>(_ type: T.Type, _ wrap: (T) -> Update) -> Update {
            (try? params?.decode(type)).map(wrap) ?? .unreadable
        }
        switch method {
        case DaemonAPI.Notification.agentChanged: return decode(Agent.self, Update.agentChanged)
        case DaemonAPI.Notification.projectChanged: return decode(DaemonAPI.ProjectSummary.self, Update.projectChanged)
        case DaemonAPI.Notification.agentEntry: return decode(DaemonAPI.EntryNotification.self, Update.entry)
        case DaemonAPI.Notification.agentPermission: return decode(DaemonAPI.PermissionNotification.self, Update.permission)
        case DaemonAPI.Notification.agentElicitation: return decode(DaemonAPI.ElicitationNotification.self, Update.elicitation)
        case DaemonAPI.Notification.attentionChanged: return decode(DaemonAPI.AttentionNotification.self, Update.attention)
        case DaemonAPI.Notification.agentUsage: return decode(DaemonAPI.UsageNotification.self, Update.usage)
        case DaemonAPI.Notification.workflowChanged: return decode(WorkflowSummary.self, Update.workflowChanged)
        case DaemonAPI.Notification.workflowRemoved: return decode(DaemonAPI.WorkflowRemovedNotification.self, Update.workflowRemoved)
        case DaemonAPI.Notification.dashboardChanged:
            return decode(DaemonAPI.DashboardChangedNotification.self, Update.dashboardChanged)
        case DaemonAPI.Notification.pinsChanged: return decode(DaemonAPI.PinsChangedNotification.self, Update.pinsChanged)
        case DaemonAPI.Notification.pagesChanged: return decode(DaemonAPI.PagesChangedNotification.self, Update.pagesChanged)
        case DaemonAPI.Notification.pluginsChanged: return decode(DaemonAPI.PluginsList.self, Update.pluginsChanged)
        case DaemonAPI.Notification.costChanged: return decode(DaemonAPI.CostState.self, Update.costChanged)
        case DaemonAPI.Notification.retentionChanged: return decode(DaemonAPI.RetentionState.self, Update.retentionChanged)
        case DaemonAPI.Notification.runtimesAllowancesChanged:
            return decode(RuntimeAllowances.self, Update.runtimeAllowancesChanged)
        case DaemonAPI.Notification.agentRemoved: return decode(DaemonAPI.AgentRemovedNotification.self, Update.agentRemoved)
        case DaemonAPI.Notification.leasesChanged: return decode(DaemonAPI.LeaseSnapshot.self, Update.leasesChanged)
        case DaemonAPI.Notification.diskChanged: return decode(DiskState.self, Update.diskChanged)
        case DaemonAPI.Notification.eventsChanged: return decode(DaemonAPI.EventsChange.self, Update.eventsChanged)
        case DaemonAPI.Notification.modesChanged: return decode(DaemonAPI.RememberedModes.self, Update.modesChanged)
        case DaemonAPI.Notification.wakeChanged: return decode(DaemonAPI.WakeState.self, Update.wakeChanged)
        case DaemonAPI.Notification.storeNotesChanged: return decode(DaemonAPI.StoreNotes.self, Update.storeNotesChanged)
        case DaemonAPI.Notification.agentShowFile: return decode(DaemonAPI.ShowFileNotification.self, Update.showFile)
        case DaemonAPI.Notification.agentResuming: return decode(DaemonAPI.ResumingNotification.self, Update.resuming)
        case DaemonAPI.Notification.agentTerminalOutput: return decode(DaemonAPI.TerminalOutputNotification.self, Update.terminalOutput)
        default: return nil
        }
    }

    /// Apply one notification from the daemon.
    ///
    /// Returns false for anything this does not know, so a client with notifications
    /// of its own — the Mac has shells and terminals — can go on and handle them. A
    /// notification nobody claims is skipped, never guessed at.
    @discardableResult
    public func apply(_ method: String, _ params: JSONValue?) -> Bool {
        guard let update = Self.read(method, params) else { return false }
        apply(update)
        return true
    }

    /// Apply one notification from one of several daemons (037). What it carries is
    /// stamped with the host it came from before it is filed, so a window holding a
    /// server's projects beside the Mac's never mistakes one for the other.
    @discardableResult
    public func apply(_ method: String, _ params: JSONValue?, from host: HostID) -> Bool {
        guard let update = Self.read(method, params) else { return false }
        apply(Self.stamp(update, host: host))
        return true
    }

    nonisolated static func stamp(_ update: Update, host: HostID) -> Update {
        switch update {
        case .agentChanged(var agent):
            agent.host = host
            return .agentChanged(agent)
        case .projectChanged(var summary):
            summary.host = host
            return .projectChanged(summary)
        default:
            return update
        }
    }

    /// Apply one notification already read. See `read`.
    public func apply(_ update: Update) {
        switch update {
        case .agentChanged(let agent):
            upsert(agent)

        case .projectChanged(let summary):
            upsert(summary)

        case .entry(let notification):
            guard notification.agentID == watching else { return }
            heardSincePage.append(notification.entry)
            if heardSincePage.count > Self.heardSincePageLimit {
                heardSincePage.removeFirst(heardSincePage.count - Self.heardSincePageLimit)
            }
            // Already on the page: written before the daemon read it, and heard after.
            guard entryIDs.insert(notification.entry.id).inserted else { return }
            entries.append(notification.entry)
            display.add(notification.entry)
            if isFollowingEnd, entries.count > nextTrimAt {
                trimFront()
            } else {
                transcriptItems = display.items
            }

        case .permission(let notification):
            if let id = notification.requestID ?? notification.request?.id {
                permissions.removeAll { $0.agentID == notification.agentID && $0.id == id }
            } else {
                // Every question at once: a daemon from before 09-27 withdraws this way
                // (kept, #58; see `PermissionNotification.requestID`).
                permissions.removeAll { $0.agentID == notification.agentID }
            }
            if let request = notification.request { permissions.append(request) }
            permissions.sort { $0.askedAt < $1.askedAt }

        case .elicitation(let notification):
            elicitations.removeAll { $0.id == notification.requestID }
            if let request = notification.request { elicitations.append(request) }

        case .attention(let notification):
            if let need = notification.need {
                needs[notification.needID] = need
                deliveries[notification.needID] = notification.to
            } else {
                needs.removeValue(forKey: notification.needID)
                deliveries.removeValue(forKey: notification.needID)
            }

        case .usage(let notification):
            if var agent = byID[notification.agentID] {
                agent.usage = notification.usage
                file(agent)
            }

        case .workflowChanged(let summary):
            upsert(summary)

        case .workflowRemoved(let notification):
            let folder = Project.standardize(notification.folder)
            workflows.removeAll {
                $0.folder == folder && $0.workflowID == notification.workflowID
            }

        case .dashboardChanged(let notification):
            let folder = Project.standardize(notification.folder)
            dashboardSummaries[folder] = notification.summary
            dashboardRevisions[folder, default: 0] += 1

        case .pinsChanged(let notification):
            let folder = Project.standardize(notification.folder)
            pins[folder] = notification.pins.isEmpty ? nil : notification.pins
            let sessions = notification.sessions ?? []
            if sessionPins[folder] != (sessions.isEmpty ? nil : sessions) {
                sessionPins[folder] = sessions.isEmpty ? nil : sessions
            }

        case .pagesChanged(let notification):
            pageRevisions[Project.standardize(notification.folder), default: 0] += 1

        case .pluginsChanged(let list):
            replacePlugins(list)

        case .costChanged(let state):
            costState = state

        case .retentionChanged(let state):
            retentionState = state

        case .runtimeAllowancesChanged(let allowances):
            runtimeAllowances = allowances

        case .agentRemoved(let notification):
            // Retired (051). Out of every list; a chat that was showing it finds no
            // agent and shows what is left of it instead.
            unfile(notification.agentID)
            permissions.removeAll { $0.agentID == notification.agentID }
            elicitations.removeAll { $0.agentID == notification.agentID }

        case .leasesChanged(let snapshot):
            leases = snapshot

        case .diskChanged(let state):
            disk = state

        case .eventsChanged(let change):
            waitingAgents = change.waiting
            if let event = change.event { takeEvent(event) }

        case .modesChanged(let modes):
            rememberedModes = modes

        case .wakeChanged(let state):
            wakeState = state

        case .storeNotesChanged(let notes):
            storeNotes = notes.notes

        case .showFile(let notification):
            filesToShow[notification.agentID] = notification.file
            // Its group can move with it: a file to look at is wanting eyes.
            if let agent = byID[notification.agentID] { file(agent) }

        case .resuming(let notification):
            if notification.isResuming {
                resuming.insert(notification.agentID)
            } else {
                resuming.remove(notification.agentID)
            }

        case .terminalOutput(let notification):
            let id = notification.terminalID
            let before = terminalOutput[id]?.utf8.count ?? 0
            var text = terminalOutput[id, default: ""] + notification.chunk
            // The tail, because a build that prints for ten minutes is read from the end.
            // Bytes first: they are counted already, and characters are counted by walking.
            if text.utf8.count > Self.terminalOutputLimit, text.count > Self.terminalOutputLimit {
                text = String(text.suffix(Self.terminalOutputLimit))
            }
            terminalOutput[id] = text
            terminalOutputBytes += text.utf8.count - before
            terminalAgents[id] = notification.agentID
            if let at = terminalsByWrite.lastIndex(of: id) { terminalsByWrite.remove(at: at) }
            terminalsByWrite.append(id)
            dropOldTerminalOutput()

        case .unreadable:
            break
        }
    }

    // MARK: Filing what arrives

    /// One agent, new or changed, moved to where it now goes: in `agents`, in its
    /// project's shelf, in its own cell. Nothing else is filed again (#165).
    public func upsert(_ agent: Agent) {
        file(agent)
    }

    public func upsert(_ summary: WorkflowSummary) {
        if let index = workflows.firstIndex(where: { $0.id == summary.id }) {
            workflows[index] = summary
        } else {
            workflows.append(summary)
        }
        workflows.sort {
            $0.workflow.name.localizedCaseInsensitiveCompare($1.workflow.name) == .orderedAscending
        }
    }

    public func replaceWorkflows(_ summaries: [WorkflowSummary]) {
        workflows = summaries.sorted {
            $0.workflow.name.localizedCaseInsensitiveCompare($1.workflow.name) == .orderedAscending
        }
    }

    public func replacePlugins(_ list: DaemonAPI.PluginsList) {
        plugins[Project.standardize(list.folder)] = list.plugins.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The plugins of one project, which is what a project page shows.
    public func plugins(in folder: URL?) -> [ProjectPlugin] {
        guard let folder else { return [] }
        return plugins[Project.standardize(folder)] ?? []
    }

    /// One project's Dashboard row, or nil when it has no tiles.
    public func dashboardSummary(in folder: URL?) -> DashboardSummary? {
        guard let folder else { return nil }
        return dashboardSummaries[Project.standardize(folder)]
    }

    public func replaceDashboardSummaries(_ listed: [DashboardSummary]) {
        dashboardSummaries = Dictionary(listed.map { (Project.standardize($0.folder), $0) }, uniquingKeysWith: { $1 })
    }

    /// A Dashboard as fetched; its row follows it.
    public func store(_ snapshot: DashboardSnapshot) {
        let folder = Project.standardize(snapshot.folder)
        dashboards[folder] = snapshot
        dashboardSummaries[folder] = DashboardModel.summary(snapshot)
    }

    /// One project's pinned pages, in their order.
    public func pins(in folder: URL?) -> [PinView] {
        folder.map { pins[Project.standardize($0)] ?? [] } ?? []
    }

    public func replacePins(_ listed: [ProjectPins]) {
        pins = Dictionary(listed.compactMap { $0.pins.isEmpty ? nil : (Project.standardize($0.folder), $0.pins) },
                          uniquingKeysWith: { $1 })
        let sessions = Dictionary(listed.compactMap { listed in
            listed.sessions.map { (Project.standardize(listed.folder), $0) }
        }, uniquingKeysWith: { $1 })
        if sessionPins != sessions { sessionPins = sessions }
    }

    /// One project's pinned sessions (#180), in their order: ids, whether or not this
    /// client holds them.
    public func pinnedSessions(in folder: URL?) -> [UUID] {
        folder.map { sessionPins[Project.standardize($0)] ?? [] } ?? []
    }

    /// A project's pinned sessions as a screen left them, before the host says so.
    public func setSessionPins(_ ids: [UUID], in folder: URL) {
        sessionPins[Project.standardize(folder)] = ids.isEmpty ? nil : ids
    }

    /// A project's pins as a screen left them, before the host says so: a drop, an Unpin.
    public func setPins(_ list: [PinView], in folder: URL) {
        pins[Project.standardize(folder)] = list.isEmpty ? nil : list
    }

    public func pageRevision(in folder: URL?) -> Int {
        folder.map { pageRevisions[Project.standardize($0)] ?? 0 } ?? 0
    }

    public func dashboardRevision(in folder: URL?) -> Int {
        folder.map { dashboardRevisions[Project.standardize($0)] ?? 0 } ?? 0
    }

    /// The workflows of one project, which is what a project page shows.
    public func workflows(in folder: URL?) -> [WorkflowSummary] {
        guard let folder else { return [] }
        let standardized = Project.standardize(folder)
        return workflows.filter { $0.folder == standardized }
    }

    public func upsert(_ summary: DaemonAPI.ProjectSummary) {
        if let index = projects.firstIndex(where: { $0.folder == summary.folder && $0.host == summary.host }) {
            projects[index] = summary
        } else {
            projects.append(summary)
        }
        projects.sort { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func replaceAgents(_ listed: [Agent]) {
        refile(listed.map { $0.keepingLists(of: byID[$0.id]) })
    }

    /// Agents from a list that is not all of them (a project's archived ones, a workflow's
    /// runs, the open chat's record), filed beside the rest. A lean one keeps the lists
    /// held for it (#107); `agent/changed` is always whole and goes through `upsert`.
    ///
    /// Merged in one go and sorted once, as `replaceAgents` does: filed one at a time it
    /// was a search and a sort of everything held for each one listed (#136).
    public func takeListed(_ listed: [Agent]) {
        guard !listed.isEmpty else { return }
        // A few, one at a time; many, filed again in one go.
        if listed.count <= 8 {
            for agent in listed { file(agent.keepingLists(of: byID[agent.id])) }
            return
        }
        var merged = byID
        for agent in listed { merged[agent.id] = agent.keepingLists(of: merged[agent.id]) }
        refile(Array(merged.values))
    }

    public func replaceProjects(_ listed: [DaemonAPI.ProjectSummary]) {
        projects = listed.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// One host's agents, as it just listed them. Every other host's are left alone:
    /// a server re-listing after a reconnect must not take the Mac's away (037).
    public func replaceAgents(_ listed: [Agent], from host: HostID) {
        // A lean list (#107) keeps the lists already held for an agent: the open chat's menus.
        let held = byID.filter { $0.value.host == host }
        let stamped = listed.map { var agent = $0.keepingLists(of: held[$0.id]); agent.host = host; return agent }
        refile(byID.values.filter { $0.host != host } + stamped)
    }

    public func replaceProjects(_ listed: [DaemonAPI.ProjectSummary], from host: HostID) {
        let stamped = listed.map { var summary = $0; summary.host = host; return summary }
        projects = (projects.filter { $0.host != host } + stamped).sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Down to the budget, never taking the terminal just written to.
    private func dropOldTerminalOutput() {
        while terminalsByWrite.count > 1,
              terminalOutputBytes > Self.terminalOutputBudget || terminalsByWrite.count > Self.terminalsKept {
            let older = terminalsByWrite.dropLast()
            let at = older.firstIndex { terminalAgents[$0] != watching } ?? older.startIndex
            let id = terminalsByWrite.remove(at: at)
            terminalOutputBytes -= terminalOutput.removeValue(forKey: id)?.utf8.count ?? 0
            terminalAgents[id] = nil
        }
    }

    public func replaceCostState(_ state: DaemonAPI.CostState) { costState = state }
    public func replaceRetentionState(_ state: DaemonAPI.RetentionState) { retentionState = state }
    public func replaceRuntimeAllowances(_ allowances: RuntimeAllowances) { runtimeAllowances = allowances }
    /// Tombstones as `agents/retired` answered, kept for the retired page (051).
    public func takeTombstones(_ found: [Tombstone]) {
        for tombstone in found { tombstones[tombstone.id] = tombstone }
    }
    public func replaceLeases(_ snapshot: DaemonAPI.LeaseSnapshot) { leases = snapshot }
    public func replaceDisk(_ state: DiskState) { disk = state }

    /// A page of events from `events/list`, asked for with `filter`. The first page
    /// replaces what was there; a page from further back (`appending`) goes on the end.
    /// A page for a filter other than the current one is too late, and dropped.
    public func takeEvents(_ page: DaemonAPI.EventsPage, for filter: EventFilter = EventFilter(),
                           appending: Bool = false) {
        guard filter == eventsFilter else { return }
        noteEventAt(page.events.first?.latest)
        if appending {
            let known = Set(recentEvents.map(\.position))
            recentEvents += page.events.filter { !known.contains($0.position) }
        } else {
            recentEvents = page.events
        }
        moreEvents = page.hasMore
        waitingAgents = page.waiting
        eventsLoaded = true
    }

    /// `recentEvents` narrowed to `filter` and cut into days, as an Events page draws
    /// them. Worked out again only when the events, the filter or the calendar change,
    /// not on every redraw of the page (#137). Reads `recentEvents` either way, so a page
    /// asking is redrawn when they change.
    public func shownEvents(_ filter: EventFilter, calendar: Calendar = .current) -> ShownEvents {
        let events = recentEvents
        if let memo = shownMemo, memo.revision == eventsRevision, memo.filter == filter, memo.calendar == calendar {
            return memo.shown
        }
        let shown = ShownEvents(events.filter(filter.matches), calendar: calendar)
        shownMemo = (eventsRevision, filter, calendar, shown)
        return shown
    }

    /// One event, new or changed, put in by its position so the list stays newest first.
    func takeEvent(_ event: Event) {
        noteEventAt(event.latest)
        guard eventsFilter.matches(event) else { return }
        if let index = recentEvents.firstIndex(where: { $0.position == event.position }) {
            recentEvents[index] = event
        } else if let index = recentEvents.firstIndex(where: { $0.position < event.position }) {
            recentEvents.insert(event, at: index)
        } else if !moreEvents || recentEvents.isEmpty {
            recentEvents.append(event)
        }
        if recentEvents.count > Self.eventsKept {
            recentEvents.removeLast(recentEvents.count - Self.eventsKept)
            // What went is still the daemon's, and paging back brings it in.
            moreEvents = true
        }
    }

    private func noteEventAt(_ date: Date?) {
        guard let date else { return }
        if lastEventAt.map({ date > $0 }) ?? true { lastEventAt = date }
    }

    /// How many live events a window keeps before the oldest go; paging back brings them in.
    static let eventsKept = 1_000

    /// What an agent is waiting on, in the words its row, card and capsule use.
    public func waitStatus(of agent: Agent) -> WaitStatus? {
        WaitStatus.of(agent, names: { self.agentTitles[$0] })
    }

    /// What an agent holds and waits for, in the words the row, the card and the chat
    /// use. Nil when it is nothing, or the daemon has no leases to say.
    public func leaseStatus(of agentID: UUID) -> LeaseStatus? {
        guard let leases else { return nil }
        return LeaseStatus.of(agentID, in: leases, titles: agentTitles)
    }

    /// Every agent's title by id, for naming whoever holds what another is waiting for.
    /// Kept as titles change, and read through a count that moves only when one does, so
    /// every row asking is not redrawn by every change (#165).
    public var agentTitles: [UUID: String] {
        _ = titlesRevision
        return titles
    }
    public func replaceRememberedModes(_ modes: DaemonAPI.RememberedModes) { rememberedModes = modes }

    /// The mode last chosen for this runtime, on any device (029).
    public func rememberedMode(for runtimeID: String) -> JSONValue? { rememberedModes[runtimeID] }
    public func replaceWakeState(_ state: DaemonAPI.WakeState) { wakeState = state }
    public func replaceStoreNotes(_ notes: DaemonAPI.StoreNotes) { storeNotes = notes.notes }

    // MARK: Choices in flight

    /// What an option control should read: the choice just made, else what is in
    /// force, else what the runtime says is current.
    public func chosenOption(_ optionID: String, for agent: Agent, advertised: ConfigOption) -> JSONValue? {
        pendingOptions[agent.id]?[optionID]?.value
            ?? agent.startOptions.values[optionID]
            ?? advertised.currentValue
    }

    /// Show a choice at once, before the daemon has it. Returns which write this was,
    /// for `settleOption` when the call comes back.
    ///
    /// The control used to read `agent.startOptions` while the change went only to a
    /// `Task`, so the menu closed over the old value and stayed there for the whole
    /// round trip. The optimistic value closes that gap.
    public func beginOption(agentID: UUID, optionID: String, value: JSONValue) -> Int {
        pendingOptionSequence += 1
        pendingOptions[agentID, default: [:]][optionID] = PendingOption(value: value, sequence: pendingOptionSequence)
        return pendingOptionSequence
    }

    /// The call for one write came back, whether it succeeded or was refused: the
    /// record is what is in force, and a refusal must settle the control on that rather
    /// than on what was asked for. Only if this write is still the last word — a slower
    /// earlier call finishing must not drop a later choice.
    public func settleOption(agentID: UUID, optionID: String, sequence: Int) {
        guard pendingOptions[agentID]?[optionID]?.sequence == sequence else { return }
        pendingOptions[agentID]?[optionID] = nil
        if pendingOptions[agentID]?.isEmpty == true { pendingOptions[agentID] = nil }
    }

    // MARK: Actions in flight (#87)

    /// Begin one, unless another is already on its way to this agent. False means the
    /// press is the second of a pair, or a different button pressed while the first is
    /// still going, and is not to be sent: whichever surface it came from (menu, row,
    /// swipe, strip, key), it is one agent and one answer at a time.
    public func begin(_ act: AgentAct, on agentID: UUID) -> Bool {
        guard acting[agentID] == nil else { return false }
        acting[agentID] = act
        return true
    }

    /// The call came back, sent or not. The record arriving says what became of it.
    public func end(_ act: AgentAct, on agentID: UUID) {
        if acting[agentID] == act { acting[agentID] = nil }
    }

    /// What this agent has left before it stops, under the limits as they stand.
    /// Nil when uncapped, when unmeasured, or before the daemon has said.
    public func costHeadroom(for agent: Agent) -> Decimal? {
        guard let limits = costState?.limits else { return nil }
        return agent.costHeadroom(under: limits)
    }

    public func isAtCostLimit(_ agent: Agent) -> Bool {
        guard let limits = costState?.limits else { return false }
        return agent.isAtCostLimit(under: limits)
    }

    public func replacePermissions(_ listed: [PermissionRequest]) { permissions = listed }

    public func replaceElicitations(_ listed: [ElicitationRequest]) { elicitations = listed }

    /// What `attention/pending` said on connect: the outstanding needs and where each
    /// is showing, replacing whatever this surface believed while it was not listening.
    public func replaceAttention(_ pending: DaemonAPI.AttentionPending) {
        needs = Dictionary(uniqueKeysWithValues: pending.needs.map { ($0.id, $0) })
        deliveries = Dictionary(uniqueKeysWithValues: pending.deliveries.map { ($0.needID, $0.to) })
            .compactMapValues { $0 }
    }

    /// The finished turns at the end of the conversation, and where the one in progress
    /// starts. Asked for before the transcript, which then starts there.
    public func replaceTurns(with page: TurnsPage) {
        turns = page.turns
        firstTurn = page.firstTurn
        openTurnStart = page.openStart
    }

    /// Earlier finished turns, put in front.
    public func prependTurns(_ page: TurnsPage) {
        let held = Set(turns.map(\.id))
        turns = page.turns.filter { !held.contains($0.id) } + turns
        firstTurn = page.firstTurn
    }

    /// The first page of the conversation being read: the end of it.
    public func replaceTranscript(with page: TranscriptPage) {
        // What was heard and is not on the page was written after the page was read, so
        // it goes after it, in the order it was heard.
        let onPage = Set(page.entries.map(\.id))
        entries = page.entries + heardSincePage.filter { !onPage.contains($0.id) }
        heardSincePage = []
        firstEntryIndex = page.firstIndex
        hasMoreBefore = page.firstIndex > openTurnStart
        refold()
    }

    /// An earlier page, put in front of what is already held.
    public func prepend(_ page: TranscriptPage) {
        // Only what is not already held. Where a trimmed page starts is counted, not
        // read off the file, and an entry that was heard but never written would put
        // the count past it: the page asked for then ends with entries already here.
        entries.insert(contentsOf: page.entries.filter { !entryIDs.contains($0.id) }, at: 0)
        firstEntryIndex = page.firstIndex
        hasMoreBefore = page.firstIndex > openTurnStart
        refold()
    }

    public func clearTranscript() {
        entries = []
        heardSincePage = []
        firstEntryIndex = 0
        hasMoreBefore = false
        turns = []
        firstTurn = 0
        openTurnStart = 0
        refold()
    }

    /// The page folded again from the top: a page replaced or grown at the front is
    /// not a page grown at the end, and only the latter can be folded a step at a time.
    private func refold() {
        entryIDs = Set(entries.map(\.id))
        display = TranscriptDisplayBuilder()
        for entry in entries { display.add(entry) }
        transcriptItems = display.items
        nextTrimAt = Self.entriesTrimmedAt
    }

    /// The oldest entries let go, down to `entriesKept`, while the chat follows the end.
    ///
    /// Cut where a row begins, so every row left is the row it was — the same id, the
    /// same fold, a run still open or not as before — and the pane has nothing to
    /// redraw but the rows that went, far above it. What went is only marked as being
    /// there: `hasMoreBefore`, and `firstEntryIndex` moved on past it, so reaching the
    /// top pages it back in from the daemon the way any earlier page comes.
    private func trimFront() {
        let items = display.items
        var position: [UUID: Int] = [:]
        for (index, entry) in entries.enumerated() where position[entry.id] == nil {
            position[entry.id] = index
        }
        let starts = items.compactMap { position[$0.id] }
        let latest = starts.count > Self.itemsKept ? starts[starts.count - Self.itemsKept] : 0
        let wanted = starts.first { $0 >= entries.count - Self.entriesKept } ?? latest
        let cut = min(wanted, latest)
        guard cut > 0 else {
            transcriptItems = items
            nextTrimAt = entries.count + Self.entriesTrimmedAt - Self.entriesKept
            return
        }
        let dropped = Array(entries[..<cut])
        entries.removeFirst(cut)
        firstEntryIndex += cut
        hasMoreBefore = true
        refold()
        nextTrimAt = max(Self.entriesTrimmedAt, entries.count + Self.entriesTrimmedAt - Self.entriesKept)
        onTrimmed(dropped)
    }

    /// Taken out once it has been acted on. This is "look at this now", and a client
    /// opened tomorrow has missed it.
    public func takeFileToShow(for agentID: UUID) -> ShownFile? {
        let taken = filesToShow.removeValue(forKey: agentID)
        if taken != nil, let agent = byID[agentID] { file(agent) }
        return taken
    }

    /// Everything the daemon said was on its way back when we connected. A window
    /// that arrives mid-batch is told the set rather than piecing it together from
    /// notifications it was not there to hear.
    public func setResuming(_ ids: [UUID]) {
        resuming = Set(ids)
    }

    /// Whether the daemon is bringing this chat back by itself.
    public func isComingBack(_ agent: Agent) -> Bool {
        resuming.contains(agent.id)
    }

    /// Who started an agent another agent started, as its mark says it (028): that
    /// agent's title as it is now, or "another agent" once it has none or has gone.
    /// `nil` for every agent the person or a workflow started. Here rather than in a
    /// view so the Mac's row and the phone's card cannot word it differently.
    public func startedByAgentLabel(_ agent: Agent) -> String? {
        guard let starter = agent.startedByAgent else { return nil }
        // A starter that has been retired is named from what is left of it (051).
        let retired = self.agent(starter) == nil ? tombstones[starter] : nil
        let title = (self.agent(starter)?.title ?? retired?.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.flatMap { $0.isEmpty ? nil : "\u{201C}\($0)\u{201D}" } ?? "another agent"
        return "Started by " + name + (retired != nil ? " (retired)" : "")
    }

    /// The symbol that mark is drawn with.
    public static let startedByAgentSymbol = "person.2"

    /// Who is asking, at the head of a question or permission card (#121): the agent's
    /// title and runtime, and for a helper who started it. A card read beside others,
    /// on a phone, then has a named asker even when the question says "I" and "you".
    /// `nil` when the agent is not known here.
    public func askerLine(_ agentID: UUID, subagent: String? = nil) -> String? {
        guard let agent = agent(agentID) else { return nil }
        let starter = startedByAgentLabel(agent).map { "s" + $0.dropFirst() }
        return Self.askerLine(title: agent.title,
                              runtime: RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID,
                              startedBy: starter, subagent: subagent)
    }

    /// The words, apart from looking anything up: "Asked by “#116 helper” (Claude),
    /// started by “Project lead”". An untitled agent is named by its runtime alone.
    public static func askerLine(title: String?, runtime: String, startedBy: String? = nil,
                                 subagent: String? = nil) -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var asker = title.flatMap { $0.isEmpty ? nil : "\u{201C}\($0)\u{201D} (\(runtime))" } ?? runtime
        // Its subagent asking, not the agent itself (057).
        if let subagent { asker = "subagent \u{201C}\(subagent)\u{201D} of " + asker }
        return "Asked by " + asker + (startedBy.map { ", " + $0 } ?? "")
    }

    // MARK: Blocked (039)

    /// The block this agent is sitting in, if it is: a settled agent whose last report
    /// was `blocked` and has not cleared. Nil for a running agent even when its report
    /// still says blocked — that is the resumed turn, and it is working.
    public func openBlock(_ agent: Agent) -> (report: WorkReport, block: Block)? {
        guard agent.state == .finished, let report = agent.report, report.isOpenBlock
        else { return nil }
        return (report, report.block ?? Block())
    }

    /// What an agent that is waited on is called now: its current title, or the one it
    /// had when the block was made once it has none or has gone (FR-010).
    public func waitName(_ wait: Wait) -> String {
        let title = agent(wait.agentID)?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.flatMap { $0.isEmpty ? nil : $0 } ?? wait.nameAtReport
    }

    /// The lines under a blocked agent's message: whether it waits on any or all of
    /// several (#152), one per agent it waits on, and when it will check again. The same on the Mac's row and the phone's card (FR-011).
    public func blockLines(_ agent: Agent) -> [String] {
        guard let (_, block) = openBlock(agent) else { return [] }
        return [block.wakeLine()].compactMap { $0 }
            + block.waits.map { Block.waitLine(name: waitName($0), ending: $0.ending) }
            + [block.checkAgainLine()].compactMap { $0 }
    }

    /// The name of the button that ends a block by hand.
    public static let carryOnLabel = "Carry on"

    /// Help for Carry on: Waiting (the app would resume itself) vs Blocked (only the person).
    public static func carryOnHelp(for agent: Agent) -> String {
        agent.isWaiting
            ? "Stop waiting and carry on now"
            : "Tell it the block has cleared, and let it carry on"
    }

    /// Whether a client should offer Stop for this chat: the daemon holds a runtime for
    /// it, or is about to pick it back up. The window's toolbar, the card's menu and
    /// the phone's menu all ask this, so no two of them can disagree about it.
    public func canStop(_ agent: Agent) -> Bool {
        // A blocked chat too (039): it holds nothing, but a resume is coming, and Stop
        // is how the person calls it off.
        agent.state.holdsRuntime || isComingBack(agent) || openBlock(agent) != nil
    }

    /// The one thing every client says about a chat on its way back, so the window
    /// and the phone cannot drift apart saying it.
    public nonisolated static let comingBackDescription = "Coming back after a restart"
    public static let comingBackSymbol = "arrow.clockwise.circle"

    // MARK: Reading it back

    /// One agent by id, read through its own cell: a view asking is redrawn when this
    /// agent changes and no other (#165).
    public func agent(_ id: UUID?) -> Agent? {
        guard let id else { return nil }
        if let cell = cells[id] { return cell.agent }
        let cell = AgentCell(byID[id])
        cells[id] = cell
        return cell.agent
    }

    /// Which runtime a new agent gets when nobody has said.
    ///
    /// Whatever the last agent used, when it is still available, because that is the
    /// one already chosen in every other sense. Here rather than in either app so that
    /// the Mac and a phone cannot offer different ones for the same work (029).
    ///
    /// - Parameter available: the runtimes that can be started now, in the Mac's order.
    ///   With no agent to go by it is the catalog's default when that can start, and
    ///   otherwise the first of these — by order, not whichever a set happened to hand
    ///   back. The order is alphabetical (#154), so it is not what picks the default.
    public func defaultRuntimeID(available: [String]) -> String? {
        let startable = Set(available)
        let recent = agents.filter { startable.contains($0.runtimeID) }
            .max { $0.lastActivityAt < $1.lastActivityAt }
        if let recent { return recent.runtimeID }
        if startable.contains(RuntimeCatalog.defaultRuntime.id) { return RuntimeCatalog.defaultRuntime.id }
        return available.first
    }

    /// The projects worth showing, newest activity first.
    public var liveProjects: [DaemonAPI.ProjectSummary] {
        projects.filter { !$0.project.isArchived }
    }

    public var archivedProjects: [DaemonAPI.ProjectSummary] {
        projects.filter(\.project.isArchived)
    }

    public func project(_ key: ProjectKey?) -> DaemonAPI.ProjectSummary? {
        guard let key else { return nil }
        return projects.first { $0.host == key.host && $0.folder == key.folder }
    }

    /// A project's shelf on one host: its agents by group, and its numbers (#165). A fold
    /// that reads it is redrawn by its own project's changes only.
    public func shelf(_ key: ProjectKey?) -> ProjectShelf {
        guard let key else { return ProjectShelf() }
        let wanted = ShelfKey(folder: Project.standardize(key.folder), host: key.host)
        if let shelf = shelves[wanted] { return shelf }
        let shelf = ProjectShelf()
        shelves[wanted] = shelf
        return shelf
    }

    /// The same by folder alone, whichever host it is on: what the phone asks.
    public func shelf(_ folder: URL?) -> ProjectShelf {
        guard let folder else { return ProjectShelf() }
        let wanted = Project.standardize(folder)
        if let shelf = folderShelves[wanted] { return shelf }
        let shelf = ProjectShelf()
        folderShelves[wanted] = shelf
        return shelf
    }

    public func agents(in key: ProjectKey?, group: AgentGroup) -> [Agent] {
        guard key != nil else { return [] }
        return shelf(key).groups[group] ?? []
    }

    public func counts(in key: ProjectKey?) -> [AgentGroup: Int] {
        guard key != nil else { return [:] }
        return shelf(key).counts
    }

    public func unreadCount(in key: ProjectKey?) -> Int {
        guard key != nil else { return 0 }
        return shelf(key).unread
    }

    /// What the Dock badge counts for one project: every session under Needs you, and
    /// every finished one nobody has opened, each once (#70). Unread left Needs you, so
    /// it is added back here: a new finish still raises the badge.
    public func attentionCount(in key: ProjectKey?) -> Int {
        guard key != nil else { return 0 }
        return shelf(key).attention
    }

    /// Needs you, Blocked from an older daemon, or unread: what the badge and the widget
    /// count, and what Next Needing Attention visits.
    public func wantsALook(_ agent: Agent) -> Bool {
        if agent.showsUnread { return true }
        let group = group(of: agent)
        return group == .needsAttention || group == .blocked
    }

    /// By folder alone, whichever host it is on: what the phone asks, which only ever
    /// holds the Mac's (037 keeps servers off the phone in its first version).
    public func project(_ folder: URL?) -> DaemonAPI.ProjectSummary? {
        guard let folder else { return nil }
        return projects.first { $0.folder == folder }
    }

    /// The agents of one project, in one group, newest started first (#182) — or, under
    /// Parked, most recently parked first (040, FR-003).
    ///
    /// Grouped by `AgentGroup(for:)`, so no client can put an agent under a heading
    /// another client would not.
    ///
    /// The folder is standardised on the way in, because an agent's `cwd` is whatever
    /// it was started with and a project's folder is the resolved form. Comparing them
    /// raw is how a project ends up looking empty while its agents are plainly running.
    public func agents(in folder: URL?, group: AgentGroup) -> [Agent] {
        guard folder != nil else { return [] }
        return shelf(folder).groups[group] ?? []
    }

    /// Every agent of one project held, whatever its group.
    public func agents(inFolder folder: URL?) -> [Agent] {
        guard folder != nil else { return [] }
        return shelf(folder).groups.values.flatMap { $0 }
    }

    // MARK: Filing (#165)

    /// One agent into its place everywhere, out of where it was.
    private func file(_ agent: Agent) {
        let old = byID[agent.id]
        let folder = agent.projectFolder
        let group = group(of: agent)
        byID[agent.id] = agent
        // The list of everything: out of its old place, into its new one.
        var all = agents
        if let old {
            let at = ProjectShelf.place(of: old, in: all, by: ProjectShelf.byActivity)
            if at < all.count, all[at].id == old.id { all.remove(at: at) } else { all.removeAll { $0.id == old.id } }
        }
        all.insert(agent, at: ProjectShelf.place(of: agent, in: all, by: ProjectShelf.byActivity))
        agents = all
        if old == nil { agentCount = byID.count }
        if let old, old.state != .archived, agent.state == .archived { archivals &+= 1 }
        // Its shelves: in place when it stays where it was, moved when not.
        let was = filedAs[agent.id]
        let key = ShelfKey(folder: folder, host: agent.host)
        if let old, let was, was.folder == folder, was.host == agent.host, was.group == group {
            for shelf in [shelves[key], folderShelves[folder]].compactMap({ $0 }) {
                if shelf.replace(old, with: agent, in: group) { continue }
                shelf.remove(old, from: group)
                shelf.insert(agent, in: group)
            }
        } else {
            if let old, let was {
                shelves[ShelfKey(folder: was.folder, host: was.host)]?.remove(old, from: was.group)
                folderShelves[was.folder]?.remove(old, from: was.group)
            }
            shelf(ProjectKey(host: agent.host, folder: folder)).insert(agent, in: group)
            shelf(folder).insert(agent, in: group)
        }
        filedAs[agent.id] = (folder, agent.host, group)
        cells[agent.id]?.agent = agent
        if titles[agent.id] != agent.title {
            titles[agent.id] = agent.title
            titlesRevision &+= 1
        }
    }

    /// Agents let go of without being gone: an Archived fold closed, a search ended
    /// (#165). The host still has them, and lists them again when asked.
    public func forget(_ ids: some Sequence<UUID>) {
        for id in ids { unfile(id) }
    }

    /// One agent out of everything (retired, 051).
    private func unfile(_ id: UUID) {
        guard let old = byID.removeValue(forKey: id) else { return }
        agents.removeAll { $0.id == id }
        agentCount = byID.count
        if let was = filedAs.removeValue(forKey: id) {
            shelves[ShelfKey(folder: was.folder, host: was.host)]?.remove(old, from: was.group)
            folderShelves[was.folder]?.remove(old, from: was.group)
        }
        cells[id]?.agent = nil
        if titles.removeValue(forKey: id) != nil { titlesRevision &+= 1 }
    }

    /// Everything filed again from a list: what a connect, a host's re-list or a big
    /// page does, once, rather than a change at a time.
    private func refile(_ held: [Agent]) {
        var unique: [UUID: Agent] = [:]
        for agent in held where unique[agent.id] == nil { unique[agent.id] = agent }
        byID = unique
        agents = unique.values.sorted(by: ProjectShelf.byActivity)
        agentCount = unique.count
        filedAs = [:]
        var byKey: [ShelfKey: [AgentGroup: [Agent]]] = [:]
        var byFolder: [URL: [AgentGroup: [Agent]]] = [:]
        for agent in agents {
            let folder = agent.projectFolder
            let group = group(of: agent)
            filedAs[agent.id] = (folder, agent.host, group)
            byKey[ShelfKey(folder: folder, host: agent.host), default: [:]][group, default: []].append(agent)
            byFolder[folder, default: [:]][group, default: []].append(agent)
        }
        for (key, groups) in byKey { byKey[key] = groups.sortedInGroupOrder() }
        for (folder, groups) in byFolder { byFolder[folder] = groups.sortedInGroupOrder() }
        for (key, shelf) in shelves where byKey[key] == nil { shelf.replaceAll([:]) }
        for (key, groups) in byKey { shelf(ProjectKey(host: key.host, folder: key.folder)).replaceAll(groups) }
        for (folder, shelf) in folderShelves where byFolder[folder] == nil { shelf.replaceAll([:]) }
        for (folder, groups) in byFolder { shelf(folder).replaceAll(groups) }
        for (id, cell) in cells where cell.agent != unique[id] { cell.agent = unique[id] }
        let titles = unique.compactMapValues(\.title)
        if titles != self.titles {
            self.titles = titles
            titlesRevision &+= 1
        }
    }

    /// Where an agent sits, counting a file it has asked the person to look at.
    ///
    /// `filesToShow` is the unseen flag already: it is keyed by agent, it is put there
    /// when the agent asks, and `takeFileToShow` removes it when that conversation is
    /// opened. Nothing new is stored, and nothing outlives the window — which matches
    /// the daemon, which stores nothing for this and refuses to show a file when no
    /// window is open.
    public func group(of agent: Agent) -> AgentGroup {
        agent.group(wantsEyes: filesToShow[agent.id] != nil)
    }

    /// How many agents of one project are in each group, by this window's own grouping.
    ///
    /// This is what FR-009 means by a count being completed by something that knows.
    /// The daemon's `ProjectSummary.counts` are computed without knowing whether an
    /// agent asked to be looked at, because the daemon has no window; this one does,
    /// and the same `group(of:)` that files an agent under a heading counts it here —
    /// so the number on a project row is the number of rows under the heading, at the
    /// same moment, by construction (FR-006, FR-007). "Wants a person" is then
    /// `counts[.needsAttention] > 0` and nothing else, which consults the agent's state
    /// the way the check it replaced never did: a stopped agent that once asked to be
    /// looked at is under Stopped, and wants nobody (FR-008, FR-011, FR-012).
    public func counts(in folder: URL?) -> [AgentGroup: Int] {
        guard folder != nil else { return [:] }
        return shelf(folder).counts
    }

    /// How many finished conversations in this project nobody has looked at since,
    /// whichever group they are under. The number a project row shows in place of
    /// "complete": a complete chat that has been read is not news.
    public func unreadCount(in folder: URL?) -> Int {
        guard folder != nil else { return 0 }
        return shelf(folder).unread
    }

    /// `attentionCount(in:)` by folder alone, as the phone and the widget ask.
    public func attentionCount(in folder: URL?) -> Int {
        guard folder != nil else { return 0 }
        return shelf(folder).attention
    }

    /// The question this agent is blocked on, if it still is.
    public func permissions(for agentID: UUID?) -> [PermissionRequest] {
        permissions.filter { $0.agentID == agentID }
    }

    public func permission(for agentID: UUID?) -> PermissionRequest? {
        guard let agentID else { return nil }
        return permissions.first { $0.agentID == agentID }
    }

    /// The form this agent is waiting on, if there is one.
    public func elicitation(for agentID: UUID?) -> ElicitationRequest? {
        guard let agentID else { return nil }
        return elicitations.first { $0.agentID == agentID }
    }
}

/// Where a project's shelf is kept: its folder, standardized, and its host.
private struct ShelfKey: Hashable {
    var folder: URL
    var host: HostID
}

private extension Dictionary where Key == AgentGroup, Value == [Agent] {
    /// Each group in its own order: filed from a list newest activity first, Archived
    /// is already, and the rest are not (#182).
    func sortedInGroupOrder() -> Self {
        var sorted = self
        for (group, agents) in sorted where group != .archived {
            sorted[group] = agents.sorted(by: ProjectShelf.order(group))
        }
        return sorted
    }
}

/// The events an Events page shows, and the same cut into days (#137).
public struct ShownEvents {
    /// Newest first, as `recentEvents` holds them.
    public let events: [Event]
    /// Newest day first, each day's events newest first.
    public let days: [(day: Date, events: [Event])]

    public init(_ events: [Event], calendar: Calendar = .current) {
        self.events = events
        var days: [(day: Date, events: [Event])] = []
        for event in events {
            let day = calendar.startOfDay(for: event.at)
            if days.last?.day == day {
                days[days.count - 1].events.append(event)
            } else {
                days.append((day, [event]))
            }
        }
        self.days = days
    }
}
