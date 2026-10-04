import SwiftUI
import UIKit
import WidgetKit
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
    private var labelVocabularies: [URL: [String]] = [:]

    /// Whether the Mac is answering, and when it last did.
    private(set) var isConnected = false
    /// Which way the Mac is being reached (046): on its own network, or through iCloud.
    /// The fake and the old single link are always direct.
    private(set) var link: RemoteLink = .direct
    /// What is getting in the relay's way, when anything is (046, FR-014).
    private(set) var relayTrouble: RelayTrouble?
    private(set) var lastHeardFrom: Date?
    private(set) var problem: String?
    /// A send refused because the agent's folder has gone (#119), with the ways on.
    var folderGone: FolderGoneAsk?

    /// Which project is being looked at. Not the daemon's business: it owns what is
    /// true about the work, and which of it somebody happens to be reading is not that.
    var selectedProject: URL? {
        didSet {
            guard selectedProject != oldValue else { return }
            selection = nil
            openWorkflow = nil
            openDashboard = false
            letGoOfProjects(keeping: selectedProject)
        }
    }

    /// The conversation open, if any. Set by the push, cleared by the back button.
    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            work.watching = selection
            presence?.watching(selection)
            letGoOfChats(keeping: selection)
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
    private let deviceID = RemoteModel.deviceID

    nonisolated static var deviceID: UUID {
        let key = "device.id"
        if let text = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
    /// This device's key, made once and kept in this device's keychain. The Mac only
    /// ever sees the public half.
    private let key: DeviceKey? = try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup)
    /// The mailbox's subscriptions are saved once per launch, the first time the Mac
    /// answers the announce.
    private var subscribed = false
    /// This device, as the Mac has it: `nil` until the Mac has answered the announce.
    private(set) var thisDevice: Device?
    private var listening: Task<Void, Never>?
    /// The loop looking for the Mac, so two of them never run at once; what a send lost
    /// with the connection waits on, for at most `sendPatience` (#208); stopped for good
    /// by a new pairing.
    @ObservationIgnored private lazy var reconnect = ReconnectLoop(backoff: backoff) { [weak self] in
        guard let self else { return .forgotten }
        // Lost again while this attempt was still settling in: `lostTouch` found this
        // loop running and left it to go round once more.
        if await self.tryOnce(), self.isConnected { return .connected }
        // Forgotten: nothing to dial until a new pairing starts a loop of its own (#81).
        if self.forgottenByControlPlane { return .forgotten }
        note("link: no answer; waiting before the next try")
        return .failed
    }
    private var isLoadingEarlier = false
    /// What the pages on screen show, and what has been read on this connection (#175).
    @ObservationIgnored private var parts = OnScreenParts()
    /// The catch-up under way, so a pull to refresh during a reconnect waits for it
    /// rather than starting a second.
    @ObservationIgnored private var catchingUp: Task<Void, Never>?
    /// The first page of live agents was full: the rest come a project at a time, as each
    /// project's page opens.
    @ObservationIgnored private var moreLiveAgents = false
    @ObservationIgnored private var filledProjects: Set<URL> = []

    /// The agent's files as the Mac reads them, and where each agent's pane is (034).
    let files: RemoteFiles
    let panes = RemotePanes()
    let pictures: PhonePictures
    /// This device's end of each agent's shell it has opened (034). The shell is the
    /// Mac's; these only know how to reach it.
    @ObservationIgnored private var shells: [UUID: ShellClient] = [:]
    /// When this device last asked to warm each session, and why (#183).
    @ObservationIgnored private var prewarmed: [String: Date] = [:]

    func shellClient(for agentID: UUID) -> ShellClient {
        if let existing = shells[agentID] { return existing }
        let fresh = ShellClient(agentID: agentID, client: client, describe: { error in
            (error as? JSONRPCError)?.message ?? "Your Mac is not answering."
        })
        shells[agentID] = fresh
        return fresh
    }


    /// The link the Mac is reached by, kept so a second connection can be made over it
    /// to a control plane's other hosts (058, US4).
    @ObservationIgnored private let baseLink: any DaemonLink
    /// Every host a control plane has besides the one this phone paired with, each with
    /// a client of its own over one more connection (058, US4). Empty against a bridge
    /// with no control plane.
    @ObservationIgnored private var otherHosts: [HostID: DaemonClient] = [:]
    @ObservationIgnored private var hostWatch: Task<Void, Never>?
    /// What `hosts/list` last said, so the project list can name each host (058, frame H).
    /// Empty when this phone is not a client of a control plane.
    private(set) var controlHosts: [DaemonAPI.ControlHost] = []
    /// The host this phone's own connection reaches. Its projects are stamped `.mac`.
    private(set) var controlHome: HostID?

    init(link: any DaemonLink) {
        baseLink = link
        client = DaemonClient(link: link)
        files = RemoteFiles(client: client)
        pictures = PhonePictures(files: files)
        // The oldest of a long conversation go from the page as it runs on; what they
        // say the agent touched is kept with the rest of the history read for Files.
        work.onTrimmed = { [weak self] dropped in
            guard let self, let agentID = work.watching else { return }
            for entry in dropped { touchedEarlier[agentID, default: TouchedPaths()].absorb(entry) }
        }
        work.onOversized = { [weak self] agentID, entryID, index in
            Task { await self?.loadOversized(entryID, of: agentID, at: index) }
        }
    }

    /// Away, and slower (046): what the screens read to show the Away line and to put
    /// the terminal, the live page and files behind "needs the same network".
    var isAway: Bool { link == .relayed }

    /// Nothing to reach the control plane with: never paired, or forgotten (FR-009).
    var needsPairing: Bool { baseLink is NotPairedLink || forgottenByControlPlane }

    /// The control plane refused this device's key: forgotten, or never known (058, US5).
    private(set) var forgottenByControlPlane = false

    /// Where a pairing started from the scanner has got to.
    enum Pairing: Equatable {
        case idle
        case pairing
        case paired
        case failed(String)
    }

    private(set) var pairing: Pairing = .idle

    /// Set once this phone has paired with a control plane: the app makes a new model on
    /// that link (058, US5).
    private(set) var pairedWithControlPlane = false

    /// Pair with the control plane whose device code was just scanned (058, US5):
    /// announced over its WebSocket.
    func pair(scanned text: String) async {
        if let control = ControlCode(text: text), control.url != nil {
            guard case .client = control.purpose else {
                pairing = .failed("That code is for adding a host, not a phone.")
                return
            }
            pairing = .pairing
            do {
                let id = deviceID
                _ = try await PairingAttempt.run { try await RemoteControl.pair(with: control, id: id) }
                pairing = .paired
                note("pairing: paired with the control plane \(control.name)")
                pairedWithControlPlane = true
            } catch {
                note("pairing: failed: \(error)")
                // The same words as the Mac's Connect… sheet (#84).
                pairing = .failed(PairingAttempt.sentence(for: error, device: "this \(UIDevice.current.model)"))
            }
            return
        }
        pairing = .failed("That isn't a pairing code from your control plane. Show a new one in Settings ▸ Control plane and scan it again.")
    }

    func forgetPairingOutcome() {
        pairing = .idle
    }

    /// Put what the person typed on a page on disk, through the daemon, which is the one
    /// writer and the one that tells the agent (022). The same request the Mac's page
    /// makes, so a phone's edit is the person's in exactly the same way (034 FR-006).
    /// Answers why it did not land, or nil.
    func writeArtifact(agentID: UUID, path: String, text: String) async -> String? {
        guard !isStale else { return "Your Mac is not answering. What you typed is kept here." }
        do {
            try await client.call(DaemonAPI.Method.artifactWrite,
                                  DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text))
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return "Your Mac is not answering. What you typed is kept here."
        }
    }

    /// The Mac predates the panes, and the phone does what it did before them (FR-029).
    var macLacksPanes: Bool { files.macLacksPanes }

    // MARK: What the screens read

    var projects: [DaemonAPI.ProjectSummary] { work.liveProjects }

    /// One host's heading in the project list. Several hosts, and the list is grouped
    /// under these; one host, and there is no heading, as on the Mac (058, frame H).
    struct HostSection: Identifiable {
        /// The id projects from this host are stamped with. The phone's own Mac is
        /// `.mac`, whichever id the control plane gave that host.
        var id: HostID
        var title: String
        var offline: Bool
    }

    var hostSections: [HostSection] {
        guard controlHosts.count > 1, let home = controlHome else { return [] }
        let homeRecord = controlHosts.first { $0.id == home }
        var sections = [HostSection(id: .mac, title: "This Mac",
                                    offline: homeRecord?.state == "offline")]
        for host in controlHosts where host.id != home && host.id != .mac {
            sections.append(HostSection(id: host.id, title: host.name.isEmpty ? host.id.rawValue : host.name,
                                        offline: host.state == "offline"))
        }
        return sections
    }

    /// Whether `host`'s projects are last known rather than current (frame H greys them).
    func hostIsOffline(_ host: HostID) -> Bool {
        hostSections.first { $0.id == host }?.offline ?? false
    }
    /// Archived ones too, for the spending page. A project put away still cost what it
    /// cost, and a grand total that quietly dropped it would be wrong rather than tidy.
    /// The archived ones are fetched when that page opens (`loadArchivedProjects`).
    var allProjects: [DaemonAPI.ProjectSummary] {
        let held = Set(work.projects.map(\.folder))
        return work.projects + archivedProjects.filter { !held.contains($0.folder) }
    }
    /// The open project's standing arrangements.
    var workflows: [WorkflowSummary] { work.workflows(in: selectedProject) }

    /// The workflow whose page is open, if one is. Its id rather than a copy, for the
    /// Mac page's reason: the file is the truth, and a copy would show what it used to
    /// say. Pushed under the conversation, so a run opened from its page comes back to it.
    var openWorkflow: Workflow.ID?
    /// Whether the project's Dashboard (074) is pushed over the project page.
    var openDashboard = false
    /// The project's pinned page (#159) pushed over the project page, by its path in it.
    var openPin: String?
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

    /// The project a New session sheet is open on, if one is. On the model rather than in
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
    /// The new agent's own sandbox choice (064). Nil follows its runtime's default.
    var startSandbox: SandboxChoice?
    /// Each runtime's sandbox default, read from the Mac, for "Use runtime default (Off)".
    private(set) var sandboxSettings = SandboxSettings()
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

    /// What the sheet reads: the runtimes to choose from, and, for its runtime menu, what
    /// the Mac's allowances say, before it is opened rather than after whoever happens to
    /// visit the Runtimes page.
    private static let startParts: Set<CatchUpPart> = [.runtimes, .allowances, .modes, .sandbox]

    private func openStart(in folder: URL) async {
        startRefusal = nil
        startWorktree = nil
        startWorktrees = .notARepository
        Task { await loadStartWorktrees(in: folder) }
        if !startShowsParts {
            startShowsParts = true
            await showing(Self.startParts)
        }
        guard startingIn == folder else { return }
        if startRuntimeID == nil || !availableRuntimeIDs.contains(startRuntimeID ?? "") {
            startRuntimeID = work.defaultRuntimeID(available: availableRuntimeIDs)
        }
        await loadStartChoices()
    }

    /// Put the sheet away. Its runtime is let go; what was typed is the keeper's.
    @ObservationIgnored private var startShowsParts = false

    private func closeStart() {
        if startShowsParts {
            startShowsParts = false
            notShowing(Self.startParts)
        }
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
        startSandbox = nil
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
    func startAgent(prompt: String, attachments: [Attachment] = [], labels: [String] = []) async -> Bool {
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
            worktree: startWorktree, requestID: retrying ?? UUID(), sandbox: startSandbox,
            labels: labels)
        return await send(start: request)
    }

    func setLabels(on id: UUID, add: [String] = [], remove: [String] = []) async -> Bool {
        do {
            let agent: Agent = try await client.call(
                DaemonAPI.Method.agentsSetLabels,
                DaemonAPI.SetLabelsRequest(agentID: id, add: add, remove: remove),
                returning: Agent.self)
            work.upsert(agent)
            await loadLabelVocabulary(in: agent.projectFolder)
            return true
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That label change did not reach your Mac."
            return false
        }
    }

    func labelSuggestions(in folder: URL) -> [String] {
        labelVocabularies[Project.standardize(folder)]
            ?? SessionLabelPolicy.vocabulary(in: folder, agents: work.agents).map(\.value)
    }

    func loadLabelVocabulary(in folder: URL) async {
        let folder = Project.standardize(folder)
        guard let values = try? await client.call(
            DaemonAPI.Method.agentsLabelVocabulary,
            DaemonAPI.LabelVocabularyRequest(folder: folder), returning: [String].self) else { return }
        labelVocabularies[folder] = values
    }

    private func send(start request: DaemonAPI.StartRequest) async -> Bool {
        isStarting = true
        defer { isStarting = false }
        startRefusal = nil
        unsettledStart = request
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsStart, request).decode(UUID.self)
            await started(id, in: request.cwd)
            return true
        } catch let refused as JSONRPCError {
            // The Mac said no, so nothing was started under this id and a later
            // Send is a fresh start.
            unsettledStart = nil
            startRefusal = refused.message
            // Its sandbox would not start (064): what it said, and the way on.
            if refused.code == DaemonAPI.Failure.sandboxWillNotStart,
               let why = try? refused.data?.decode(DaemonAPI.SandboxWillNotStart.self) {
                startRefusal = refused.message + " " + (why.detail.split(separator: "\n").first.map(String.init) ?? "")
                    + (why.offOffered ? " Set Sandbox to Off to start without it." : "")
            }
            return false
        } catch {
            // Out of patience too (#208): the sheet is let go, and the start is settled
            // when the host is back, by its `requestID`.
            startRefusal = "\(hostName(of: error) ?? "Your Mac") stopped answering before it said whether the agent "
                + "started. This will be checked when it is back."
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
        await refreshSnapshot()
        startingIn = nil
        selectedProject = folder
        openWorkflow = nil
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

    /// Whether this runtime said it takes words in the middle of a turn.
    func canSteer(_ runtimeID: String?) -> Bool {
        runtimeID.flatMap { accounts[$0]?.canSteer } ?? false
    }

    /// A project's counts from the same grouping its page uses, so the list and the
    /// page cannot disagree about what needs attention.
    func counts(in folder: URL?) -> [AgentGroup: Int] { work.counts(in: folder) }
    func counts(in key: ProjectKey) -> [AgentGroup: Int] { work.counts(in: key) }

    /// Whether the Mac is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

    /// "Started by …" for an agent another agent started, and nil otherwise (028).
    func startedByAgentLabel(_ agent: Agent) -> String? { work.startedByAgentLabel(agent) }

    /// Whether the menu offers Stop: the same answer the Mac gives.
    func canStop(_ agent: Agent) -> Bool { work.canStop(agent) }
    func blockLines(_ agent: Agent) -> [String] { work.blockLines(agent) }
    func isBlocked(_ agent: Agent) -> Bool { work.openBlock(agent) != nil }
    /// End a block by hand (039), as the person. See the Mac's `carryOn`.
    func carryOn(_ agentID: UUID) async { _ = await send(Block.carryOnPrompt, to: agentID) }

    /// The question the open conversation is blocked on, if it still is.
    var questionsForSelection: [PermissionRequest] { work.permissions(for: selection) }

    /// The form it is blocked on instead, if it is one of those.
    ///
    /// The two never share the screen, and the permission wins where both somehow
    /// exist: it is the one the runtime is most likely to be sitting on, and two
    /// blocking cards at once on a phone is a card nobody can read.
    var formForSelection: ElicitationRequest? {
        questionsForSelection.isEmpty ? work.elicitation(for: selection) : nil
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

    // MARK: Which files the agent changed (034)

    /// What the agent touched in the part of its conversation before the page loaded,
    /// per agent. Fetched once, when Files first opens for it.
    private var touchedEarlier: [UUID: TouchedPaths] = [:]
    private var touchedHistoryAsked: Set<UUID> = []

    /// The files an agent changed since it started, as the Mac marks them: from the
    /// transcript, never the disk (FR-011). The page of it that is loaded, plus what was
    /// read of the rest when Files opened.
    func touchedPaths(for agentID: UUID) -> TouchedPaths {
        var touched = touchedEarlier[agentID] ?? TouchedPaths()
        if selection == agentID { for entry in work.entries { touched.absorb(entry) } }
        return touched
    }

    /// Read the part of the conversation the chat has not loaded, once, so a file the
    /// agent edited an hour ago is marked here as it is on the Mac (research §5). Paged,
    /// backwards, as "load earlier" is; kept apart from the chat's own page.
    func loadTouchedHistory(for agentID: UUID) async {
        guard !touchedHistoryAsked.contains(agentID) else { return }
        touchedHistoryAsked.insert(agentID)
        var before: Int? = selection == agentID ? work.firstEntryIndex : nil
        if before == 0 { return }
        while true {
            guard let page = try? await client.call(
                DaemonAPI.Method.agentsTranscript,
                DaemonAPI.TranscriptRequest(agentID: agentID, before: before, limit: 500),
                returning: TranscriptPage.self) else {
                // Try again next time Files opens; the marks are short, not wrong.
                touchedHistoryAsked.remove(agentID)
                break
            }
            // Added to what is there rather than replacing it: entries trimmed off the
            // page while this was reading are already in it, and came after these.
            for entry in page.entries { touchedEarlier[agentID, default: TouchedPaths()].absorb(entry) }
            guard page.hasMoreBefore else { break }
            before = page.firstIndex
        }
    }

    /// Something is being typed on this device: the prompt, a passage on a page, the
    /// terminal. While it is, an agent asking to be looked at is offered, not opened,
    /// so the screen is not taken from under somebody's fingers (034 FR-005).
    var isTyping = false

    /// Open what the agent asked for, and take it off the model so it is asked once.
    /// "Look at this" is about a moment, and the moment has passed by the next launch.
    ///
    /// Where it opens is the Mac's answer (034 FR-004): a Markdown file on the Page, any
    /// other file in Files at the line. A Mac without the panes gets today's sheet.
    /// While the person is typing it is left where it is, and the chat offers it.
    func openFileTheAgentWants() {
        guard !isTyping, let selection, let file = work.takeFileToShow(for: selection) else { return }
        open(file, for: selection)
    }

    /// The strip's Open, which the person chose, typing or not.
    func openOfferedFile() {
        guard let selection, let file = work.takeFileToShow(for: selection) else { return }
        open(file, for: selection)
    }

    /// The strip's ✕: not now. Taken off, as an opened one would be.
    func dismissOfferedFile() {
        guard let selection else { return }
        _ = work.takeFileToShow(for: selection)
    }

    /// A plan being approved, reopened from its question card: the same page the
    /// daemon opened when it was asked.
    func openPlan(_ file: ShownFile) {
        guard let selection else { return }
        open(file, for: selection)
    }

    private func open(_ file: ShownFile, for agentID: UUID) {
        if macLacksPanes {
            fileOnScreen = file.path
        } else {
            let state = panes.state(for: agentID)
            // An agent showing a page means the page (#67).
            if HTMLPageScope.isHTML(file.url) { state.htmlShowsSource = false }
            state.open(file: file.url, line: file.line)
        }
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
    ///
    /// Backing off to half a minute between tries, so a phone in a pocket with no Mac to
    /// find is not holding the radio open every second all afternoon. A model whose
    /// pairing was replaced is stopped, and never looks again (#208).
    func connect() async {
        guard !reconnect.isStopped, !reconnect.isRunning else { return }
        note("link: looking for the Mac")
        networkChanges.start()
        await reconnect.run()
    }

    /// How long the loop waits before the next attempt, and the wait itself, which coming
    /// back to the app or a network change cuts short (#82); and the other hosts' watch's.
    @ObservationIgnored private let backoff = Backoff()
    @ObservationIgnored private let otherHostsBackoff = Backoff(first: .seconds(5), longest: .seconds(60))
    @ObservationIgnored private var checkingConnection = false
    @ObservationIgnored private lazy var networkChanges = ReconnectTriggers { [weak self] reason in
        Task { @MainActor in await self?.goBackNow(reason) }
    }

    /// The app came to the front, or the network changed (#82). A phone that was in a
    /// pocket may have been half a minute into a back-off, or holding a connection that
    /// died while it was suspended; either way, look now. A try already in flight is
    /// left alone.
    private func goBackNow(_ reason: ReconnectTriggers.Reason) async {
        guard !reconnect.isStopped else { return }
        note("link: \(reason); connected \(isConnected), reconnecting \(reconnect.isRunning)")
        otherHostsBackoff.nudge()
        guard backoff.nudge() == .idle, isConnected, !reconnect.isRunning, !checkingConnection else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        if await !client.answers(within: .seconds(4)) {
            note("link: no answer after \(reason); letting go")
            // The listener hears the connection close and reconnects.
            await client.disconnect()
        }
    }

    /// Whether a refusal is believed yet (#81).
    @ObservationIgnored private var refusals = RefusalPatience()

    /// How long each call that catches up after connecting is given.
    static let catchUpPatience = Duration.seconds(20)

    private func tryOnce() async -> Bool {
        let began = ContinuousClock.now
        do {
            try await client.connect(startIfNeeded: false)
            // Stopped while dialling: a new pairing has the screen, and this one lets go.
            guard !reconnect.isStopped else {
                await client.disconnect()
                return false
            }
            note("link: connected \(link) after \(ContinuousClock.now - began)")
            refusals.connected()
            isConnected = true
            lastHeardFrom = Date()
            problem = nil
            listen()
            // Each call here with a deadline: this runs inside the reconnect loop, and a
            // reply lost to a Mac restarting left the loop, and so the app, waiting for
            // good while it looked connected (073).
            await DaemonClient.$patience.withValue(Self.catchUpPatience) {
                await announce()
                await identify()
            }
            startPresence()
            presence?.connected()
            if link == .relayed { relayTrouble = nil }
            await DaemonClient.$patience.withValue(Self.catchUpPatience) {
                await files.reconnected()
                await catchUp()
            }
            watchOtherHosts()
            note("link: settled after \(ContinuousClock.now - began); still connected \(isConnected)")
            return true
        } catch {
            note("link: attempt failed after \(ContinuousClock.now - began): \(error)")
            if let reason = ControlPlaneLink.refused.take(), refusals.forgets(after: reason) {
                note("link: forgotten by the control plane (\(reason))")
                // Forgotten from a window, or unknown for minutes on end: this device asks
                // for a new code, and stops dialling. One "unknown" alone is a control plane
                // that could not tell yet, and is dialled again (#81).
                RemoteControl.forget()
                forgottenByControlPlane = true
                isConnected = false
                return false
            }
            isConnected = false
            return false
        }
    }

    // MARK: A control plane's other hosts (058, US4)

    /// The client a call belongs to: another host's for an agent or a folder there,
    /// this phone's own host's for everything else. Worked out from what the call names,
    /// so no call site has to know there is more than one host.
    ///
    /// Another host this phone cannot reach now is `HostAway` at once: the call used to
    /// go to the home host, which could mean a whole catch-up there before failing
    /// anyway (#208).
    private func client(for params: some Encodable) throws -> DaemonClient {
        guard let host = otherHost(named: params) else { return client }
        guard let other = otherHosts[host], reachableHosts.contains(host) else { throw HostAway(host: host) }
        return other
    }

    /// The host other than this phone's own that a call names, by its agent or its folder.
    private func otherHost(named params: some Encodable) -> HostID? {
        guard !controlHosts.isEmpty, let value = try? JSONValue.encoding(params) else { return nil }
        if let id = (value["agentID"] ?? value["id"])?.stringValue.flatMap(UUID.init(uuidString:)),
           let host = work.agent(id)?.host, host != .mac {
            return host
        }
        for key in ["folder", "cwd"] {
            guard let folder = value[key]?.stringValue else { continue }
            if let project = work.projects.first(where: { $0.folder.absoluteString == folder && $0.host != .mac }) {
                return project.host
            }
        }
        return nil
    }

    /// Another of the control plane's hosts, not reachable from here now (#208).
    struct HostAway: Error {
        let host: HostID
    }

    /// The home host did not come back within `sendPatience` (#208).
    struct MacAway: Error {}

    /// The other hosts this phone has a live connection to now (058, #208): an agent on
    /// one that is not is stale on its own, whatever the home host is doing.
    private(set) var reachableHosts: Set<HostID> = []

    /// Whether what is shown of `host`'s work can be trusted, and acted on: the home host's
    /// staleness for its own, that host's link for another's (#208).
    func isStale(on host: HostID) -> Bool {
        host == .mac ? isStale : !reachableHosts.contains(host)
    }

    func isStale(_ agent: Agent) -> Bool { isStale(on: agent.host) }

    /// Ask whether a control plane is on the other end, and follow its other hosts if so.
    /// A bridge with no control plane answers `control/status` with methodNotFound, and
    /// nothing more happens.
    ///
    /// Holds the model only for each step, never for the whole watch: a model let go (a
    /// new pairing) ends its watch rather than being kept dialling by it (#175). `stop`
    /// ends it at once.
    private func watchOtherHosts() {
        guard hostWatch == nil, !reconnect.isStopped else { return }
        let client = client
        // Through the relay a device has one session at a time (046), and it is the
        // home host's: the other hosts wait until the control plane's address answers.
        let base: any DaemonLink = (baseLink as? ControlPlaneLink)?.addressOnly ?? baseLink
        let backoff = otherHostsBackoff
        hostWatch = Task { [weak self] in
            guard (try? await client.call(DaemonAPI.Method.controlStatus)) != nil else {
                self?.hostWatch = nil
                return
            }
            let link = ControlLink { try await base.transport() }
            let control = DaemonClient(link: link.controlLink)
            defer { Task { await control.disconnect() } }
            while !Task.isCancelled, self != nil {
                backoff.trying()
                if (try? await control.connect(startIfNeeded: false, timeout: .seconds(5))) != nil {
                    backoff.connected()
                    await self?.syncOtherHosts(control, link: link)
                    for await change in control.notifications() where change.method == DaemonAPI.Notification.controlHostChanged {
                        guard let self, !Task.isCancelled else { return }
                        // A host back while this phone waits out its backoff: go back now (#172).
                        if !self.isConnected, change.params?["state"]?.stringValue == "online" { self.backoff.nudge() }
                        await self.syncOtherHosts(control, link: link)
                    }
                    note("hosts: the control plane's watch closed")
                }
                guard !Task.isCancelled, self != nil else { return }
                await backoff.wait()
            }
        }
    }

    /// Everything this model dials, ended for good: a new pairing has made a new model
    /// (#175). Stopped first, so nothing below starts a loop again: the listener's end,
    /// a network change, a send (#208).
    func stop() async {
        note("link: stopping this pairing's connections")
        reconnect.stop()
        networkChanges.stop()
        (baseLink as? ControlPlaneLink)?.watching.stop()
        hostWatch?.cancel()
        hostWatch = nil
        listening?.cancel()
        listening = nil
        for (_, other) in otherHosts { await other.disconnect() }
        otherHosts = [:]
        reachableHosts = []
        await client.disconnect()
    }

    private func syncOtherHosts(_ control: DaemonClient, link: ControlLink) async {
        guard let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self),
              let listed = try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        else { return }
        controlHosts = listed.filter { $0.relay != true }
        controlHome = status.homeHost
        // The relay's key, from the control plane itself (T077): kept for when its address
        // cannot be reached.
        RemoteControl.keepRelayKey(status.relayKey)
        let others = listed.filter { $0.id != status.homeHost && $0.state == "online" && $0.relay != true }
        for host in others {
            let other = otherHosts[host.id] ?? DaemonClient(link: link.link(for: host.id))
            otherHosts[host.id] = other
            if await other.isConnected { continue }
            reachableHosts.remove(host.id)
            guard (try? await other.connect(startIfNeeded: false, timeout: .seconds(5))) != nil else { continue }
            let id = host.id
            reachableHosts.insert(id)
            if let projects = try? await other.call(DaemonAPI.Method.projectsList,
                                                    DaemonAPI.ProjectsListRequest(includeArchived: false),
                                                    returning: [DaemonAPI.ProjectSummary].self) {
                work.replaceProjects(projects, from: id)
            }
            if let agents = try? await other.listAgents(DaemonAPI.ListRequest(includeArchived: false, lean: true)) {
                work.replaceAgents(agents, from: id)
            }
            let notes = other.notifications()
            let shown = work.shown
            // Read off the main actor, once, and applied there (#203).
            Task.detached(priority: .userInitiated) { [weak self] in
                for await note in notes {
                    guard let update = AgentsModel.read(note.method, note.params, showing: shown.id) else { continue }
                    await self?.work.apply(update, from: id)
                }
                // Its connection ended: its cards are stale until the watch reaches it again.
                await MainActor.run { [weak self] in
                    if self?.otherHosts[id] === other { self?.reachableHosts.remove(id) }
                }
            }
            // A new connection is a new record there: where the person is, and what is open.
            presence?.connected()
        }
        // A host that went offline keeps its projects, greyed under its heading (frame H).
        // One the control plane no longer lists is gone, and so is what it showed.
        for id in otherHosts.keys where !others.contains(where: { $0.id == id }) {
            reachableHosts.remove(id)
            await otherHosts.removeValue(forKey: id)?.disconnect()
            if !listed.contains(where: { $0.id == id }) {
                work.replaceProjects([], from: id)
                work.replaceAgents([], from: id)
            }
        }
    }

    private func listen() {
        listening?.cancel()
        let notifications = client.notifications()
        let shown = work.shown
        // Detached, so that each notification is decoded once, off the main actor, and
        // only what it means is applied there, in the order the Mac said them (#203).
        // An entry or terminal output for another chat is not read past its agentID.
        listening = Task.detached(priority: .userInitiated) { [weak self] in
            for await notification in notifications {
                let update = AgentsModel.read(notification.method, notification.params, showing: shown.id)
                guard let self else { return }
                await self.received(notification, update)
            }
            // Cancelled is not lost: a newer listener took over, or the model was stopped,
            // and either way this one's end is not a reason to go back (#208).
            guard !Task.isCancelled else { return }
            await self?.lostTouch()
        }
    }

    private func received(_ notification: (method: String, params: JSONValue?), _ update: AgentsModel.Update?) {
        self.lastHeardFrom = Date()
        var updated: Agent?
        if case .agentChanged(let agent)? = update { updated = agent }
        let previousLabels = updated.flatMap { self.work.agent($0.id)?.labels }
        var removedProject: URL?
        if case .agentRemoved(let removed)? = update { removedProject = self.work.agent(removed.agentID)?.projectFolder }
        // Anything the shared model does not claim is the Mac's own — shells,
        // terminals — and a remote has no business with it.
        if let update { self.work.apply(update) }
        // Nothing below waits on the network: one slow answer would hold every
        // notification after it (#175). What needs asking is asked beside the loop.
        if let updated, previousLabels != updated.labels,
           self.labelVocabularies[updated.projectFolder] != nil {
            self.reloadLabelVocabulary(in: updated.projectFolder)
        }
        if let removedProject, self.labelVocabularies[removedProject] != nil {
            self.reloadLabelVocabulary(in: removedProject)
        }
        if Self.attentionNotifications.contains(notification.method) {
            self.publishAttentionSoon()
        }
        if case .attention(let change)? = update {
            self.toNotifier { [deviceID = self.deviceID] notifier in
                await notifier.apply(change, me: .device(deviceID))
            }
        }
        if notification.method == DaemonAPI.Notification.draftOptions,
           let change = try? notification.params?.decode(DaemonAPI.DraftOptionsNotification.self) {
            self.settleStartDraft(change)
        }
        // The Mac sends a device only the shells it has open (034).
        if notification.method == DaemonAPI.Notification.shellOutput,
           let params = notification.params,
           let output = DaemonAPI.ShellOutputNotification(params: params),
           output.shell == 0 {
            self.shells[output.agentID]?.received(output.bytes)
        }
        if notification.method == DaemonAPI.Notification.shellStateChanged,
           let change = try? notification.params?.decode(DaemonAPI.ShellStateNotification.self),
           change.shell == 0 {
            self.shells[change.agentID]?.received(change.state)
        }
        if notification.method == DaemonAPI.Notification.filesChanged,
           let change = try? notification.params?.decode(DaemonAPI.FilesChangedNotification.self) {
            self.files.apply(change)
        }
        if notification.method == DaemonAPI.Notification.sandboxChanged,
           let settings = try? notification.params?.decode(SandboxSettings.self) {
            self.sandboxSettings = settings
        }
        if notification.method == DaemonAPI.Notification.runtimeChanged, self.parts.changed(.runtimes) {
            self.reloadRuntimes()
        }
        // The Mac could not keep something nobody was waiting on (#88).
        if notification.method == DaemonAPI.Notification.writeFailed,
           let failure = try? notification.params?.decode(WriteFailure.self) {
            self.problem = failure.message
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

    /// The Mac stopped answering. Say so, keep what is on screen, and go back for it.
    private func lostTouch() async {
        guard !reconnect.isStopped else { return }
        note("link: lost touch")
        isConnected = false
        parts.connectionLost()
        listening = nil
        await connect()
    }

    // MARK: Beside the notification loop (#175)

    @ObservationIgnored private var labelsReloading: Set<URL> = []
    @ObservationIgnored private var runtimesReloading = false
    /// The banners, in the order the Mac said: each waits for the one before.
    @ObservationIgnored private var notifierTail: Task<Void, Never>?
    @ObservationIgnored private var attentionPublishing: Task<Void, Never>?

    /// One reload per folder at a time; a change while one is under way is in its answer.
    private func reloadLabelVocabulary(in folder: URL) {
        guard labelsReloading.insert(folder).inserted else { return }
        Task {
            await loadLabelVocabulary(in: folder)
            labelsReloading.remove(folder)
        }
    }

    private func reloadRuntimes() {
        guard !runtimesReloading else { return }
        runtimesReloading = true
        Task {
            await refreshRuntimes()
            runtimesReloading = false
        }
    }

    private func toNotifier(_ work: @escaping @MainActor (DeviceNotifier) async -> Void) {
        let before = notifierTail
        let notifier = notifier
        notifierTail = Task {
            await before?.value
            await work(notifier)
        }
    }

    /// The widget's file written once for a burst of notifications, not once for each.
    private func publishAttentionSoon() {
        guard attentionPublishing == nil else { return }
        attentionPublishing = Task {
            try? await Task.sleep(for: .milliseconds(500))
            attentionPublishing = nil
            publishAttention()
        }
    }

    /// A call that changes something, sent so that it happens once even if the link
    /// changes under it (046, FR-003). Its params carry the id the Mac dedups — a send's
    /// `sendID`, a start's `requestID` — or it is one the Mac can safely do twice (stop,
    /// archive). A call lost with the connection is sent once more, unchanged, as soon
    /// as the Mac is back.
    ///
    /// Every wait in it is bounded (#208). The call is held only while the host answers
    /// pings; the wait for the Mac to come back is at most `sendPatience`, and none at
    /// all from inside the reconnect loop's own catching up, which would be the loop
    /// waiting on itself. Out of patience it is `MacAway`: the caller keeps what was
    /// typed, and the person's retry is the same send. A call to another host whose
    /// link went is `HostAway` at once: that host's watch brings it back, not this
    /// phone's own reconnect.
    @discardableResult
    private func sendOnce(_ method: String, _ params: some Encodable & Sendable) async throws -> JSONValue {
        let client = try client(for: params)
        let patience = Self.sendPatience
        do {
            return try await client.callWhileAnswering(method, params, checkingEvery: patience)
        } catch is JSONRPCTransportError {
        } catch DaemonClient.ConnectError.couldNotConnect {
        }
        guard client === self.client else {
            if let host = otherHost(named: params) {
                reachableHosts.remove(host)
                throw HostAway(host: host)
            }
            throw MacAway()
        }
        guard await reconnect.waitForHost(within: patience) else {
            note("link: \(method) not sent; the Mac did not come back in \(patience)")
            throw MacAway()
        }
        return try await client.callWhileAnswering(method, params, checkingEvery: patience)
    }

    /// How long a send waits for the Mac to come back, and between its pings while it
    /// waits for an answer (#208).
    static let sendPatience = catchUpPatience

    /// Catch up with the Mac: after every connection, and on a pull to refresh (#175).
    ///
    /// Only what is on screen: the projects, the first page of live agents and what is
    /// waiting on a person in one call, then the open chat, then whatever the pages on
    /// screen show. The rest is read when a page that shows it opens. One at a time, and
    /// one catch-up at a time: a pull during a reconnect waits for the reconnect's.
    func catchUp() async {
        if let running = catchingUp {
            await running.value
            return
        }
        let running = Task { await runCatchUp() }
        catchingUp = running
        await running.value
        catchingUp = nil
    }

    private func runCatchUp() async {
        let began = ContinuousClock.now
        let plan = parts.plan(chat: selection)
        for step in plan.steps {
            switch step {
            case .snapshot: await refreshSnapshot()
            case .chat: await loadTranscript()
            case .part(let part): await load(part)
            }
        }
        // The low-disk strip is under the banner on every page (#196), so it is read
        // on every catch-up, not when a page asks for it.
        await refreshDisk()
        await settleUnsettledStart()
        settleSelection()
        // Once the counts have landed, so the widget's number is this refresh's number.
        publishAttention()
        if let pendingOpen { open(pendingOpen) }
        note("catch-up: \(plan.steps.count) steps (\(plan.parts.map(\.rawValue).sorted().joined(separator: ", "))) "
             + "in \(ContinuousClock.now - began)")
    }

    /// Projects, the first page of live agents, and what waits on a person: one call to a
    /// host that knows `client/catchUp`, one per part to one that does not.
    private func refreshSnapshot() async {
        let snapshot: DaemonAPI.CatchUpSnapshot
        do {
            snapshot = try await client.catchUp()
        } catch {
            note("catch-up: the snapshot failed: \(error)")
            return
        }
        work.replaceProjects(snapshot.projects, from: .mac)
        takeLiveAgents(snapshot.agents, page: DaemonAPI.CatchUpRequest.firstPage)
        work.replacePermissions(snapshot.permissions)
        work.replaceElicitations(snapshot.elicitations)
        work.replaceAttention(snapshot.attention)
        work.setResuming(snapshot.resuming)
        toNotifier { [deviceID = self.deviceID] notifier in await notifier.sweep(keeping: snapshot.attention, me: .device(deviceID)) }
        if let selectedProject { await fillProject(selectedProject) }
    }

    /// A page showing `parts` appeared: read the ones not read on this connection.
    func showing(_ shown: Set<CatchUpPart>) async {
        let unread = parts.appeared(shown)
        for part in CatchUpPart.allCases where unread.contains(part) {
            await load(part)
        }
    }

    func notShowing(_ shown: Set<CatchUpPart>) {
        parts.disappeared(shown)
    }

    private func load(_ part: CatchUpPart) async {
        switch part {
        case .workflows: await refreshWorkflows()
        case .pins: await refreshPins()
        case .dashboards: await refreshDashboardSummaries()
        case .leases: await refreshLeases()
        case .runtimes: await refreshRuntimes()
        case .allowances: await refreshRuntimeAllowances()
        case .modes: await refreshModes()
        case .sandbox: await refreshSandboxSettings()
        case .costs: await refreshCostState()
        }
    }

    // MARK: Where this device is (021)

    /// The app came to the front or went behind. `.active` is foreground and unlocked,
    /// which is what "in the person's hands" means on a device.
    func scenePhase(_ phase: ScenePhase) {
        presence?.scenePhase(phase)
        if phase == .active {
            Task {
                await goBackNow(.wake)
                await refreshAttention()
                // A silent push is best effort, so a need that moved while the app was
                // shut may have been missed; the model is now as true as it can be.
                publishAttention()
            }
        }
    }

    private var kind: Device.Kind {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: .iPhone
        case .pad: .iPad
        default: .unknown
        }
    }

    /// `devices/announce`: who this is, once per connection, so the Mac's record of it
    /// keeps its name and when it was last seen. Pairing is the scanned code
    /// (`pair(scanned:)`); on a paired device's own link this only updates the record.
    private func announce() async {
        guard let key else { return }
        do {
            let reply = try await client.call(
                DaemonAPI.Method.devicesAnnounce,
                DaemonAPI.DeviceAnnouncement(id: deviceID, publicKey: key.publicKey,
                                             name: UIDevice.current.name, kind: kind),
                returning: DaemonAPI.AnnounceReply.self)
            thisDevice = reply.device
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
            // The relay's wake-up (046): a push when the Mac writes to this device's
            // zone, so a relayed session looks at once. Polling still works without it.
            if RemoteControl.relayKey != nil {
                do {
                    try await CloudKitRelayChannel().subscribe(device: deviceID)
                    note("relay: subscribed")
                } catch {
                    note("relay: subscribe failed: \(error)")
                }
            }
        }
    }

    // MARK: A push arrived (021 T077, T079)

    /// A silent push: a need moved here without a buzz, moved away, or was met. The
    /// loud ones never come here — `RemoteNotify` turns those into banners before the
    /// system shows them. Everything this does is to local notifications, and it
    /// decides nothing about where the need belongs.
    func receivedPush(_ userInfo: [AnyHashable: Any]) async {
        // What kind of push, never its payload: that is the person's work (#175).
        note("push: \(CloudKitRelayChannel.isRelayPush(userInfo) ? "relay wake-up" : "mailbox")")
        // The relay's wake-up: a relayed session polls, so there is nothing to poke.
        if CloudKitRelayChannel.isRelayPush(userInfo) { return }
        guard let pushed = CloudKitMailbox.pushed(from: userInfo) else { return }
        // A need has moved here or away, which is the one thing the widget counts.
        publishAttention()
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
        // A banner is about the agent, not whatever page was open over the project.
        openWorkflow = nil
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

    // MARK: The Home-screen widget (068)

    /// Write the file the widget reads, and redraw it if what it says has changed.
    ///
    /// A widget cannot reach the daemon. WidgetKit loads the extension on demand and
    /// kills it without warning, so what it is given has to be something that is already
    /// on disk, and this is the only writer of it (FR-014). Built from the model the
    /// Remote already holds, so the number on the Home screen is the number the Dock
    /// badge shows: the same sum over the same live projects.
    ///
    /// A push is also what tells the app something moved, so this runs on those too
    /// rather than waiting for the person to open the app.
    func publishAttention() {
        let snapshot = AttentionSnapshot.make(model: work, at: Date())
        guard AttentionSnapshotStore.write(snapshot, over: lastPublished) else { return }
        lastPublished = snapshot
        WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
    }

    /// What was last written for the widget, so the file is not read back each time.
    @ObservationIgnored private var lastPublished: AttentionSnapshot?

    /// The notifications that can move the number. The Mac sends a great deal more than
    /// this — a shell printing, a file changing, a runtime's status — and a widget does
    /// not redraw for any of those.
    private static let attentionNotifications: Set<String> = [
        DaemonAPI.Notification.agentChanged,
        DaemonAPI.Notification.projectChanged,
        DaemonAPI.Notification.attentionChanged,
        DaemonAPI.Notification.agentPermission,
        DaemonAPI.Notification.agentElicitation,
    ]

    /// A tap on the widget: `agents://attention` for the body, `agents://agent/<id>` for
    /// a row.
    ///
    /// A body is showing one number over several projects, so it goes to the first
    /// project with something waiting, and to the projects page when nothing is waiting
    /// or the app was launched cold and has not heard about any projects yet. A row
    /// names one agent, and `open(_:)` already knows how to get there.
    func openedFromTheWidget(_ url: URL) {
        switch AttentionLink.parse(url) {
        case .agent(let id):
            open(id)
            // A row drawn a few minutes ago can name a session that has gone since, and
            // a tap that names nothing left must not look like a tap that did nothing.
            // `open` has kept the id, so the conversation still opens if the agents are
            // merely late; a project is shown until then.
            if work.agent(id) == nil { showTheFirstProjectNeedingYou() }
        case .attention:
            showTheFirstProjectNeedingYou()
        case nil:
            break
        }
    }

    /// The projects page, with the first project that has somebody waiting already open.
    private func showTheFirstProjectNeedingYou() {
        openWorkflow = nil
        selection = nil
        selectedProject = work.liveProjects.first(where: needsYou)?.project.folder
    }

    /// Whether anything in a project is waiting on a person: the same sum the widget
    /// shows, asked of one project. Counted from this model's own grouping, which is the
    /// one that knows whether a person has looked at an agent, and not the counts the
    /// daemon sent.
    private func needsYou(_ summary: DaemonAPI.ProjectSummary) -> Bool {
        work.attentionCount(in: summary.project.folder) > 0
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
        let reporter = PresenceReporter { [weak self] watching, active, mayNotify, showing in
            guard let self else { return }
            // Every host hears whether the person is here; only the open chat's host hears
            // which it is, and that is where its entries and output come from (#203).
            let owner = showing.map { self.work.agent($0)?.host ?? .mac }
            func report(for host: HostID) -> DaemonAPI.PresenceReport {
                DaemonAPI.PresenceReport(watching: owner == host ? watching : nil, active: active,
                                         mayNotify: mayNotify, showing: owner == host ? showing : nil)
            }
            _ = try? await self.client.call(DaemonAPI.Method.presenceReport, report(for: .mac))
            for (id, other) in self.otherHosts where self.reachableHosts.contains(id) {
                _ = try? await other.call(DaemonAPI.Method.presenceReport, report(for: id))
            }
        }
        presence = reporter
    }

    private func refreshAttention() async {
        guard let pending = try? await client.call(DaemonAPI.Method.attentionPending,
                                                   Optional<String>.none,
                                                   returning: DaemonAPI.AttentionPending.self) else { return }
        work.replaceAttention(pending)
        toNotifier { [deviceID = self.deviceID] notifier in await notifier.sweep(keeping: pending, me: .device(deviceID)) }
    }

    /// The live agents only, the first page of them. Archived ones outnumber them many
    /// times over and are almost never looked at, so they come when a page asks for them
    /// — a project's Archived section, a workflow's runs — and not on every connection.
    private func refreshAgents() async {
        // Lean: no card or row reads the option and command lists, which were nearly all of
        // each record (#107). The open chat's come with `loadWholeAgent`.
        let page = DaemonAPI.CatchUpRequest.firstPage
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, page, returning: [Agent].self)
        else { return }
        takeLiveAgents(listed, page: page)
        if let selectedProject { await fillProject(selectedProject) }
    }

    /// The first page of live agents, in place of what was held. Archived agents already
    /// fetched are kept only where a screen can still show them: the open project, and an
    /// open archived chat (#175). One brought back while this phone was away is in the live
    /// list, and that copy wins.
    private func takeLiveAgents(_ listed: [Agent], page: DaemonAPI.ListRequest) {
        moreLiveAgents = page.next(after: listed) != nil
        filledProjects = []
        let live = Set(listed.map(\.id))
        let letGo = Set(ClientHolding.archivedToLetGo(work.agents, project: selectedProject, chat: selection))
        // Only this host's: another host's agents come from that host (058, US4).
        let kept = work.agents.filter {
            $0.host == .mac && $0.state == .archived && !live.contains($0.id) && !letGo.contains($0.id)
        }
        work.replaceAgents(listed + kept, from: .mac)
    }

    /// The rest of a project's live agents, when the first page did not hold them all:
    /// asked as its page opens, once per connection.
    func fillProject(_ folder: URL) async {
        guard moreLiveAgents, filledProjects.insert(folder).inserted else { return }
        let request = DaemonAPI.ListRequest(includeArchived: false, folder: folder, lean: true)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request, returning: [Agent].self)
        else {
            filledProjects.remove(folder)
            return
        }
        work.takeListed(listed)
    }

    /// A project page has gone: what only it could show is let go (#175). Its archived
    /// agents, its label suggestions, and the live agents beyond the first page that it
    /// filled in.
    private func letGoOfProjects(keeping folder: URL?) {
        work.forget(ClientHolding.archivedToLetGo(work.agents, project: folder, chat: selection))
        labelVocabularies = labelVocabularies.filter { $0.key == folder.map(Project.standardize) }
        if let folder { Task { await fillProject(folder) } }
    }

    /// A chat has gone: what was read for it alone is let go (#175). Its earlier marks
    /// for Files, and an archived chat outside the open project.
    private func letGoOfChats(keeping agentID: UUID?) {
        touchedEarlier = touchedEarlier.filter { $0.key == agentID }
        touchedHistoryAsked = touchedHistoryAsked.filter { $0 == agentID }
        work.forget(ClientHolding.archivedToLetGo(work.agents, project: selectedProject, chat: agentID))
    }

    /// The newest `limit` archived agents in a project, for its Archived section when
    /// it is opened. Without their slash commands: an archived chat has no prompt bar
    /// here to use them.
    /// What is left of an agent that has been retired, when something here leads to an
    /// agent the Mac no longer lists (051). Remembered once found.
    func lookUpRetired(_ agentID: UUID) async {
        guard work.agent(agentID) == nil, work.tombstones[agentID] == nil,
              let found = try? await client.call(DaemonAPI.Method.agentsRetired,
                                                 DaemonAPI.RetiredRequest(ids: [agentID]),
                                                 returning: [Tombstone].self) else { return }
        work.takeTombstones(found)
    }

    func loadArchivedAgents(in folder: URL, limit: Int) async {
        let request = DaemonAPI.ListRequest(archivedCommands: false, archivedOnly: true,
                                            folder: folder, limit: limit, lean: true)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return }
        work.takeListed(listed)
    }

    func loadAllArchivedAgents(in folder: URL) async {
        let request = DaemonAPI.ListRequest(archivedCommands: false, archivedOnly: true,
                                            folder: folder, lean: true)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return }
        work.takeListed(listed)
    }

    /// A workflow's newest `limit` runs, archived ones included, for its page. Answers
    /// whether there are more than that.
    func loadRuns(of workflowID: String, in folder: URL, limit: Int) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedCommands: false, folder: folder,
                                            startedByWorkflow: workflowID, limit: limit + 1, lean: true)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return false }
        work.takeListed(Array(listed.prefix(limit)))
        return listed.count > limit
    }

    /// Archived projects, for Spending only: what they cost still counts. Asked for when
    /// that page opens.
    private(set) var archivedProjects: [DaemonAPI.ProjectSummary] = []

    func loadArchivedProjects() async {
        guard let listed = try? await client.call(DaemonAPI.Method.projectsList,
                                                  DaemonAPI.ProjectsListRequest(includeArchived: true),
                                                  returning: [DaemonAPI.ProjectSummary].self)
        else { return }
        archivedProjects = listed.filter(\.project.isArchived)
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

    // MARK: The pool (052)

    func agent(_ id: UUID) -> Agent? { work.agent(id) }


    /// Every runtime's state on the Mac (065, US4).
    var runtimeAllowances: RuntimeAllowances? { work.runtimeAllowances }

    func refreshRuntimeAllowances() async {
        guard let allowances = try? await client.call(DaemonAPI.Method.runtimesAllowances, Optional<String>.none,
                                                      returning: RuntimeAllowances.self) else { return }
        work.replaceRuntimeAllowances(allowances)
    }

    /// The person says a runtime is back. The phone may: it costs one turn if wrong.
    func markRuntimeAvailable(_ credentialKey: String) async {
        guard let allowances = try? await client.call(DaemonAPI.Method.runtimesMarkAvailable,
                                                      DaemonAPI.MarkRuntimeAvailable(credentialKey: credentialKey),
                                                      returning: RuntimeAllowances.self) else { return }
        work.replaceRuntimeAllowances(allowances)
    }

    /// Assess a runtime (#47) in a project on the Mac: the daemon starts an agent on it with
    /// the assessment's steps. Nil when it started; the daemon's refusal if not.
    func assessRuntime(_ runtimeID: String, in folder: URL) async -> String? {
        do {
            _ = try await client.call(DaemonAPI.Method.runtimesAssess,
                                      DaemonAPI.AssessRuntimeRequest(runtimeID: runtimeID, folder: folder),
                                      returning: DaemonAPI.AssessRuntimeResult.self)
            return nil
        } catch {
            return (error as? JSONRPCError)?.message ?? error.localizedDescription
        }
    }

    /// What each agent holds and waits for (036). The phone only reads it: the
    /// Resources page and ending a lease are the Mac's (FR-011).
    private func refreshLeases() async {
        guard let snapshot = try? await client.call(DaemonAPI.Method.leasesSnapshot,
                                                    Optional<String>.none,
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    /// Every volume on the Mac low on space (#196), for the strip under the banner. A Mac
    /// too old to know the method leaves it empty, and no strip is drawn.
    private func refreshDisk() async {
        guard let state = try? await client.call(DaemonAPI.Method.diskState, Optional<String>.none,
                                                 returning: DiskState.self) else { return }
        work.replaceDisk(state)
    }

    /// The newest events and who is waiting (042). The phone only reads them.
    func refreshEvents(_ filter: EventFilter? = nil) async {
        let filter = filter ?? work.eventsFilter
        work.eventsFilter = filter
        guard let page = try? await client.call(DaemonAPI.Method.eventsList, DaemonAPI.EventsListRequest(filter),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, for: filter)
    }

    /// The page before the oldest event the phone has, for scrolling back.
    func loadOlderEvents() async {
        let filter = work.eventsFilter
        guard work.moreEvents, let oldest = work.recentEvents.last?.position else { return }
        guard let page = try? await client.call(DaemonAPI.Method.eventsList,
                                                DaemonAPI.EventsListRequest(before: oldest, filter),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, for: filter, appending: true)
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

    // MARK: Pinned pages (#159)

    func pins(in folder: URL?) -> [PinView] { work.pins(in: folder) }

    func refreshPins() async {
        guard let listed = try? await client.call(DaemonAPI.Method.pinsList, DaemonAPI.Empty(),
                                                  returning: [ProjectPins].self) else { return }
        work.replacePins(listed)
    }

    /// A file of the project's: a pinned page, a page tile's, or what an HTML page draws.
    func readPage(_ path: String, in folder: URL, known: FileStamp? = nil) async throws -> FileReading {
        try await client.call(DaemonAPI.Method.pinsRead,
                              DaemonAPI.PinReadRequest(folder: folder, path: path, knownStamp: known),
                              returning: FileReading.self)
    }

    /// What the person typed on a pinned Markdown page. Why it was not saved, or nil.
    func writePage(_ path: String, in folder: URL, text: String) async -> String? {
        do {
            try await client.call(DaemonAPI.Method.pinsWrite, DaemonAPI.PinWriteRequest(folder: folder, path: path, text: text))
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    func pin(_ path: String, in folder: URL) async {
        do {
            let pins = try await client.call(DaemonAPI.Method.pinsPin, DaemonAPI.PinRequest(folder: folder, path: path),
                                             returning: [PinView].self)
            work.setPins(pins, in: folder)
        } catch {
            problem = sentence(for: error)
        }
    }

    func unpin(_ path: String, in folder: URL) async {
        work.setPins(pins(in: folder).filter { $0.path != path }, in: folder)
        if openPin == path { openPin = nil }
        do {
            try await client.call(DaemonAPI.Method.pinsUnpin, DaemonAPI.PinPathRequest(folder: folder, path: path))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// A Move item or a drag in Edit: shown at once, then the whole order sent once.
    func arrangePins(_ paths: [String], in folder: URL) async {
        let held = pins(in: folder)
        work.setPins(paths.compactMap { path in held.first { $0.path == path } }, in: folder)
        do {
            try await client.call(DaemonAPI.Method.pinsArrange, DaemonAPI.PinArrangeRequest(folder: folder, paths: paths))
        } catch {
            problem = sentence(for: error)
        }
    }

    // MARK: Pinned sessions (#180)

    func pinnedSessions(in folder: URL?) -> [UUID] { work.pinnedSessions(in: folder) }

    func isPinned(_ agent: Agent) -> Bool {
        pinnedSessions(in: agent.projectFolder).contains(agent.id)
    }

    /// Pin or Unpin from a card's menu or swipe: shown at once, then the Mac told.
    func setPinned(_ agent: Agent, _ pinned: Bool) async {
        let folder = agent.projectFolder
        let held = pinnedSessions(in: folder).filter { $0 != agent.id }
        work.setSessionPins(pinned ? held + [agent.id] : held, in: folder)
        do {
            try await client.call(pinned ? DaemonAPI.Method.pinsPinSession : DaemonAPI.Method.pinsUnpinSession,
                                  DaemonAPI.PinSessionRequest(folder: folder, agentID: agent.id))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Move Up or Move Down among the pinned sessions: shown at once, the order sent once.
    func arrangeSessionPins(_ ids: [UUID], in folder: URL) async {
        work.setSessionPins(ids, in: folder)
        do {
            try await client.call(DaemonAPI.Method.pinsArrangeSessions,
                                  DaemonAPI.PinArrangeSessionsRequest(folder: folder, agentIDs: ids))
        } catch {
            problem = sentence(for: error)
        }
    }

    // MARK: The Dashboard (074)

    func refreshDashboardSummaries() async {
        guard let listed = try? await client.call(DaemonAPI.Method.dashboardSummaries, DaemonAPI.Empty(),
                                                  returning: [DashboardSummary].self) else { return }
        work.replaceDashboardSummaries(listed)
    }

    func refreshDashboard(_ folder: URL) async {
        guard let snapshot = try? await client.call(DaemonAPI.Method.dashboardGet,
                                                    DaemonAPI.DashboardRequest(folder: folder),
                                                    returning: DashboardSnapshot.self) else { return }
        work.store(snapshot)
    }

    /// Hide, Show or Remove: every client may (FR-029).
    func actOnTile(_ method: String, folder: URL, id: String) async {
        do {
            try await client.call(method, DaemonAPI.TileRequest(folder: folder, id: id))
        } catch {
            problem = sentence(for: error)
        }
        await refreshDashboard(folder)
    }

    /// Update now (#146): the Mac runs the dashboard workflow, or a one-off agent, and
    /// says why when it won't.
    func updateDashboard(_ folder: URL) async {
        do {
            try await client.call(DaemonAPI.Method.dashboardUpdate, DaemonAPI.DashboardRequest(folder: folder))
        } catch {
            problem = sentence(for: error)
        }
        await refreshDashboard(folder)
    }

    /// A Move menu item (#147): shown at once, then the whole order sent once.
    func arrangeDashboard(_ order: DashboardOrder, folder: URL) async {
        let key = Project.standardize(folder)
        if var snapshot = work.dashboards[key] {
            snapshot.order = order
            work.store(snapshot)
        }
        do {
            try await client.call(DaemonAPI.Method.dashboardArrange, DaemonAPI.ArrangeRequest(folder: folder, order: order))
        } catch {
            problem = sentence(for: error)
        }
        await refreshDashboard(folder)
    }

    /// A tile's keeper: its conversation, or its workflow's page (FR-030).
    func openKeeper(_ keeper: KeeperView, folder: URL) {
        switch keeper.kind {
        case .agent:
            if let id = UUID(uuidString: keeper.id) { selection = id }
        case .workflow:
            openWorkflow = Project.standardize(folder).path + "/" + keeper.id
        }
    }

    // MARK: Driving a workflow

    /// Run one now. The Mac still applies the in-flight, ceiling and archive rules and
    /// says so on the summary, which is why nothing here second-guesses it first.
    func runWorkflow(_ summary: WorkflowSummary) async {
        do {
            try await client.call(DaemonAPI.Method.workflowsRun,
                                  DaemonAPI.WorkflowRequest(folder: summary.folder,
                                                            workflowID: summary.workflowID))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Put one away, or bring it back. `workflow/changed` redraws the page.
    func setWorkflowArchived(_ summary: WorkflowSummary, _ archived: Bool) async {
        do {
            try await client.call(DaemonAPI.Method.workflowsArchive,
                                  DaemonAPI.WorkflowArchiveRequest(folder: summary.folder,
                                                                   workflowID: summary.workflowID,
                                                                   archived: archived))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Let a waiting one run as its file now reads (#142): the digest is what the page
    /// was showing, so a file changed since is still waiting afterwards.
    func approveWorkflow(_ summary: WorkflowSummary) async {
        guard let waiting = summary.awaitingApproval else { return }
        do {
            let updated: WorkflowSummary = try await client.call(
                DaemonAPI.Method.workflowsApprove,
                DaemonAPI.WorkflowApproveRequest(folder: summary.folder, workflowID: summary.workflowID,
                                                 digest: waiting.digest),
                returning: WorkflowSummary.self)
            work.upsert(updated)
        } catch {
            problem = sentence(for: error)
            await refreshWorkflows()
        }
    }

    /// Turn one on or off, keeping its place on the list (#100).
    func setWorkflowEnabled(_ summary: WorkflowSummary, _ enabled: Bool) async {
        do {
            try await client.call(DaemonAPI.Method.workflowsEnable,
                                  DaemonAPI.WorkflowEnableRequest(folder: summary.folder,
                                                                  workflowID: summary.workflowID,
                                                                  enabled: enabled))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Change what a workflow is allowed to do. The Mac's daemon writes the file and
    /// answers with what it now says; a refusal has to reach the person, and the list
    /// is asked again so the menu goes back to what the file still holds (FR-025).
    func setWorkflowSettings(_ summary: WorkflowSummary, _ settings: WorkflowSettings,
                             labels: [String]? = nil) async {
        do {
            let updated: WorkflowSummary = try await client.call(
                DaemonAPI.Method.workflowsSettings,
                DaemonAPI.WorkflowSettingsRequest(folder: summary.folder,
                                                  workflowID: summary.workflowID,
                                                  settings: settings, labels: labels),
                returning: WorkflowSummary.self)
            work.upsert(updated)
        } catch {
            problem = sentence(for: error)
            await refreshWorkflows()
        }
    }

    /// What a runtime last advertised for a folder, for the workflow page's menus.
    /// Empty is an answer: nothing has been remembered for it there yet.
    func rememberedOptions(runtimeID: String, cwd: URL) async -> [ConfigOption] {
        (try? await client.call(DaemonAPI.Method.optionsRemembered,
                                DaemonAPI.RememberedOptionsRequest(runtimeID: runtimeID, cwd: cwd),
                                returning: [ConfigOption].self)) ?? []
    }

    /// The mode last chosen for each runtime, on any device. `modes/changed` keeps it
    /// current afterwards. A Mac too old to know the method leaves the sheet opening
    /// on each runtime's own current mode.
    private func refreshModes() async {
        guard let modes = try? await client.call(DaemonAPI.Method.modesRemembered, Optional<Int>.none,
                                                 returning: DaemonAPI.RememberedModes.self) else { return }
        work.replaceRememberedModes(modes)
    }

    /// A Mac too old to know the method leaves every runtime as configured, which is
    /// what it does.
    private func refreshSandboxSettings() async {
        guard let settings = try? await client.call(DaemonAPI.Method.sandboxState, Optional<String>.none,
                                                    returning: SandboxSettings.self) else { return }
        sandboxSettings = settings
    }

    /// One agent's own sandbox choice from the phone (064); nil follows the default.
    func setAgentSandbox(_ agentID: UUID, _ choice: SandboxChoice?) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        do {
            try await client.call(DaemonAPI.Method.agentsSetSandbox,
                                  DaemonAPI.SetSandboxRequest(agentID: agentID, choice: choice))
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    /// The sandbox card's answer, from the phone (064, FR-007a).
    func answerSandbox(_ agentID: UUID, carryOn: Bool) async {
        do {
            try await client.call(DaemonAPI.Method.agentsAnswerSandbox,
                                  DaemonAPI.AnswerSandboxRequest(agentID: agentID, carryOn: carryOn))
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    private func refreshRuntimes() async {
        if let listed = try? await client.call(DaemonAPI.Method.runtimesList,
                                               Optional<String>.none,
                                               returning: [RuntimeStatus].self) {
            runtimes = RuntimeCatalog.sortedByName(listed)
        }
        if let listed = try? await client.call(DaemonAPI.Method.runtimesAccounts,
                                               Optional<Int>.none,
                                               returning: [RuntimeAccount].self) {
            accounts = Dictionary(uniqueKeysWithValues: listed.map { ($0.runtimeID, $0) })
        }
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

    /// The open chat's record whole, with the menus and plan a lean list leaves out (#107).
    /// A Mac too old to know `agentID` lists its newest instead, which is not this one.
    func loadWholeAgent(_ id: UUID) async {
        let request = DaemonAPI.ListRequest.whole(id)
        guard let listed = try? await client(for: request).call(DaemonAPI.Method.agentsList, request,
                                                                returning: [Agent].self),
              var whole = listed.first(where: { $0.id == id }) else { return }
        whole.host = work.agent(id)?.host ?? whole.host
        work.takeListed([whole])
    }

    func loadTranscript() async {
        guard let selection else { work.clearTranscript(); return }
        // Beside the transcript rather than before it, and not cancelled by its returns.
        Task { await loadWholeAgent(selection) }
        // The finished turns as summaries, then the turn in progress. A Mac too old to
        // keep turns gives the lot. Both from the chat's own host (058).
        let turnsRequest = DaemonAPI.TurnsRequest(agentID: selection)
        let turns = (try? await client(for: turnsRequest).call(DaemonAPI.Method.agentsTurns, turnsRequest,
                                                               returning: TurnsPage.self))
            ?? TurnsPage(turns: [], firstTurn: 0, openStart: 0)
        let request = DaemonAPI.TranscriptRequest(agentID: selection, limit: firstPageSize, from: turns.openStart)
        guard let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                              returning: TranscriptPage.self) else { return }
        // A chat left before its page arrived does not get that page shown under the
        // next one's name.
        guard self.selection == selection else { return }
        work.replaceTurns(with: turns)
        work.replaceTranscript(with: page)
    }

    /// An entry its host sent as a stub, too big to send to every chat (#203), read here.
    func loadOversized(_ entryID: UUID, of agentID: UUID, at index: Int?) async {
        let request = DaemonAPI.TranscriptRequest.around(index, of: agentID)
        guard let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                              returning: TranscriptPage.self),
              let entry = page.entries.first(where: { $0.id == entryID }) else { return }
        work.fillOversized(entry, for: agentID)
    }

    /// A finished turn's entries, for the chat to open it: the last page of them when
    /// the turn is longer than a host gives in one answer (#200).
    func turnEntries(_ agentID: UUID, _ range: Range<Int>) async -> [TranscriptEntry] {
        let request = DaemonAPI.TranscriptRequest(agentID: agentID, before: range.upperBound,
                                                  limit: min(range.count, DaemonAPI.TranscriptRequest.limitCeiling),
                                                  from: range.lowerBound)
        let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                        returning: TranscriptPage.self)
        return page?.entries ?? []
    }

    /// Another page, backwards. Never the whole history: that is the difference
    /// between a conversation opening in a second and one opening on a train.
    func loadEarlier() async {
        guard let selection, work.hasMoreOfTheConversation, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        // Past the start of the turn in progress, the turns before it.
        if !work.hasMoreBefore {
            let turnsRequest = DaemonAPI.TurnsRequest(agentID: selection, before: work.firstTurn)
            guard let turns = try? await client(for: turnsRequest).call(
                DaemonAPI.Method.agentsTurns, turnsRequest, returning: TurnsPage.self),
                self.selection == selection else { return }
            work.prependTurns(turns)
            return
        }
        let request = DaemonAPI.TranscriptRequest(agentID: selection, before: work.firstEntryIndex,
                                                  limit: firstPageSize, from: work.openTurnStart)
        guard let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
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
            try await sendOnce(DaemonAPI.Method.permissionsAnswer,
                               DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID,
                                                       sendID: UUID()))
            return true
        } catch {
            problem = away(error, "that could not be sent.") ?? "That question could not be answered."
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
            try await sendOnce(DaemonAPI.Method.elicitationsAnswer,
                               DaemonAPI.AnswerElicitationRequest(requestID: request.id, action: action,
                                                                  content: content, sendID: UUID()))
            return true
        } catch {
            // The daemon refuses an answer that does not fit the shape the agent asked
            // for, and says why. Its words, not ours: it knows which field was wrong.
            problem = (error as? JSONRPCError)?.message ?? away(error, "that could not be sent.")
                ?? "That question could not be answered."
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
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
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
            try await sendOnce(DaemonAPI.Method.agentsPrompt,
                               DaemonAPI.PromptRequest(agentID: agentID, text: what,
                                                       attachments: attachments, sendID: UUID()))
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.couldNotSave {
            // It reached the Mac, which could not write it down (#88).
            problem = error.message + " What you typed is still there."
            return false
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.folderGone {
            // Its folder has gone (#119): said with the ways on, carrying what was typed.
            folderGone = FolderGoneAsk(agentID: agentID, message: error.message, text: what,
                                       attachments: attachments)
            return false
        } catch {
            problem = (away(error, "that was not sent.") ?? "That did not reach your Mac.") + " What you typed is still there."
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
            let request = DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id)
            try await client(for: request).call(DaemonAPI.Method.agentsUnqueue, request)
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// Stop one shell an agent left running, and nothing else it is doing (057). The
    /// row goes when the daemon says the agent changed.
    func stopBackground(_ item: BackgroundItem, of agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be stopped."
            return
        }
        do {
            let request = DaemonAPI.StopBackgroundRequest(agentID: agentID, itemID: item.id)
            try await client(for: request).call(DaemonAPI.Method.agentsStopBackground, request)
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// Send a queued prompt into the turn that is running, where the runtime takes one.
    /// Once: the row shows it going, and a second tap is not a second send (#87).
    func sendNow(_ prompt: QueuedPrompt, to agentID: UUID) async {
        await act(.sendNow(prompt.id), on: agentID,
                  DaemonAPI.Method.agentsSendNow,
                  DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id))
    }

    /// What a command an agent ran has printed, as far as this phone heard it.
    func terminalOutput(_ terminalID: String) -> String { work.terminalOutput[terminalID] ?? "" }

    func stop(_ agentID: UUID) async {
        await act(.stop, on: agentID, DaemonAPI.Method.agentsStop, DaemonAPI.AgentRequest(agentID: agentID))
    }
    func archive(_ agentID: UUID) async {
        await act(.archive, on: agentID, DaemonAPI.Method.agentsArchive, DaemonAPI.AgentRequest(agentID: agentID))
    }

    /// Continue in the project folder (#119): a successor that reads this session and
    /// carries on, with whatever was typed, opened once the Mac has started it.
    @discardableResult
    func continueInProject(_ agentID: UUID, text: String = "", attachments: [Attachment] = []) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        let folder = work.agent(agentID)?.projectFolder
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsContinueInProject,
                                        DaemonAPI.ContinueInProjectRequest(agentID: agentID, text: text,
                                                                           attachments: attachments,
                                                                           requestID: UUID())).decode(UUID.self)
            await refreshAgents()
            if let folder { selectedProject = folder }
            selection = id
            return true
        } catch let error as JSONRPCError {
            problem = error.message
            return false
        } catch {
            problem = "That did not reach your Mac."
            return false
        }
    }

    /// Recreate the worktree from its branch (#119).
    func recreateWorktree(_ agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await sendOnce(DaemonAPI.Method.agentsRecreateWorktree, DaemonAPI.AgentRequest(agentID: agentID))
            await refreshAgents()
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = "That did not reach your Mac."
        }
    }
    func unarchive(_ agentID: UUID) async { await act(DaemonAPI.Method.agentsUnarchive, agentID) }
    /// Park or unpark, whichever `Agent.parkAction` offers (040). From the card's menu.
    func perform(_ action: ParkAction, on agentID: UUID) async {
        await act(AgentAct(action), on: agentID,
                  action == .park ? DaemonAPI.Method.agentsPark : DaemonAPI.Method.agentsUnpark,
                  DaemonAPI.AgentRequest(agentID: agentID))
    }

    /// What is on its way to this agent, if anything: for the control that sent it to
    /// show, and the others to hold (#87).
    func acting(_ agentID: UUID) -> AgentAct? { work.acting[agentID] }

    /// Ask the Mac to start a session's runtime ahead of a prompt (#183): the chat was
    /// opened, or somebody is typing in it. Once per session and reason in a while,
    /// however many keys; the Mac debounces too. Silent: nothing is said if it fails.
    func prewarm(_ agentID: UUID, _ why: DaemonAPI.PrewarmRequest.Why) async {
        guard !isStale, let agent = agent(agentID), agent.state == .finished || agent.state == .stopped else { return }
        let key = "\(agentID) \(why.rawValue)"
        if let last = prewarmed[key], Date().timeIntervalSince(last) < 15 { return }
        prewarmed[key] = Date()
        if prewarmed.count > 64 { prewarmed = prewarmed.filter { Date().timeIntervalSince($0.value) < 15 } }
        _ = try? await client.call(DaemonAPI.Method.agentsPrewarm, DaemonAPI.PrewarmRequest(agentID: agentID, why: why))
    }

    /// Mark as Unread / Mark as Read, from the card's menu (#70).
    func setUnread(_ agentID: UUID, _ unread: Bool) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await client.call(DaemonAPI.Method.agentsSetUnread,
                                  DaemonAPI.SetUnreadRequest(agentID: agentID, unread: unread))
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// Something asked of a whole agent, sent once (#87): held in `work.acting` until the
    /// Mac has answered, so the card, its menu, the swipe and the chat all show it going
    /// and none sends a second. Given back, with the problem said, if it did not go.
    @discardableResult
    private func act(_ act: AgentAct, on agentID: UUID, _ method: String,
                     _ request: some Encodable & Sendable) async -> Bool {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        guard work.begin(act, on: agentID) else { return false }
        defer { work.end(act, on: agentID) }
        do {
            // To the agent's own host (073), and held no longer than `sendPatience` while
            // that host is away (#208).
            try await sendOnce(method, request)
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.folderGone {
            problem = error.message
            return false
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
            return false
        }
    }

    private func act(_ method: String, _ agentID: UUID) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            // To the agent's own host: one on another of the control plane's hosts is not
            // the home host's to stop, park or archive (073).
            let request = DaemonAPI.AgentRequest(agentID: agentID)
            try await sendOnce(method, request)
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// What to say when a send did not go because its host is away (#208): the home host
    /// or another of the control plane's, by name. Nil for any other failure.
    private func away(_ error: any Error, _ outcome: String) -> String? {
        if error is MacAway { return "Your Mac is not answering, so \(outcome)" }
        guard error is HostAway else { return nil }
        return "\(hostName(of: error) ?? "That host") is not answering, so \(outcome)"
    }

    /// The name of the other host a `HostAway` is about.
    private func hostName(of error: any Error) -> String? {
        guard let away = error as? HostAway else { return nil }
        return controlHosts.first { $0.id == away.host }.map { $0.name.isEmpty ? $0.id.rawValue : $0.name }
            ?? "That host"
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
            // `-start` opens New session on that project: the sheet is the one screen in
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
        // `-workflow` opens a workflow's page on the chosen project, by its name.
        if let name = value("-workflow"),
           let workflow = work.workflows.first(where: { $0.workflow.name == name }) {
            selectedProject = workflow.folder
            try? await Task.sleep(for: .milliseconds(600))
            openWorkflow = workflow.id
        }
    }
#endif
}

/// A send refused because the agent's folder has gone (#119): what the Mac said, and what
/// was typed, for Continue in the project folder to carry on with.
struct FolderGoneAsk: Identifiable, Equatable {
    let id = UUID()
    let agentID: UUID
    let message: String
    let text: String
    let attachments: [Attachment]
}
