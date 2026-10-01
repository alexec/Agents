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

    /// Which project is being looked at. Not the daemon's business: it owns what is
    /// true about the work, and which of it somebody happens to be reading is not that.
    var selectedProject: URL? {
        didSet {
            guard selectedProject != oldValue else { return }
            selection = nil
            openWorkflow = nil
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
    /// The loop looking for the Mac, so two of them never run at once.
    private var reconnecting: Task<Void, Never>?
    private var isLoadingEarlier = false

    /// The agent's files as the Mac reads them, and where each agent's pane is (034).
    let files: RemoteFiles
    let panes = RemotePanes()
    let pictures: PhonePictures
    /// This device's end of each agent's shell it has opened (034). The shell is the
    /// Mac's; these only know how to reach it.
    @ObservationIgnored private var shells: [UUID: ShellClient] = [:]

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
                try await RemoteControl.pair(with: control, id: deviceID)
                pairing = .paired
                note("pairing: paired with the control plane \(control.name)")
                pairedWithControlPlane = true
            } catch let error as JSONRPCError {
                pairing = .failed(error.message)
            } catch {
                note("pairing: failed: \(error)")
                pairing = .failed("The control plane didn't take that code. It may have run out: show a new one and try again.")
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

    private func openStart(in folder: URL) async {
        startRefusal = nil
        startWorktree = nil
        startWorktrees = .notARepository
        Task { await loadStartWorktrees(in: folder) }
        if startRuntimeID == nil || !availableRuntimeIDs.contains(startRuntimeID ?? "") {
            startRuntimeID = work.defaultRuntimeID(available: availableRuntimeIDs)
        }
        await loadStartChoices()
        // The runtime menu groups by what the Mac's allowances say, so it needs them
        // before it is opened, not after whoever happens to visit the Runtimes page.
        await refreshRuntimeAllowances()
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
    var questionForSelection: PermissionRequest? { work.permission(for: selection) }

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
            panes.state(for: agentID).open(file: file.url, line: file.line)
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
    func connect() async {
        guard reconnecting == nil else { return }
        reconnecting = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Lost again while this attempt was still settling in: `lostTouch` found
                // this loop running and left it to go round once more.
                if await self.tryOnce(), self.isConnected { break }
                let nap = Task<Void, Never> { try? await Task.sleep(for: self.backOff) }
                self.backingOff = nap
                await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
                self.backingOff = nil
                // Backing off to half a minute, so a phone in a pocket with no Mac to
                // find is not holding the radio open every second all afternoon.
                self.backOff = min(self.backOff * 2, .seconds(30))
            }
            // Cancelled by a pairing, which has already started the loop that replaces
            // this one; that one's handle is not this one's to clear.
            if !Task.isCancelled { self?.finishedReconnecting() }
        }
        await reconnecting?.value
    }

    /// How long the loop waits before the next attempt, and the wait itself, so coming
    /// back to the app can cut it short.
    @ObservationIgnored private var backOff = Duration.seconds(1)
    @ObservationIgnored private var backingOff: Task<Void, Never>?

    /// The app came to the front. A phone that was in a pocket may have been half a
    /// minute into a back-off, or holding a connection that died while it was
    /// suspended; either way the person is looking now, so look now.
    private func cameToTheFront() async {
        backOff = .seconds(1)
        if let backingOff {
            backingOff.cancel()
            return
        }
        guard isConnected, reconnecting == nil else { return }
        if await !client.answers(within: .seconds(4)) {
            // The listener hears the connection close and reconnects.
            await client.disconnect()
        }
    }

    private func tryOnce() async -> Bool {
        do {
            try await client.connect(startIfNeeded: false)
            isConnected = true
            lastHeardFrom = Date()
            problem = nil
            backOff = .seconds(1)
            listen()
            await announce()
            await identify()
            startPresence()
            presence?.connected()
            if link == .relayed { relayTrouble = nil }
            await files.reconnected()
            await refreshEverything()
            watchOtherHosts()
            return true
        } catch {
            if let reason = ControlPlaneLink.refused.take(), reason == .forgotten || reason == .unknown {
                // Forgotten from a window: this device asks for a new code, and stops dialling.
                RemoteControl.forget()
                forgottenByControlPlane = true
                isConnected = false
                reconnecting?.cancel()
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
    private func client(for params: some Encodable) -> DaemonClient {
        guard !otherHosts.isEmpty, let value = try? JSONValue.encoding(params) else { return client }
        if let id = (value["agentID"] ?? value["id"])?.stringValue.flatMap(UUID.init(uuidString:)),
           let host = work.agent(id)?.host, let other = otherHosts[host] {
            return other
        }
        for key in ["folder", "cwd"] {
            guard let folder = value[key]?.stringValue else { continue }
            if let project = work.projects.first(where: { $0.folder.absoluteString == folder && $0.host != .mac }),
               let other = otherHosts[project.host] {
                return other
            }
        }
        return client
    }

    /// Ask whether a control plane is on the other end, and follow its other hosts if so.
    /// A bridge with no control plane answers `control/status` with methodNotFound, and
    /// nothing more happens.
    private func watchOtherHosts() {
        guard hostWatch == nil else { return }
        hostWatch = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.client.call(DaemonAPI.Method.controlStatus)) != nil else {
                self.hostWatch = nil
                return
            }
            // Through the relay a device has one session at a time (046), and it is the
            // home host's: the other hosts wait until the control plane's address answers.
            let base: any DaemonLink = (self.baseLink as? ControlPlaneLink)?.addressOnly ?? self.baseLink
            let link = ControlLink { try await base.transport() }
            let control = DaemonClient(link: link.controlLink)
            while !Task.isCancelled {
                if (try? await control.connect(startIfNeeded: false, timeout: .seconds(5))) != nil {
                    await self.syncOtherHosts(control, link: link)
                    for await note in control.notifications() where note.method == DaemonAPI.Notification.controlHostChanged {
                        await self.syncOtherHosts(control, link: link)
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
            guard await !other.isConnected,
                  (try? await other.connect(startIfNeeded: false, timeout: .seconds(5))) != nil else { continue }
            let id = host.id
            if let projects = try? await other.call(DaemonAPI.Method.projectsList,
                                                    DaemonAPI.ProjectsListRequest(includeArchived: false),
                                                    returning: [DaemonAPI.ProjectSummary].self) {
                work.replaceProjects(projects, from: id)
            }
            if let agents = try? await other.call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest(includeArchived: false),
                                                  returning: [Agent].self) {
                work.replaceAgents(agents, from: id)
            }
            let notes = other.notifications()
            Task { [weak self] in
                for await note in notes { _ = self?.work.apply(note.method, note.params, from: id) }
            }
        }
        // A host that went offline keeps its projects, greyed under its heading (frame H).
        // One the control plane no longer lists is gone, and so is what it showed.
        for id in otherHosts.keys where !others.contains(where: { $0.id == id }) {
            await otherHosts.removeValue(forKey: id)?.disconnect()
            if !listed.contains(where: { $0.id == id }) {
                work.replaceProjects([], from: id)
                work.replaceAgents([], from: id)
            }
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
                let updated = notification.method == DaemonAPI.Notification.agentChanged
                    ? (try? notification.params?.decode(Agent.self)) : nil
                let previousLabels = updated.flatMap { self.work.agent($0.id)?.labels }
                let removed = notification.method == DaemonAPI.Notification.agentRemoved
                    ? (try? notification.params?.decode(DaemonAPI.AgentRemovedNotification.self)) : nil
                let removedProject = removed.flatMap { self.work.agent($0.agentID)?.projectFolder }
                // Anything the shared model does not claim is the Mac's own — shells,
                // terminals — and a remote has no business with it.
                _ = self.work.apply(notification.method, notification.params)
                if let updated, previousLabels != updated.labels,
                   self.labelVocabularies[updated.projectFolder] != nil {
                    await self.loadLabelVocabulary(in: updated.projectFolder)
                }
                if let removedProject, self.labelVocabularies[removedProject] != nil {
                    await self.loadLabelVocabulary(in: removedProject)
                }
                if Self.attentionNotifications.contains(notification.method) {
                    self.publishAttention()
                }
                if notification.method == DaemonAPI.Notification.attentionChanged,
                   let change = try? notification.params?.decode(DaemonAPI.AttentionNotification.self) {
                    await self.notifier.apply(change, me: .device(self.deviceID))
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

    /// A call that changes something, sent so that it happens once even if the link
    /// changes under it (046, FR-003). Its params carry the id the Mac dedups — a send's
    /// `sendID`, a start's `requestID` — or it is one the Mac can safely do twice (stop,
    /// archive). A call lost with the connection is sent once more, unchanged, as soon
    /// as the Mac is back.
    @discardableResult
    private func sendOnce(_ method: String, _ params: some Encodable & Sendable) async throws -> JSONValue {
        let client = client(for: params)
        do {
            return try await client.call(method, params)
        } catch is JSONRPCTransportError {
        } catch DaemonClient.ConnectError.couldNotConnect {
        }
        if let underway = reconnecting { await underway.value } else { await connect() }
        return try await client.call(method, params)
    }

    func refreshEverything() async {
        // Projects first: the screen the app opens on, and a row's counts are read from
        // the agents as they land, so the list is there while they are still coming.
        await refreshProjects()
        await refreshAgents()
        await refreshPermissions()
        await refreshElicitations()
        await refreshAttention()
        await refreshResuming()
        await refreshCostState()
        await refreshRuntimeAllowances()
        await refreshLeases()
        await refreshEvents()
        await refreshWorkflows()
        await refreshRuntimes()
        await refreshModes()
        await refreshSandboxSettings()
        await settleUnsettledStart()
        await loadTranscript()
        settleSelection()
        // Once the counts have landed, so the widget's number is this refresh's number.
        publishAttention()
        if let pendingOpen { open(pendingOpen) }
    }

    // MARK: Where this device is (021)

    /// The app came to the front or went behind. `.active` is foreground and unlocked,
    /// which is what "in the person's hands" means on a device.
    func scenePhase(_ phase: ScenePhase) {
        presence?.scenePhase(phase)
        if phase == .active {
            Task {
                await cameToTheFront()
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
        note("push: \(userInfo)")
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
        guard AttentionSnapshotStore.write(AttentionSnapshot.make(model: work, at: Date())) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
    }

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
        let counts = work.counts(in: summary.project.folder)
        return (counts[.needsAttention] ?? 0) + (counts[.blocked] ?? 0) > 0
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

    /// The live agents only. Archived ones outnumber them many times over and are
    /// almost never looked at, so they come when a page asks for them — a project's
    /// Archived section, a workflow's runs — and not on every connection.
    ///
    /// Archived agents already fetched are kept: an open archived chat stays open. One
    /// brought back while this phone was away is in the live list, and that copy wins.
    private func refreshAgents() async {
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList,
                                                  DaemonAPI.ListRequest(includeArchived: false),
                                                  returning: [Agent].self) else { return }
        let live = Set(listed.map(\.id))
        // Only this host's: another host's agents come from that host (058, US4).
        work.replaceAgents(listed + work.agents.filter { $0.host == .mac && $0.state == .archived && !live.contains($0.id) },
                           from: .mac)
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
                                            folder: folder, limit: limit)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return }
        for agent in listed { work.upsert(agent) }
    }

    func loadAllArchivedAgents(in folder: URL) async {
        let request = DaemonAPI.ListRequest(archivedCommands: false, archivedOnly: true,
                                            folder: folder)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return }
        for agent in listed { work.upsert(agent) }
    }

    /// A workflow's newest `limit` runs, archived ones included, for its page. Answers
    /// whether there are more than that.
    func loadRuns(of workflowID: String, in folder: URL, limit: Int) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedCommands: false, folder: folder,
                                            startedByWorkflow: workflowID, limit: limit + 1)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return false }
        for agent in listed.prefix(limit) { work.upsert(agent) }
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

    /// What each agent holds and waits for (036). The phone only reads it: the
    /// Resources page and ending a lease are the Mac's (FR-011).
    private func refreshLeases() async {
        guard let snapshot = try? await client.call(DaemonAPI.Method.leasesSnapshot,
                                                    Optional<String>.none,
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
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

    private func refreshProjects() async {
        // Live ones only; Spending asks for the archived ones when it opens.
        guard let listed = try? await client.call(DaemonAPI.Method.projectsList,
                                                  DaemonAPI.ProjectsListRequest(includeArchived: false),
                                                  returning: [DaemonAPI.ProjectSummary].self)
        else { return }
        work.replaceProjects(listed, from: .mac)
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

    /// Change what a workflow is allowed to do. The Mac's daemon writes the file and
    /// answers with what it now says; a refusal has to reach the person, and the list
    /// is asked again so the menu goes back to what the file still holds (FR-025).
    func setWorkflowSettings(_ summary: WorkflowSummary, _ settings: WorkflowSettings) async {
        do {
            let updated: WorkflowSummary = try await client.call(
                DaemonAPI.Method.workflowsSettings,
                DaemonAPI.WorkflowSettingsRequest(folder: summary.folder,
                                                  workflowID: summary.workflowID,
                                                  settings: settings),
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

    /// Every entry of a finished turn, for the chat to open it.
    func turnEntries(_ agentID: UUID, _ range: Range<Int>) async -> [TranscriptEntry] {
        let request = DaemonAPI.TranscriptRequest(agentID: agentID, before: range.upperBound,
                                                  limit: range.count, from: range.lowerBound)
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
            try await sendOnce(DaemonAPI.Method.elicitationsAnswer,
                               DaemonAPI.AnswerElicitationRequest(requestID: request.id, action: action,
                                                                  content: content, sendID: UUID()))
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
            try await sendOnce(DaemonAPI.Method.agentsPrompt,
                               DaemonAPI.PromptRequest(agentID: agentID, text: what,
                                                       attachments: attachments, sendID: UUID()))
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

    /// Stop one shell an agent left running, and nothing else it is doing (057). The
    /// row goes when the daemon says the agent changed.
    func stopBackground(_ item: BackgroundItem, of agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be stopped."
            return
        }
        do {
            try await client.call(DaemonAPI.Method.agentsStopBackground,
                                  DaemonAPI.StopBackgroundRequest(agentID: agentID, itemID: item.id))
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// Send a queued prompt into the turn that is running, where the runtime takes one.
    func sendNow(_ prompt: QueuedPrompt, to agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await client.call(DaemonAPI.Method.agentsSendNow,
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
    /// Park or unpark, whichever `Agent.parkAction` offers (040). From the card's menu.
    func perform(_ action: ParkAction, on agentID: UUID) async {
        await act(action == .park ? DaemonAPI.Method.agentsPark : DaemonAPI.Method.agentsUnpark, agentID)
    }

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
