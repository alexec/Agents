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
    var transcriptItems: [TranscriptItem] { work.transcriptItems }
    /// What the reader will allow, as the Mac has it. The phone shows limits and does
    /// not set them; it can only let one agent go on past its own (033).
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

    /// Somebody asked for the end of the conversation: a prompt went. A counter, so two
    /// asks in a row both land (033, the Mac's own rule).
    private(set) var scrollToEndToken = 0

    /// Told by the conversation, which is the only thing that knows how tall it is.
    func measure(transcriptHeight height: CGFloat) {
        guard height > 0 else { return }
        let entries = (height / Self.entryHeight) * Self.screensHeld
        firstPageSize = min(200, max(30, Int(entries.rounded())))
    }

    func agents(group: AgentGroup) -> [Agent] { work.agents(in: selectedProject, group: group) }

    // MARK: Starting an agent (029)

    /// The project a New agent sheet is open on, if one is. On the model rather than in
    /// the page's `@State` so a launch argument can open it, and so the sheet can close
    /// itself when the agent it started is ready to be looked at.
    var startingIn: URL? {
        didSet {
            guard startingIn != oldValue else { return }
            if let startingIn { Task { await openStart(in: startingIn) } } else { closeStart() }
        }
    }

    enum StartChoicesState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// The runtime the sheet will start. Seeded with the one the Mac would offer.
    private(set) var startRuntimeID: String?
    /// What that runtime offers, in the order they are drawn.
    private(set) var startOptions: [ConfigOption] = []
    /// What has been chosen, by option id. Sent as the start's options.
    private(set) var startChosen: [String: JSONValue] = [:]
    private(set) var startChoicesState: StartChoicesState = .loading
    /// Why the last Send did not start anything, in one sentence. Shown in the sheet
    /// rather than as the app's alert, which a sheet would hide.
    private(set) var startRefusal: String?
    /// A start sent whose answer never came back. Its request id is reused by every
    /// retry, so the Mac answers with the agent the first one made rather than
    /// starting the work twice.
    private(set) var unsettledStart: DaemonAPI.StartRequest?
    private(set) var isStarting = false
    /// Where in the project the new agent works, when not the project folder (030).
    /// Decided per agent, so it goes back to the project folder each time the sheet
    /// opens and after every start.
    private(set) var startWorktree: WorktreeChoice?
    /// What the sheet's project's repository has, for the Worktree row. Not a
    /// repository until the Mac says otherwise, which keeps the row hidden.
    private(set) var startWorktrees: DaemonAPI.WorktreesListResponse = .notARepository
    private var startDraftID: UUID?
    /// Bumped by every fetch of a runtime's choices, so an answer for a runtime the
    /// person has since moved off is recognised as that and let go.
    private var startGeneration = 0

    var startRuntime: RuntimeStatus? { runtimes.first { $0.runtime.id == startRuntimeID } }

    private func openStart(in folder: URL) async {
        startRefusal = nil
        startWorktree = nil
        startWorktrees = .notARepository
        Task { await loadStartWorktrees(in: folder) }
        if startRuntimeID == nil || !availableRuntimeIDs.contains(startRuntimeID ?? "") {
            startRuntimeID = work.defaultRuntimeID(available: availableRuntimeIDs)
        }
        await loadStartChoices()
    }

    /// Put the sheet away. Its runtime is let go; what was typed is the keeper's.
    private func closeStart() {
        startGeneration += 1
        discardStartDraft()
        startOptions = []
        startChosen = [:]
        startChoicesState = .loading
        startRefusal = nil
        startWorktree = nil
    }

    /// The repository's worktrees for the sheet. Asked once when it opens, never polled.
    private func loadStartWorktrees(in folder: URL) async {
        let answer = (try? await client.call(DaemonAPI.Method.worktreesList,
                                             DaemonAPI.WorktreesListRequest(folder: folder),
                                             returning: DaemonAPI.WorktreesListResponse.self))
            ?? .notARepository
        guard startingIn == folder else { return }
        startWorktrees = answer
    }

    /// Where the draft is made: in a worktree already there when one is chosen, so the
    /// start can use it; otherwise the project folder (030, research R2).
    private var startOptionsFolder: URL? {
        if case .existing(let root) = startWorktree { return root }
        return startingIn
    }

    /// Choose where the new agent works, and make the draft there if that moved it.
    func chooseWorktree(_ choice: WorktreeChoice?) async {
        let before = startOptionsFolder
        startWorktree = choice
        startRefusal = nil
        if startOptionsFolder != before { await loadStartChoices() }
    }

    func chooseRuntime(_ runtimeID: String) async {
        guard runtimeID != startRuntimeID else { return }
        startRuntimeID = runtimeID
        startRefusal = nil
        await loadStartChoices()
    }

    func choose(_ value: JSONValue, for optionID: String) {
        startChosen[optionID] = value
    }

    /// A runtime is started behind the form so its choices are real ones; the start
    /// that follows uses it. Answered from what it offered last time when the Mac has
    /// that, and put right by `agents/draftOptions` if it has moved.
    func loadStartChoices() async {
        guard let folder = startOptionsFolder else { return }
        guard let runtimeID = startRuntimeID else {
            // Not "asking": there is nobody to ask.
            startChoicesState = .failed(runtimes.isEmpty
                ? "No runtimes are set up on the Mac. Set one up there to start an agent."
                : "None of the Mac's runtimes can start right now.")
            return
        }
        startGeneration += 1
        let generation = startGeneration
        discardStartDraft()
        startOptions = []
        startChosen = [:]
        startChoicesState = .loading
        do {
            let response = try await client.call(DaemonAPI.Method.agentsOptions,
                                                 DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: folder),
                                                 returning: DaemonAPI.OptionsResponse.self)
            guard generation == startGeneration else { discard(draft: response.draftID); return }
            startDraftID = response.draftID
            showStart(response.options, opening: true)
        } catch {
            guard generation == startGeneration else { return }
            startChoicesState = .failed(sentence(for: error))
        }
    }

    /// Draw what the runtime offers, keeping every choice already made that is still
    /// one of the choices.
    ///
    /// On the first draw only, the mode opens on the one last chosen for this runtime
    /// on any device, as the Mac's form does: a correction arriving behind a form drawn
    /// from memory must not undo a mode chosen since.
    private func showStart(_ options: [ConfigOption], opening: Bool = false) {
        startOptions = PromptControlsState.drawable(agentOptions: nil, draftOptions: options)
        var kept: [String: JSONValue] = [:]
        for option in startOptions {
            if let chosen = startChosen[option.id],
               option.isBoolean || (option.options ?? []).contains(where: { $0.value == chosen }) {
                kept[option.id] = chosen
            } else if let current = option.currentValue {
                kept[option.id] = current
            }
        }
        if opening, let runtimeID = startRuntimeID, let mode = ModeMemory.modeOption(in: startOptions),
           let value = ModeMemory.startingValue(remembered: work.rememberedMode(for: runtimeID), for: mode) {
            kept[mode.id] = value
        }
        startChosen = kept
        startChoicesState = .ready
    }

    private func settleStartDraft(_ notification: DaemonAPI.DraftOptionsNotification) {
        guard notification.draftID == startDraftID else { return }
        if let failure = notification.failure {
            startDraftID = nil
            startOptions = []
            startChosen = [:]
            startChoicesState = .failed(failure)
            return
        }
        showStart(notification.options)
    }

    private func discardStartDraft() {
        guard let startDraftID else { return }
        self.startDraftID = nil
        discard(draft: startDraftID)
    }

    /// Not waited on: the sheet has moved on, and a Mac too old to know the method has
    /// nothing to be told.
    private func discard(draft: UUID) {
        Task { _ = try? await client.call(DaemonAPI.Method.agentsDiscardDraft,
                                          DaemonAPI.DiscardDraftRequest(draftID: draft)) }
    }

    /// Start an agent in the sheet's project. Answers whether it started, so the sheet
    /// keeps what was typed when it did not.
    ///
    /// Refused here, before anything is sent, when the Mac is not answering or the
    /// project cannot take a new agent. Refused by the Mac, its sentence is shown as it
    /// is. Lost on the way back, nothing is assumed: the start is kept, and settled by
    /// its request id once the Mac is heard from again.
    func startAgent(prompt: String, attachments: [Attachment] = []) async -> Bool {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !isStarting, let folder = startingIn else { return false }
        if let refusal = startRefusalBeforeSending(in: folder) {
            startRefusal = refusal
            return false
        }
        guard let runtimeID = startRuntimeID else {
            startRefusal = "Choose a runtime to start."
            return false
        }
        // Before sending, and in the Mac's words: a runtime that will not take what is
        // attached would refuse the whole prompt after the agent had started.
        let capabilities = promptCapabilities(for: runtimeID)
        if let refused = attachments.first(where: { PhoneAttachment.refusal(for: $0, from: capabilities) != nil }),
           let reason = PhoneAttachment.refusal(for: refused, from: capabilities) {
            startRefusal = "\(refused.displayName): \(reason)."
            return false
        }
        if let tooMuch = PhoneAttachment.totalRefusal(attachments) {
            startRefusal = tooMuch
            return false
        }
        // The unsettled start's id only for the same project: sent again there, the Mac
        // answers with the agent it made if it made one. Anywhere else it is a new
        // start, and reusing the id would be answered with the other project's agent.
        let retrying = unsettledStart?.cwd == folder ? unsettledStart?.requestID : nil
        let request = DaemonAPI.StartRequest(
            runtimeID: runtimeID, cwd: folder, prompt: words, attachments: attachments,
            startOptions: StartOptions(values: startChosen), draftID: startDraftID,
            worktree: startWorktree, requestID: retrying ?? UUID())
        return await send(start: request)
    }

    private func send(start request: DaemonAPI.StartRequest) async -> Bool {
        isStarting = true
        defer { isStarting = false }
        startRefusal = nil
        unsettledStart = request
        do {
            let id = try await client.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            await started(id, in: request.cwd)
            return true
        } catch let refused as JSONRPCError {
            // The Mac said no, so nothing was started under this id and a later
            // Send is a fresh start.
            unsettledStart = nil
            startRefusal = refused.message
            return false
        } catch {
            startRefusal = "Your Mac stopped answering before it said whether the agent started. "
                + "This will be checked when it is back."
            return false
        }
    }

    /// - Parameter open: go to it. True when the person is waiting on the sheet; false
    ///   when a lost answer is settled later, perhaps while they read something else,
    ///   and taking the screen from them would be the surprise.
    private func started(_ id: UUID, in folder: URL, open: Bool = true) async {
        unsettledStart = nil
        startWorktree = nil
        // Only now: a draft is kept until the agent it was typed for exists (FR-017).
        StartDraftKeeper.shared.clear(in: folder)
        guard open else { return }
        startDraftID = nil
        await refreshAgents()
        await refreshProjects()
        startingIn = nil
        selectedProject = folder
        // A beat, so the sheet has gone before the conversation is pushed. Two
        // presentations in one turn of the loop is not something to ask of a split view.
        try? await Task.sleep(for: .milliseconds(400))
        selection = id
    }

    /// A start whose answer was lost: find the agent it made, or send it again with the
    /// same id, which the Mac answers with that agent if it did make one.
    private func settleUnsettledStart() async {
        guard let request = unsettledStart, let requestID = request.requestID else { return }
        if let made = work.agents.first(where: { $0.startRequestID == requestID }) {
            await started(made.id, in: request.cwd, open: startingIn == request.cwd)
            return
        }
        guard startingIn == request.cwd else { return }
        _ = await send(start: request)
    }

    // MARK: The project's worktrees (030)

    /// The branch each project folder is on, for the chat's folder chip, as the Mac
    /// shows it. Missing until asked, and for a folder in no repository.
    private(set) var projectFolderBranches: [URL: String] = [:]

    /// Asked when a chat opens and when its turn ends, since someone may have checked
    /// out another branch meanwhile. Never polled.
    func loadProjectFolderBranch(of agent: Agent) async {
        guard agent.worktree == nil else { return }
        let folder = agent.projectFolder
        let answer = try? await client.call(DaemonAPI.Method.worktreesList,
                                            DaemonAPI.WorktreesListRequest(folder: folder),
                                            returning: DaemonAPI.WorktreesListResponse.self)
        projectFolderBranches[folder] = answer?.projectFolderBranch
    }

    /// The app's worktrees for the project on screen, for its Worktrees section.
    private(set) var projectWorktrees: DaemonAPI.WorktreesListResponse = .notARepository
    private var projectWorktreesFolder: URL?

    /// Asked when the project page appears and after a removal, never polled.
    func loadProjectWorktrees(in folder: URL) async {
        projectWorktreesFolder = folder
        let answer = (try? await client.call(DaemonAPI.Method.worktreesList,
                                             DaemonAPI.WorktreesListRequest(folder: folder),
                                             returning: DaemonAPI.WorktreesListResponse.self))
            ?? .notARepository
        guard projectWorktreesFolder == folder else { return }
        projectWorktrees = answer
    }

    /// What removing one would lose, or nil when the Mac could not say (and the app's
    /// alert says why).
    func checkWorktreeRemoval(_ root: URL, in folder: URL) async -> DaemonAPI.RemovalCheck? {
        do {
            return try await client.call(DaemonAPI.Method.worktreesCheck,
                                         DaemonAPI.WorktreeRemovalRequest(project: folder, root: root),
                                         returning: DaemonAPI.RemovalCheck.self)
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// Remove one. `confirmed` is the person having seen what would be lost; the Mac
    /// checks again either way.
    func removeWorktree(_ root: URL, in folder: URL, confirmed: Bool) async {
        do {
            _ = try await client.call(DaemonAPI.Method.worktreesRemove,
                                      DaemonAPI.WorktreeRemovalRequest(project: folder, root: root,
                                                                       confirmed: confirmed),
                                      returning: DaemonAPI.WorktreeRemoved.self)
        } catch {
            problem = sentence(for: error)
        }
        await loadProjectWorktrees(in: folder)
    }

    private func startRefusalBeforeSending(in folder: URL) -> String? {
        if isStale { return "Your Mac is not answering, so nothing was started." }
        guard let summary = work.project(folder) else { return nil }
        if summary.project.isArchived { return "This project was archived on the Mac, so nothing was started." }
        if !summary.exists { return "This project's folder is not on the Mac any more, so nothing was started." }
        if let runtime = startRuntime, let reason = runtime.unavailableReason {
            return "\(runtime.runtime.name) cannot start: \(reason)"
        }
        return nil
    }

    private func sentence(for error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? "Your Mac did not answer."
    }

    // MARK: The Mac's runtimes (029)

    /// Every runtime the Mac knows, in the Mac's order, startable or not. The start
    /// sheet lists the ones that cannot start too, with why, because a runtime that
    /// silently is not there reads as one the phone forgot.
    private(set) var runtimes: [RuntimeStatus] = []
    private var accounts: [String: RuntimeAccount] = [:]

    var availableRuntimeIDs: [String] {
        runtimes.filter(\.availability.isAvailable).map(\.runtime.id)
    }

    /// What this runtime says it will take in a prompt, as the Mac reads it. Nothing
    /// is refused on a guess: unknown is the protocol's baseline.
    func promptCapabilities(for runtimeID: String?) -> ACP.PromptCapabilities {
        runtimeID.flatMap { accounts[$0]?.promptCapabilities } ?? ACP.PromptCapabilities()
    }

    /// A project's counts from the same grouping its page uses, so the list and the
    /// page cannot disagree about what needs attention.
    func counts(in folder: URL?) -> [AgentGroup: Int] { work.counts(in: folder) }

    /// Whether the Mac is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

    /// "Started by …" for an agent another agent started, and nil otherwise (028).
    func startedByAgentLabel(_ agent: Agent) -> String? { work.startedByAgentLabel(agent) }

    /// Whether the menu offers Stop: the same answer the Mac gives.
    func canStop(_ agent: Agent) -> Bool { work.canStop(agent) }

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
                if notification.method == DaemonAPI.Notification.draftOptions,
                   let change = try? notification.params?.decode(DaemonAPI.DraftOptionsNotification.self) {
                    self.settleStartDraft(change)
                }
                if notification.method == DaemonAPI.Notification.runtimeChanged {
                    await self.refreshRuntimes()
                }
                if notification.method == DaemonAPI.Notification.runtimeAccountChanged,
                   let account = try? notification.params?.decode(RuntimeAccount.self) {
                    self.accounts[account.runtimeID] = account
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
        await refreshRuntimes()
        await refreshModes()
        await settleUnsettledStart()
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
        selectedProject = agent.projectFolder
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

    /// The mode last chosen for each runtime, on any device. `modes/changed` keeps it
    /// current afterwards. A Mac too old to know the method leaves the sheet opening
    /// on each runtime's own current mode.
    private func refreshModes() async {
        guard let modes = try? await client.call(DaemonAPI.Method.modesRemembered, Optional<Int>.none,
                                                 returning: DaemonAPI.RememberedModes.self) else { return }
        work.replaceRememberedModes(modes)
    }

    private func refreshRuntimes() async {
        if let listed = try? await client.call(DaemonAPI.Method.runtimesList,
                                               Optional<String>.none,
                                               returning: [RuntimeStatus].self) {
            runtimes = listed
        }
        if let listed = try? await client.call(DaemonAPI.Method.runtimesAccounts,
                                               Optional<Int>.none,
                                               returning: [RuntimeAccount].self) {
            accounts = Dictionary(uniqueKeysWithValues: listed.map { ($0.runtimeID, $0) })
        }
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

    /// Say something to an agent that already exists, with whatever goes with it.
    ///
    /// Answers whether it went, so the prompt bar can keep what was typed when it did
    /// not. A prompt that could not be delivered and was cleared from the field anyway
    /// is the worst outcome here: the person believes they asked, and nothing did.
    ///
    /// An agent mid-turn is not refused — the daemon queues it and gets to it after
    /// this turn. That is the daemon's rule and it is deliberately not second-guessed
    /// from here. What is attached is checked first, by the same rules as a start from
    /// the phone (029): nothing the runtime cannot take, and nothing too big for the link.
    func send(_ what: String, attachments: [Attachment] = [], to agentID: UUID) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that was not sent."
            return false
        }
        let capabilities = promptCapabilities(for: work.agent(agentID)?.runtimeID)
        if let refused = attachments.lazy.compactMap({ PhoneAttachment.refusal(for: $0, from: capabilities) }).first {
            problem = refused
            return false
        }
        if let tooMuch = PhoneAttachment.totalRefusal(attachments) {
            problem = tooMuch
            return false
        }
        do {
            try await client.call(DaemonAPI.Method.agentsPrompt,
                                  DaemonAPI.PromptRequest(agentID: agentID, text: what,
                                                          attachments: attachments))
            return true
        } catch {
            problem = "That did not reach your Mac. What you typed is still there."
            return false
        }
    }

    /// Back to the end of the conversation, as the Mac does when a prompt goes.
    func scrollToEnd() { scrollToEndToken += 1 }

    // MARK: The agent's own controls (033)

    /// What an option control should read. The same bookkeeping as the Mac's, in the
    /// kit, so a choice made here shows at once and settles the same way.
    func chosenOption(_ optionID: String, for agent: Agent, advertised: ConfigOption) -> JSONValue? {
        work.chosenOption(optionID, for: agent, advertised: advertised)
    }

    /// Change one of a running agent's options, from the phone. Not `async`, so the
    /// choice is on the control as the menu closes.
    func setOption(agentID: UUID, optionID: String, value: JSONValue) {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        let sequence = work.beginOption(agentID: agentID, optionID: optionID, value: value)
        Task {
            do {
                try await client.call(DaemonAPI.Method.agentsSetOption,
                                      DaemonAPI.SetOptionRequest(agentID: agentID, optionID: optionID, value: value))
            } catch {
                problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
            }
            work.settleOption(agentID: agentID, optionID: optionID, sequence: sequence)
        }
    }

    /// What the controls row shows for an agent that exists. Its options came with it,
    /// so there is nothing to load.
    func controlsState(for agent: Agent) -> PromptControlsState {
        PromptControlsState.resolve(agentOptions: agent.advertisedOptions,
                                    draftOptions: [],
                                    hasFolder: true,
                                    hasRuntime: true,
                                    runtimeName: PromptWords.runtimeName(agent.runtimeID),
                                    isLoading: false,
                                    failure: nil)
    }

    /// Let this one agent carry on past its limit: one more step of its ceiling, the
    /// same step the Mac takes. No other agent is changed.
    func letThisAgentGoOn(_ agent: Agent) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        do {
            let changed = try await client.call(
                DaemonAPI.Method.agentsSetCeiling,
                DaemonAPI.SetCeilingRequest(agentID: agent.id, ceiling: agent.ceilingToGoOn(under: costLimits)),
                returning: Agent.self)
            work.upsert(changed)
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// Files under the agent's folders for what follows an `@`, found on the Mac.
    /// Empty when the Mac is not answering: an empty list is not a problem to show.
    func mentions(_ term: String, for agentID: UUID) async -> [FileMention] {
        guard !isStale, !term.isEmpty else { return [] }
        let found = try? await client.call(DaemonAPI.Method.filesMention,
                                           DaemonAPI.FileMentionRequest(agentID: agentID, term: term),
                                           returning: [DaemonAPI.FileMentionDTO].self)
        return (found ?? []).map(\.mention)
    }

    /// Take something back off the queue before it goes (033). The same call the Mac
    /// makes; the row goes on both when the daemon says the agent changed.
    func unqueue(_ prompt: QueuedPrompt, from agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be taken back."
            return
        }
        do {
            try await client.call(DaemonAPI.Method.agentsUnqueue,
                                  DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id))
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// What a command an agent ran has printed, as far as this phone heard it.
    func terminalOutput(_ terminalID: String) -> String { work.terminalOutput[terminalID] ?? "" }

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
            // `-start` opens New agent on that project: the sheet is the one screen in
            // this app that cannot be reached by naming what to look at.
            if arguments.contains("-start") {
                try? await Task.sleep(for: .milliseconds(600))
                startingIn = summary.folder
            }
        }
        if let title = value("-agent"),
           let agent = work.agents.first(where: { $0.title == title }) {
            selectedProject = agent.projectFolder
            // A beat, so the project has been pushed before the conversation is. Two
            // pushes in one turn of the loop is not something to ask of a split view.
            try? await Task.sleep(for: .milliseconds(600))
            selection = agent.id
        }
    }
#endif
}
