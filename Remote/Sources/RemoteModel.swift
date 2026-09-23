import SwiftUI
import UIKit
import AgentsKitCore
import Foundation
import Observation

/// The remote's state, which is a view of the Mac's and never a copy of it.
///
/// Everything it knows came from the daemon and everything it does goes back to it.
/// The remote owns no agent, decides nothing, and stores nothing between launches —
/// a phone that kept a transcript would be a phone that still had one after it was
/// revoked.
///
/// The work itself is held in `AgentsModel`, the same file the Mac uses, so the two
/// cannot disagree about what a notification means. What is here is the rest: which
/// project and agent are being looked at, and whether the Mac is still there.
@MainActor
@Observable
final class RemoteModel {
    let work = AgentsModel()

    /// Whether the Mac is answering, and when it last did.
    private(set) var isConnected = false
    private(set) var lastHeardFrom: Date?
    private(set) var problem: String?

    /// Which project is being looked at. Not the daemon's business: it owns what is
    /// true about the work, and which of it somebody happens to be reading is not that.
    var selectedProject: URL? {
        didSet {
            guard selectedProject != oldValue else { return }
            selection = nil
        }
    }

    /// The conversation open, if any. Set by the push, cleared by the back button.
    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            work.watching = selection
            presence?.watching(selection)
            Task { await loadTranscript() }
        }
    }

    private let client: DaemonClient
    /// 021: this device's banner, and its report of where the person is. Neither
    /// decides anything; the Mac routes and these two obey.
    private let notifier = DeviceNotifier()
    private var presence: PresenceReporter?
    /// Which device this is, minted once and kept. Told to the Mac right after every
    /// connection (`surface/identify`), so every later request on it is this device's.
    private let deviceID: UUID = {
        let key = "device.id"
        if let text = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()
    /// This device's key, made once and kept in this device's keychain. The Mac only
    /// ever sees the public half.
    private let key: DeviceKey? = try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup)
    /// The mailbox's subscriptions are saved once per launch, the first time the Mac
    /// answers the announce.
    private var subscribed = false
    /// This device, as the Mac has it: `nil` until the Mac has answered the announce.
    private(set) var thisDevice: Device?
    private var listening: Task<Void, Never>?
    /// The loop looking for the Mac, so two of them never run at once.
    private var reconnecting: Task<Void, Never>?
    private var isLoadingEarlier = false

    init(link: any DaemonLink) {
        client = DaemonClient(link: link)
    }

    // MARK: What the screens read

    var projects: [DaemonAPI.ProjectSummary] { work.liveProjects }
    /// Archived ones too, for the spending page. A project put away still cost what it
    /// cost, and a grand total that quietly dropped it would be wrong rather than tidy.
    var allProjects: [DaemonAPI.ProjectSummary] { work.projects }
    /// The open project's standing arrangements. Listed here, driven on the Mac.
    var workflows: [WorkflowSummary] { work.workflows(in: selectedProject) }
    var selectedSummary: DaemonAPI.ProjectSummary? { work.project(selectedProject) }
    var selectedAgent: Agent? { work.agent(selection) }
    var entries: [TranscriptEntry] { work.entries }
    /// What the reader will allow, as the Mac has it. The phone shows limits and
    /// never sets them, so there is no setter beside this.
    var costState: DaemonAPI.CostState? { work.costState }
    var costLimits: CostLimits { work.costState?.limits ?? CostLimits() }
    var hasMoreBefore: Bool { work.hasMoreBefore }

    /// How much transcript to ask for on the first fetch, measured rather than fixed.
    ///
    /// A constant page means the iPad fetches twice before the reader has finished the
    /// first screen: a 13-inch iPad in landscape shows two to three times a phone's
    /// lines, and the same number of entries covers proportionally less of it
    /// (research §9, SC-007).
    ///
    /// Entries, not lines — the protocol pages by entry — so the screen's height is
    /// turned into one through a rough average of how tall an entry draws. Rough is
    /// enough: being out by a third costs one extra fetch, which is what the constant
    /// cost every time.
    private(set) var firstPageSize = defaultPageSize

    /// A phone's, near enough, for the first conversation opened before anything has
    /// been measured. Every one after it uses the real height.
    static let defaultPageSize = 60

    /// About as tall as an entry draws: a line of tool call, a short paragraph, a
    /// state change. Measured by eye rather than computed, and the clamp either side
    /// is what keeps a bad guess from becoming a bad fetch.
    private static let entryHeight: CGFloat = 80
    /// Screens' worth to hold: enough to scroll a couple before going back for more.
    private static let screensHeld: CGFloat = 3

    /// Told by the conversation, which is the only thing that knows how tall it is.
    func measure(transcriptHeight height: CGFloat) {
        guard height > 0 else { return }
        let entries = (height / Self.entryHeight) * Self.screensHeld
        firstPageSize = min(200, max(30, Int(entries.rounded())))
    }

    func agents(group: AgentGroup) -> [Agent] { work.agents(in: selectedProject, group: group) }

    /// A project's counts from the same grouping its page uses, so the list and the
    /// page cannot disagree about what needs attention.
    func counts(in folder: URL?) -> [AgentGroup: Int] { work.counts(in: folder) }

    /// Whether the Mac is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

    /// The question the open conversation is blocked on, if it still is.
    var questionForSelection: PermissionRequest? { work.permission(for: selection) }

    /// The form it is blocked on instead, if it is one of those.
    ///
    /// The two never share the screen, and the permission wins where both somehow
    /// exist: it is the one the runtime is most likely to be sitting on, and two
    /// blocking cards at once on a phone is a card nobody can read.
    var formForSelection: ElicitationRequest? {
        questionForSelection == nil ? work.elicitation(for: selection) : nil
    }

    /// A file being read, by path, or nothing.
    ///
    /// On the model rather than in a view's `@State` because the tap that opens one is
    /// a tool call's file name, several views down inside the transcript, and passing a
    /// binding through every row to reach it would be a worse thing than this.
    var fileOnScreen: String?

    /// What the agent has asked be looked at, if the conversation open is its own.
    /// Peeked rather than taken: taking it is what opening it does.
    var fileTheAgentWants: ShownFile? {
        guard let selection else { return nil }
        return work.filesToShow[selection]
    }

    /// Open what the agent asked for, and take it off the model so it is asked once.
    /// "Look at this" is about a moment, and the moment has passed by the next launch.
    func openFileTheAgentWants() {
        guard let selection, let file = work.takeFileToShow(for: selection) else { return }
        fileOnScreen = file.path
    }

    /// Whether what is on screen can still be trusted, and acted on.
    ///
    /// Stale is not an error. It is the honest answer for a Mac that is asleep, and
    /// the screens say so and stop offering actions rather than pretending (FR-035).
    var isStale: Bool { !isConnected }

    /// How long since the Mac last answered, in words.
    var lastHeard: String? {
        guard let lastHeardFrom else { return nil }
        return lastHeardFrom.formatted(.relative(presentation: .named))
    }

    // MARK: Staying in touch

    /// Keep trying until the Mac answers.
    ///
    /// It retries rather than giving up because the ordinary first run fails: iOS will
    /// not let an app look at the local network until the user has said yes, and the
    /// asking happens after the first attempt has already been refused. Giving up there
    /// would mean tapping Allow and then having to quit the app to use it.
    ///
    /// It is also the right behaviour afterwards. A Mac that is asleep, or on another
    /// network, is a thing that comes back, and the screens say "last heard from" in
    /// the meantime rather than looking broken.
    func connect() async {
        guard reconnecting == nil else { return }
        reconnecting = Task { [weak self] in
            var wait = Duration.seconds(1)
            while !Task.isCancelled {
                guard let self else { return }
                if await self.tryOnce() { break }
                try? await Task.sleep(for: wait)
                // Backing off to half a minute, so a phone in a pocket with no Mac to
                // find is not holding the radio open every second all afternoon.
                wait = min(wait * 2, .seconds(30))
            }
            await self?.finishedReconnecting()
        }
        await reconnecting?.value
    }

    private func tryOnce() async -> Bool {
        do {
            try await client.connect(startIfNeeded: false)
            isConnected = true
            lastHeardFrom = Date()
            problem = nil
            listen()
            await announce()
            await identify()
            startPresence()
            presence?.connected()
            await refreshEverything()
            return true
        } catch {
            isConnected = false
            return false
        }
    }

    private func finishedReconnecting() {
        reconnecting = nil
    }

    private func listen() {
        listening?.cancel()
        let notifications = client.notifications()
        listening = Task { [weak self] in
            for await notification in notifications {
                guard let self else { return }
                self.lastHeardFrom = Date()
                // Anything the shared model does not claim is the Mac's own — shells,
                // terminals — and a remote has no business with it.
                _ = self.work.apply(notification.method, notification.params)
                if notification.method == DaemonAPI.Notification.attentionChanged,
                   let change = try? notification.params?.decode(DaemonAPI.AttentionNotification.self) {
                    await self.notifier.apply(change, me: .device(self.deviceID))
                }
                if notification.method == DaemonAPI.Notification.deviceChanged,
                   let change = try? notification.params?.decode(DaemonAPI.DeviceNotification.self),
                   change.id == self.deviceID {
                    self.thisDevice = change.device
                    self.subscribeOnce()
                }
            }
            await self?.lostTouch()
        }
    }

    /// The Mac stopped answering. Say so, keep what is on screen, and go back for it.
    private func lostTouch() async {
        isConnected = false
        listening = nil
        await connect()
    }

    func refreshEverything() async {
        await refreshAgents()
        // After the agents, because a project's counts are worked out from them.
        await refreshProjects()
        await refreshPermissions()
        await refreshElicitations()
        await refreshAttention()
        await refreshResuming()
        await refreshCostState()
        await refreshWorkflows()
        await loadTranscript()
        settleSelection()
        if let pendingOpen { open(pendingOpen) }
    }

    // MARK: Where this device is (021)

    /// The app came to the front or went behind. `.active` is foreground and unlocked,
    /// which is what "in the person's hands" means on a device.
    func scenePhase(_ phase: ScenePhase) {
        presence?.scenePhase(phase)
        if phase == .active { Task { await refreshAttention() } }
    }

    private var kind: Device.Kind {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: .iPhone
        case .pad: .iPad
        default: .unknown
        }
    }

    /// `devices/announce`: who this is and its public key, once per connection — which
    /// is all pairing is. A Mac that knows this id under another key, or one too old to
    /// be asked, leaves `thisDevice` nil and the LAN link works as it always did; what
    /// announcing buys is being reached when the LAN cannot.
    private func announce() async {
        guard let key else { return }
        do {
            thisDevice = try await client.call(
                DaemonAPI.Method.devicesAnnounce,
                DaemonAPI.DeviceAnnouncement(id: deviceID, publicKey: key.publicKey,
                                             name: UIDevice.current.name, kind: kind),
                returning: Device.self)
            note("pairing: announced as \(deviceID)")
        } catch {
            note("pairing: announce failed: \(error)")
        }
        subscribeOnce()
    }

    /// Ask CloudKit to push this device's mailbox items here. Idempotent on the server
    /// — the subscriptions have stable ids — so once per launch is plenty.
    private func subscribeOnce() {
        guard thisDevice != nil, !subscribed else { return }
        subscribed = true
        Task {
            // Permission first, so the Mac hears `mayNotify` and may choose this device.
            await notifier.requestIfUndetermined()
            do {
                try await CloudKitMailbox().subscribe(device: deviceID)
                note("mailbox: subscribed")
            } catch {
                note("mailbox: subscribe failed: \(error)")
                subscribed = false
            }
        }
    }

    // MARK: A push arrived (021 T077, T079)

    /// A silent push: a need moved here without a buzz, moved away, or was met. The
    /// loud ones never come here — `RemoteNotify` turns those into banners before the
    /// system shows them. Everything this does is to local notifications, and it
    /// decides nothing about where the need belongs.
    func receivedPush(_ userInfo: [AnyHashable: Any]) async {
        note("push: \(userInfo)")
        guard let pushed = CloudKitMailbox.pushed(from: userInfo) else { return }
        if pushed.withdrawn || pushed.envelope == nil {
            notifier.withdraw(pushed.token)
            return
        }
        guard let key, let envelope = pushed.envelope,
              let headline = try? Envelope.open(envelope, with: key) else { return }
        notifier.show(headline, needID: pushed.needID, alert: pushed.alert)
    }

    /// Open one conversation from a banner: its project first, then the chat.
    ///
    /// The chat is pushed on the next turn of the run loop, not in the same one as the
    /// project change: on a phone the split view collapses, and a path set while the
    /// detail column is still being pushed is dropped — the tap "went to the right
    /// project" and stopped there (2026-09-21). A banner tapped before the agents have
    /// arrived — a cold launch — is kept and honoured once they have.
    func open(_ agentID: UUID) {
        guard let agent = work.agent(agentID) else {
            pendingOpen = agentID
            return
        }
        pendingOpen = nil
        selectedProject = Project.standardize(agent.cwd)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            self.selection = agentID
        }
    }

    private var pendingOpen: UUID?

    /// Which conversation a banner is about, from the need it names. The Mac's
    /// `attention/pending` is the truth; this reads the copy the model already holds.
    func agentID(forNeedToken token: String) -> UUID? {
        if let need = work.needs.first(where: { $0.key.token == token }) { return need.value.agentID }
        switch token.split(separator: ":", maxSplits: 1).map(String.init) {
        case let parts where parts.count == 2 && parts[0] == "permission":
            return work.permissions.first { $0.id.uuidString == parts[1] }?.agentID
        case let parts where parts.count == 2 && parts[0] == "elicitation":
            return work.elicitations.first { $0.id.uuidString == parts[1] }?.agentID
        case let parts where parts.count == 2 && parts[0] == "report":
            return UUID(uuidString: String(parts[1].split(separator: ":").first ?? ""))
        default:
            return nil
        }
    }

    private func identify() async {
        _ = try? await client.call(DaemonAPI.Method.surfaceIdentify,
                                   DaemonAPI.SurfaceIdentification(id: deviceID, name: UIDevice.current.name, kind: kind))
    }

    private func startPresence() {
        guard presence == nil else { return }
        notifier.open = { [weak self] agentID in self?.open(agentID) }
        notifier.openNeed = { [weak self] token in
            guard let self, let agentID = self.agentID(forNeedToken: token) else { return }
            self.notifier.open(agentID)
        }
        notifier.authorisationChanged = { [weak self] in self?.presence?.connected() }
        let reporter = PresenceReporter { [weak self] watching, active, mayNotify in
            guard let self else { return }
            _ = try? await self.client.call(DaemonAPI.Method.presenceReport,
                                            DaemonAPI.PresenceReport(watching: watching, active: active,
                                                                     mayNotify: mayNotify))
        }
        presence = reporter
    }

    private func refreshAttention() async {
        guard let pending = try? await client.call(DaemonAPI.Method.attentionPending,
                                                   Optional<String>.none,
                                                   returning: DaemonAPI.AttentionPending.self) else { return }
        work.replaceAttention(pending)
        await notifier.sweep(keeping: pending, me: .device(deviceID))
    }

    private func refreshAgents() async {
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList,
                                                  DaemonAPI.ListRequest(),
                                                  returning: [Agent].self) else { return }
        work.replaceAgents(listed)
    }

    /// What today has cost and what the reader will allow. The phone shows limits
    /// and never sets them. A daemon too old to know the method leaves this nil, and
    /// every surface shows what it showed before this feature.
    private func refreshCostState() async {
        guard let state = try? await client.call(DaemonAPI.Method.costState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.CostState.self) else { return }
        work.replaceCostState(state)
    }

    private func refreshProjects() async {
        guard let listed = try? await client.call(DaemonAPI.Method.projectsList,
                                                  DaemonAPI.ProjectsListRequest(),
                                                  returning: [DaemonAPI.ProjectSummary].self)
        else { return }
        work.replaceProjects(listed)
    }

    private func refreshPermissions() async {
        guard let listed = try? await client.call(DaemonAPI.Method.permissionsPending,
                                                  Optional<String>.none,
                                                  returning: [PermissionRequest].self) else { return }
        work.replacePermissions(listed)
    }

    /// The forms an agent is blocked on. Fetched for the same reason permissions are:
    /// `agent/elicitation` keeps them current afterwards, but a question raised before
    /// this phone connected would otherwise never appear at all.
    private func refreshElicitations() async {
        guard let listed = try? await client.call(DaemonAPI.Method.elicitationsPending,
                                                  Optional<String>.none,
                                                  returning: [ElicitationRequest].self) else { return }
        work.replaceElicitations(listed)
    }

    /// What the Mac is still bringing back after a restart.
    ///
    /// A daemon too old to know the method answers method-not-found, which is the
    /// same as nothing coming back — not a connection that failed.
    /// Every project's, in one call, the way the window asks for them. `workflow/changed`
    /// keeps them current afterwards; without this first fetch the section would stay
    /// empty until something happened to a workflow, which on a quiet project is never.
    private func refreshWorkflows() async {
        guard let listed = try? await client.call(DaemonAPI.Method.workflowsList,
                                                  DaemonAPI.WorkflowsListRequest(),
                                                  returning: [WorkflowSummary].self) else { return }
        work.replaceWorkflows(listed)
    }

    private func refreshResuming() async {
        let response = try? await client.call(DaemonAPI.Method.agentsResuming,
                                              Optional<String>.none,
                                              returning: DaemonAPI.ResumingResponse.self)
        work.setResuming(response?.agentIDs ?? [])
    }

    /// A project archived on the Mac while it is being read here moves the selection
    /// rather than leaving an empty screen.
    private func settleSelection() {
        guard let selectedProject else { return }
        if !projects.contains(where: { $0.folder == selectedProject }) {
            self.selectedProject = nil
        }
    }

    // MARK: The conversation

    func loadTranscript() async {
        guard let selection else { work.clearTranscript(); return }
        guard let page = try? await client.call(DaemonAPI.Method.agentsTranscript,
                                                DaemonAPI.TranscriptRequest(agentID: selection, limit: firstPageSize),
                                                returning: TranscriptPage.self) else { return }
        // A chat left before its page arrived does not get that page shown under the
        // next one's name.
        guard self.selection == selection else { return }
        work.replaceTranscript(with: page)
    }

    /// Another page, backwards. Never the whole history: that is the difference
    /// between a conversation opening in a second and one opening on a train.
    func loadEarlier() async {
        guard let selection, work.hasMoreBefore, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        guard let page = try? await client.call(
            DaemonAPI.Method.agentsTranscript,
            DaemonAPI.TranscriptRequest(agentID: selection, before: work.firstEntryIndex,
                                        limit: firstPageSize),
            returning: TranscriptPage.self) else { return }
        guard self.selection == selection else { return }
        work.prepend(page)
    }

    // MARK: Doing something about it

    /// Answer the question the agent is blocked on.
    ///
    /// Refused here and now when the Mac is not answering, rather than accepted and
    /// quietly dropped (FR-033). An answer that cannot be delivered is not an answer.
    @discardableResult
    func answer(_ request: PermissionRequest, optionID: String) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        do {
            try await client.call(DaemonAPI.Method.permissionsAnswer,
                                  DaemonAPI.AnswerRequest(permissionID: request.id,
                                                          optionID: optionID))
            return true
        } catch {
            problem = "That question could not be answered."
            return false
        }
    }

    /// Answer the form the agent is blocked on.
    ///
    /// Refused here when the Mac is not answering, exactly as a permission is: an
    /// answer that cannot be delivered is not an answer, and an agent left waiting
    /// while the person believes they replied is the worst of both.
    @discardableResult
    func answer(_ request: ElicitationRequest,
                action: DaemonAPI.AnswerElicitationRequest.Action,
                content: [String: JSONValue] = [:]) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        do {
            try await client.call(DaemonAPI.Method.elicitationsAnswer,
                                  DaemonAPI.AnswerElicitationRequest(requestID: request.id,
                                                                     action: action,
                                                                     content: content))
            return true
        } catch {
            // The daemon refuses an answer that does not fit the shape the agent asked
            // for, and says why. Its words, not ours: it knows which field was wrong.
            problem = (error as? JSONRPCError)?.message ?? "That question could not be answered."
            return false
        }
    }

    /// Say something to an agent that already exists.
    ///
    /// Answers whether it went, so the prompt bar can keep what was typed when it did
    /// not. A prompt that could not be delivered and was cleared from the field anyway
    /// is the worst outcome here: the person believes they asked, and nothing did.
    ///
    /// An agent mid-turn is not refused — the daemon queues it and gets to it after
    /// this turn. That is the daemon's rule and it is deliberately not second-guessed
    /// from here.
    func send(_ what: String, to agentID: UUID) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that was not sent."
            return false
        }
        do {
            try await client.call(DaemonAPI.Method.agentsPrompt,
                                  DaemonAPI.PromptRequest(agentID: agentID, text: what))
            return true
        } catch {
            problem = "That did not reach your Mac. What you typed is still there."
            return false
        }
    }

    func stop(_ agentID: UUID) async { await act(DaemonAPI.Method.agentsStop, agentID) }
    func archive(_ agentID: UUID) async { await act(DaemonAPI.Method.agentsArchive, agentID) }
    func unarchive(_ agentID: UUID) async { await act(DaemonAPI.Method.agentsUnarchive, agentID) }

    private func act(_ method: String, _ agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await client.call(method, DaemonAPI.AgentRequest(agentID: agentID))
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    func dismissProblem() { problem = nil }

#if DEBUG
    /// Open a named project, and optionally a named agent, straight after connecting.
    ///
    /// Scaffolding for the phase this app is in: there is no Simulator window on this
    /// machine to tap, and a layout nobody can look at is a layout nobody can settle.
    /// `-project Agents -agent "Lay the remote out for a phone"` lands on that screen.
    ///
    /// It goes when the layout does. What replaces it is the real thing US1 needs: a
    /// notification that lands on the agent it names.
    func openFromLaunchArguments() async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.index(after: index) < arguments.endIndex
            else { return nil }
            return arguments[arguments.index(after: index)]
        }
        if let name = value("-project"),
           let summary = work.projects.first(where: { $0.name == name }) {
            selectedProject = summary.folder
        }
        if let title = value("-agent"),
           let agent = work.agents.first(where: { $0.title == title }) {
            selectedProject = agent.cwd
            // A beat, so the project has been pushed before the conversation is. Two
            // pushes in one turn of the loop is not something to ask of a split view.
            try? await Task.sleep(for: .milliseconds(600))
            selection = agent.id
        }
    }
#endif
}
