import BackgroundTasks
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
/// folder and agent are being looked at, and whether the Mac is still there.
@MainActor
@Observable
final class RemoteModel {
    let work = AgentsModel()
    private var labelVocabularies: [URL: [String]] = [:]
    @ObservationIgnored private var attentionRefreshTask: Task<Void, Never>?

    /// Whether the Mac is answering, and when it last did.
    private(set) var isConnected = false {
        didSet { if oldValue, !isConnected { liveUntil = Date() } }
    }
    /// When what the phone holds was last live with the Mac (#1163): the moment touch was
    /// lost. Nil before the first connection since launch, when the phone holds nothing.
    private(set) var liveUntil: Date?
    /// When the Needs you count was last true, for the "Updated" line beside it: nil while
    /// live, when it is true now (#1163).
    var needsYouUpdatedAt: Date? { isConnected ? nil : liveUntil }
    /// Which way the Mac is being reached (046): on its own network, or through iCloud.
    /// Set from the route each connection took (#883); a link that cannot be relayed,
    /// such as the fake, is always direct.
    private(set) var link: RemoteLink = .direct
    /// What is getting in the relay's way, when anything is (046, FR-014).
    private(set) var relayTrouble: RelayTrouble?
    private(set) var lastHeardFrom: Date?
    private(set) var problem: String?
    /// Words for one chat's prompt bar, from elsewhere in the chat: an edit to a queued
    /// prompt that came too late (#1552). That agent's bar (#1679) takes them and sets this
    /// back to nil, so another iPad scene's bar leaves them.
    var offeredPrompt: PromptOffer?
    /// Words quoted from a reply for that chat's prompt bar (#1553, #1679): added to what is
    /// there as a quote, then cleared.
    var offeredQuote: PromptOffer?
    /// A message for the open chat to go to, and where it is in the transcript: Find in
    /// Chat's match (#1532). Cleared once the chat has gone to it.
    var focusedEntry: UUID?
    var focusedIndex: Int?
    /// A send refused because the agent's folder has gone (#119), with the ways on.
    var folderGone: FolderGoneAsk?

    /// Which folder is being looked at. Not the daemon's business: it owns what is
    /// true about the work, and which of it somebody happens to be reading is not that.
    var selectedFolder: URL? {
        didSet {
            guard selectedFolder != oldValue else { return }
            composing = false
            selection = nil
            openWorkflow = nil
            openPin = nil
            openArchive = false
            openMCPServers = false
            if selectedFolder != nil { openActivity = nil }
            letGoOfFolders(keeping: selectedFolder)
        }
    }

    /// A new session is being written in the selected folder (#2090), the Mac's
    /// `composing`: set only by asking for one (New Session, +, a link), and let go by
    /// anything else opening. Leaving a session, by Archive or by its going, never opens
    /// New session: with nothing open the detail says nothing is picked.
    var composing = false

    /// The conversation open, if any. Set by the push, cleared by the back button.
    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            if selection != nil { composing = false }
            // A Review page pushed over the last chat is not left over the next (#1472).
            openReview = nil
            work.watching = selection
            presence?.watching(selection)
            // Opened from Unread, it stays there until something else is opened (#495,
            // #498), as a read message stays in Mail's Unread mailbox while it is selected.
            keptInUnread = selection.flatMap { work.agent($0) }.flatMap { $0.showsUnread ? $0.id : nil }
            letGoOfChats(keeping: selection)
            Task { await loadTranscript() }
        }
    }

    /// The selection once it has been looked for, as `PoppedChat.looked`: from then a
    /// selected session not in hand is one that has gone (#2652).
    private(set) var lookedForSelection: UUID?

    /// The sessions open in scenes of their own on an iPad (#888), each with its own page
    /// of its transcript. See `PoppedChat`.
    var popouts: [UUID: PoppedChat] = [:]
    /// The folders open on their own (#1089): a scene each on an iPad, the screen on an
    /// iPhone. Each with what it has picked, so a notification can open a session in it.
    var folderScenes: [FolderKey: RemoteFolderState] = [:]
    /// The folder an iPhone shows alone, over the sidebar of every folder (#1089).
    var phoneFolder: FolderKey?
    /// The Export… or Import Agents… on its way, drawn as a busy sheet with Cancel (#2437).
    var exportImport: ExportImportProgress?
    /// The folder whose own scene's start page the start form is for, while one is (#1089).
    var composingScene: FolderKey?
    /// Brings a folder's scene forward, or opens it: handed over by a view that has the
    /// scene's action, for what is not a view (a notification).
    @ObservationIgnored var openFolderScene: ((FolderKey) -> Void)?
    /// The one of them in the key window, if one is: what the person is watching.
    @ObservationIgnored var popoutInFront: UUID?

    private let client: DaemonClient
    /// 021: this device's banner, and its report of where the person is. Neither
    /// decides anything; the Mac routes and these two obey.
    private let notifier = DeviceNotifier()
    /// A turn sent from here, on the Lock Screen and in the Dynamic Island (#1657).
    @ObservationIgnored let liveActivities = TurnActivities()
    var presence: PresenceReporter?
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
    /// The first page of live agents was full: the rest come a folder at a time, as each
    /// folder's page opens.
    @ObservationIgnored private var moreLiveAgents = false
    @ObservationIgnored private var filledFolders: Set<URL> = []

    /// The agent's files as the Mac reads them, and where each agent's pane is (034).
    let files: RemoteFiles
    let panes = RemotePanes()
    let pictures: PhonePictures
    /// This device's end of each of an agent's shells it has opened (034), one per
    /// terminal tab (055, #345). The shells are the Mac's; these only know how to reach them.
    @ObservationIgnored private var shells: [ShellKey: ShellClient] = [:]
    /// Shells no screen shows that still hold their emulator, most recent last, so going
    /// back to an agent's terminal finds it as it was instead of rebuilding it and
    /// replaying megabytes on the main thread (#419, as the Mac since #401). A few, not
    /// all: `shells` keeps a client for every shell ever opened, and each emulator holds
    /// a screen's worth of scrollback.
    @ObservationIgnored private var parkedScreens: [ShellKey] = []
    private static let parkedScreenLimit = 6
    /// When this device last asked to warm each session, and why (#183).
    @ObservationIgnored private var prewarmed: [String: Date] = [:]

    struct ShellKey: Hashable {
        let agentID: UUID
        let shell: Int
    }

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

    func shellClient(for agentID: UUID, shell: Int = 0) -> ShellClient {
        let key = ShellKey(agentID: agentID, shell: shell)
        if let existing = shells[key] { return existing }
        let fresh = ShellClient(agentID: agentID, shell: shell, client: client, describe: { error in
            (error as? JSONRPCError)?.message ?? "Your Mac is not answering."
        })
        shells[key] = fresh
        return fresh
    }

    /// One of the folder's own shells (#418), on the folder's host: the ones Control-`
    /// opens on the Mac, in the folder whichever agent is open.
    func folderShellClient(for folder: URL, shell: Int = 0) -> ShellClient {
        let id = FolderShell.id(for: folder)
        let key = ShellKey(agentID: id, shell: shell)
        if let existing = shells[key] { return existing }
        let fresh = ShellClient(agentID: id, shell: shell, folderContext: folder, client: folderHostClient(for: folder),
                                describe: { error in
            (error as? JSONRPCError)?.message ?? "Your Mac is not answering."
        })
        shells[key] = fresh
        return fresh
    }

    /// The shells the folder's host holds for the folder, so the sheet opens with the
    /// tabs the Mac's panel has. Nil from a host too old to list them.
    func folderShellNumbers(for folder: URL) async -> [Int]? {
        let response = try? await folderHostClient(for: folder).call(
            DaemonAPI.Method.shellList, DaemonAPI.AgentRequest(agentID: FolderShell.id(for: folder)),
            returning: DaemonAPI.ShellListResponse.self)
        return response?.shells
    }

    /// A new tab in the folder's sheet, numbered by its host. Nil from a host too old
    /// to open one for a folder, and the sheet numbers it itself.
    func openFolderShell(for folder: URL) async -> Int? {
        await ShellClient.open(agentID: FolderShell.id(for: folder), folder: folder,
                               on: folderHostClient(for: folder))
    }

    private func folderHostClient(for folder: URL) -> DaemonClient {
        let host = work.folders.first { $0.folder.folder == folder }?.host ?? .mac
        return host == .mac ? client : otherHosts[host] ?? client
    }

    /// The shells the Mac holds for an agent, so the pane opens with the tabs the window
    /// has (055). Nil from a daemon too old to hold more than one, and the pane then
    /// offers only the one.
    func shellNumbers(for agentID: UUID) async -> [Int]? {
        let response = try? await client.call(DaemonAPI.Method.shellList, DaemonAPI.AgentRequest(agentID: agentID),
                                              returning: DaemonAPI.ShellListResponse.self)
        return response?.shells
    }

    /// The person closed a terminal tab: the shell ends, on the Mac too, and this
    /// device forgets it.
    /// A new terminal tab: the Mac starts the shell and says its number (#401). Nil from
    /// a Mac too old to, and the pane numbers it itself.
    func openShell(for agentID: UUID) async -> Int? {
        await ShellClient.open(agentID: agentID, on: client)
    }

    /// A shell's screen is showing: its emulator is not one to let go of (#419).
    func showScreen(of client: ShellClient) {
        parkedScreens.removeAll { $0 == ShellKey(agentID: client.agentID, shell: client.shell) }
    }

    /// A shell's screen went: its emulator is kept for a while, and the oldest kept past
    /// the limit is let go of. That shell's next screen is built again and replayed (#419).
    func parkScreen(of client: ShellClient) {
        let key = ShellKey(agentID: client.agentID, shell: client.shell)
        parkedScreens.removeAll { $0 == key }
        parkedScreens.append(key)
        while parkedScreens.count > Self.parkedScreenLimit {
            guard let parked = shells[parkedScreens.removeFirst()] else { continue }
            parked.onOutput = nil
            parked.screen = nil
        }
    }

    func closeShell(agentID: UUID, shell: Int) async {
        let client = shellClient(for: agentID, shell: shell)
        shells[ShellKey(agentID: agentID, shell: shell)] = nil
        parkedScreens.removeAll { $0 == ShellKey(agentID: agentID, shell: shell) }
        await client.close()
    }


    /// The link the Mac is reached by, kept so a second connection can be made over it
    /// to a control plane's other hosts (058, US4).
    @ObservationIgnored private let baseLink: any DaemonLink
    /// Every host a control plane has besides the one this phone paired with, each with
    /// a client of its own over one more connection (058, US4). Empty against a bridge
    /// with no control plane.
    @ObservationIgnored private var otherHosts: [MachineRef: DaemonClient] = [:]
    @ObservationIgnored private var hostWatch: Task<Void, Never>?
    /// The watch's own client of the control plane while it is connected, for the control
    /// plane's own requests (`hosts/start`, #691). Nil against a bridge with no control plane.
    @ObservationIgnored private(set) var controlPlane: DaemonClient?
    /// People (#994): the machines waiting for this person's approval, fed from the watch.
    let people = PeopleState()
    /// The GitHub sign-ins waiting for this person's Approve (#995).
    let signIn = SignInState()
    /// The settings and secrets that follow the person to their machines (#1760).
    let userScope = UserScopeState()
    /// What `hosts/list` last said, so the folder list can name each host (058, frame H).
    /// Empty when this phone is not a client of a control plane.
    private(set) var controlHosts: [DaemonAPI.ControlMachine] = []
    /// Git asks answered on this device, until the control plane's list drops them (#1122).
    private var gitAsksAnswered: Set<String> = []
    /// The host this phone's own connection reaches. Its folders are stamped `.mac`.
    private(set) var controlHome: MachineRef?
    /// What `control/status` last said: its version and capabilities, for Settings (#1748).
    private(set) var controlStatus: DaemonAPI.ControlStatus?

    /// Each connected server's local daily ledger, matching the window's combined
    /// Today figure. Limits remain local to the host that owns them.
    private(set) var serverCosts: [MachineRef: DaemonAPI.CostState] = [:]
    /// Each other host's disk alarms, kept separate from this Mac's strip (#263).
    private(set) var serverDisks: [MachineRef: DiskState] = [:]

    var serversToday: [String: Decimal] {
        serverCosts.values.reduce(into: [:]) { sum, state in
            for (currency, amount) in state.today { sum[currency, default: 0] += amount }
        }
    }

    init(link: any DaemonLink) {
        baseLink = link
        client = DaemonClient(link: link)
        files = RemoteFiles(client: client)
        pictures = PhonePictures(files: files)
        // From the start, not once connected: a banner tapped to launch or wake the app
        // arrives before then, and was dropped (#1045).
        notifier.open = { [weak self] agentID in
            // In its folder's own scene or screen when one is open (#1089, Alex).
            if self?.showInFolderScene(agentID) == true { return }
            // Not in the folder an iPhone shows alone: back to every folder, to it.
            self?.phoneFolder = nil
            self?.open(agentID)
        }
        notifier.openNeed = { [weak self] token in self?.open(needToken: token) }
        notifier.answer = { [weak self] token, quick, typed in
            await self?.answerFromBanner(token, quick, typed: typed) ?? false
        }
        // The oldest of a long conversation go from the page as it runs on; what they
        // say the agent touched is kept with the rest of the history read for Files.
        work.onTrimmed = { [weak self] dropped in
            guard let self, let agentID = work.watching else { return }
            for entry in dropped { touchedEarlier[agentID, default: TouchedPaths()].absorb(entry) }
        }
        work.onOversized = { [weak self] agentID, entryID, index in
            Task { await self?.loadOversized(entryID, of: agentID, at: index) }
        }
        liveActivities.tokenChanged = { [weak self] agentID, token, startedAt in
            guard let self, isConnected else { return }
            Task { await self.sendActivityToken(agentID, token, startedAt) }
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
                pairing = .failed("That code is for adding a machine, not a phone.")
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

    /// Set once this device has forgotten itself: the app makes a new, unpaired model (#344).
    private(set) var forgotItself = false

    /// Forget This iPhone (#344, 071 FR-015): the control plane forgets this device, and only
    /// it, then the pairing goes and the app asks for a code again. Answers why not, with
    /// nothing changed, or nil.
    func forgetThisDevice() async -> String? {
        do {
            try await client.call(DaemonAPI.Method.clientsForgetSelf, DaemonAPI.Empty())
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return "Your Mac is not answering. This \(UIDevice.current.model) is still paired."
        }
        note("pairing: forgot itself")
        RemoteControl.forget()
        forgotItself = true
        return nil
    }

    // MARK: Add a Browser (#1459)

    /// A code for a browser, as the window's Add a Browser… makes one, and the page's
    /// address on the control plane's own domain when it serves one there. Or why not, in
    /// words to show.
    func startBrowserCode() async -> Result<BrowserCode, BrowserCodeProblem> {
        do {
            // Who was there before the code, so whoever it lets in can be named (#1537).
            let listed = await pairedClients()
            let before = Set(listed?.map(\.id) ?? [])
            let shown = try await client.call(DaemonAPI.Method.clientsStartPairing,
                                              JSONValue.object(["kind": .string(ClientRecord.Kind.browser.rawValue)]),
                                              returning: DaemonAPI.ControlCodeShown.self)
            let status = try? await client.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
            return .success(BrowserCode(shown: shown, page: status?.publicWeb, web: status?.web, before: before))
        } catch let error as JSONRPCError {
            return .failure(BrowserCodeProblem(words: error.message))
        } catch {
            return .failure(BrowserCodeProblem(words: "The control plane can’t be reached."))
        }
    }

    /// The control plane's paired clients, or nil when it can't say.
    func pairedClients() async -> [ClientRecord]? {
        try? await client.call(DaemonAPI.Method.clientsList, returning: [ClientRecord].self)
    }

    /// The code is no longer shown: it can't be used.
    func stopBrowserCode() async {
        _ = try? await client.call(DaemonAPI.Method.clientsStopPairing)
    }

    // MARK: A server's key (#344)

    /// A server asked for a key this device has none of to lend: the window's card asks the
    /// person, and the key is lent on this device's own connection to it (043, #344).
    var tokenAsk: TokenAsk?

    /// The home host's asks: the control plane's, which may be a server.
    private func answerHomeCredentialWanted(_ wanted: DaemonAPI.CredentialWanted) async -> Bool {
        await answerCredentialWanted(wanted, on: controlHome ?? .mac)
    }

    /// A server's daemon wants a key to start a runtime (043, R6): asked of the person, as the
    /// window asks. True when one was lent, and the refused call is then sent again, as
    /// it was. A second ask while one is showing is refused rather than left waiting.
    private func answerCredentialWanted(_ wanted: DaemonAPI.CredentialWanted, on id: MachineRef) async -> Bool {
        guard id != .mac, !CredentialKind.kinds(for: wanted.runtime).isEmpty, tokenAsk == nil else { return false }
        let label = hostName(id)
        return await withCheckedContinuation { answer in
            tokenAsk = TokenAsk(runtimeID: wanted.runtime, host: id, label: label,
                                keeping: "Paste a key and Agents lends it to \(label) while this \(UIDevice.current.model) "
                                    + "is connected. It is kept nowhere.",
                                whereToGet: CredentialKind.source(for: wanted.runtime),
                                action: "Lend and start", answer: answer)
        }
    }

    /// The person pasted a key: offered and lent to the server that asked, on this device's
    /// connection to it, and nowhere else. The ask is answered either way.
    func lend(_ secret: Secret, for ask: TokenAsk) async {
        let server = ask.host == controlHome ? client : otherHosts[ask.host]
        var lent = false
        if let server {
            lent = (try? await server.call(DaemonAPI.Method.credentialsOffer,
                                           DaemonAPI.CredentialsOffer(runtimes: [ask.runtimeID], ownSignInOnly: false))) != nil
            if lent {
                lent = (try? await server.call(DaemonAPI.Method.credentialsLend,
                                               DaemonAPI.CredentialsLend(runtime: ask.runtimeID, secret: secret))) != nil
            }
        }
        finishTokenAsk(lent: lent)
    }

    /// The ask answered: lent (true), or cancelled. Once per ask: its answer is a continuation.
    func finishTokenAsk(lent: Bool) {
        guard let ask = tokenAsk else { return }
        tokenAsk = nil
        ask.answer.resume(returning: lent)
    }

    /// Put what the person typed on a page on disk, through the daemon, which is the one
    /// writer and the one that tells the agent (022). The same request the Mac's page
    /// makes, so a phone's edit is the person's in exactly the same way (034 FR-006).
    /// Answers why it did not land, or nil.
    /// The editor's save that checks the file first (#1858).
    func writeArtifact(agentID: UUID, path: String, text: String, base: String) async -> SaveOutcome {
        guard !isStale else { return .failed("Your Mac is not answering. What you typed is kept here.") }
        do {
            let request = DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text, base: base)
            try await client(for: request).call(DaemonAPI.Method.artifactWrite, request)
            return .saved
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.fileChanged {
            return .changedOnDisk
        } catch let error as JSONRPCError {
            return .failed(error.message)
        } catch {
            return .failed("Your Mac is not answering. What you typed is kept here.")
        }
    }

    func writeArtifact(agentID: UUID, path: String, text: String) async -> String? {
        guard !isStale else { return "Your Mac is not answering. What you typed is kept here." }
        do {
            let request = DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text)
            try await client(for: request).call(DaemonAPI.Method.artifactWrite, request)
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return "Your Mac is not answering. What you typed is kept here."
        }
    }

    /// Why a file is not sent to a drop box from a phone: too big for one record.
    static func dropboxTooBig(_ name: String) -> String {
        "From a phone, a drop box file can be 900 KB, and \(name) is bigger. Copy it into .agents/dropbox/ on the Mac instead."
    }

    /// A file put into a folder's drop box (#231), where a workflow on
    /// `dropbox.file_added` can pick it up. `subfolder` is inside `.agents/dropbox/`, empty
    /// for its top. Held to what crosses the relayed link in one record, as an attachment
    /// is. Answers why it did not go, or nil.
    func putInDropbox(_ data: Data, name: String, subfolder: String, folder: FolderKey) async -> String? {
        guard !isStale(on: folder.host) else { return notAnswering(folder.host, "\(name) was not sent.") }
        guard data.count <= PhoneAttachment.limit else { return Self.dropboxTooBig(name) }
        let subfolder = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let request = DaemonAPI.DropboxPutRequest(folder: folder.folder, subfolder: subfolder.isEmpty ? nil : subfolder,
                                                  name: name, data: data)
        do {
            _ = try await client(for: request).call(DaemonAPI.Method.dropboxPut, request,
                                                    returning: DaemonAPI.DropboxPutResponse.self)
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return notAnswering(folder.host, "\(name) was not sent.")
        }
    }

    /// The Mac predates the panes, and the phone does what it did before them (FR-029).
    var macLacksPanes: Bool { files.macLacksPanes }

    // MARK: What the screens read

    var folders: [DaemonAPI.FolderSummary] { work.liveFolders }

    /// The hosts a folder can be added on or cloned to (#537): this Mac, then each
    /// other host of the control plane, as the window's + menu lists them.
    var folderHosts: [HostSection] {
        let sections = hostSections
        return sections.isEmpty ? [HostSection(id: .mac, title: "This Mac", offline: false)] : sections
    }

    /// The client for `host` itself, for a call that names no folder there yet.
    private func client(on host: MachineRef) throws -> DaemonClient {
        if host == .mac { return client }
        guard let other = otherHosts[host], reachableHosts.contains(host) else { throw HostAway(host: host) }
        return other
    }

    /// One folder on `host`, for choosing a folder there (#537): `files/browse`, as the
    /// window's and the page's folder sheets read a server's. `~` is the host's home.
    func browse(_ path: String, on host: MachineRef) async -> Result<DirectoryListing, BrowseProblem> {
        do {
            return .success(try await client(on: host).call(DaemonAPI.Method.filesBrowse,
                                                             DaemonAPI.FilesBrowseRequest(path: path),
                                                             returning: DirectoryListing.self))
        } catch let error as JSONRPCError {
            return .failure(BrowseProblem(message: error.message))
        } catch {
            return .failure(BrowseProblem(message: notAnswering(host, "its folders can't be shown.")))
        }
    }

    struct BrowseProblem: Error {
        let message: String
    }

    /// Add a folder on `host` as a folder, and open it: in `project` when one was picked
    /// (#2671). Answers why not, or nil.
    func addFolder(_ folder: URL, on host: MachineRef, project: String? = nil) async -> String? {
        do {
            let summary = try await client(on: host).call(DaemonAPI.Method.foldersAdd,
                                                          DaemonAPI.AddFolderRequest(folder: folder, project: project),
                                                          returning: DaemonAPI.FolderSummary.self)
            show(summary, on: host)
            return nil
        } catch {
            return away(error, "the folder was not added.") ?? sentence(for: error)
        }
    }

    /// Clone a repository into `host`'s home folder as a folder, and open it. Answers
    /// why not, or nil.
    func cloneFolder(url: String, on host: MachineRef) async -> String? {
        do {
            let summary = try await client(on: host).call(DaemonAPI.Method.foldersClone,
                                                          DaemonAPI.CloneRequest(url: url),
                                                          returning: DaemonAPI.FolderSummary.self)
            show(summary, on: host)
            return nil
        } catch {
            return away(error, "nothing was cloned.") ?? sentence(for: error)
        }
    }

    /// A folder just added on `host`, listed and opened at once rather than when the
    /// host next says so.
    private func show(_ summary: DaemonAPI.FolderSummary, on host: MachineRef) {
        var added = summary
        added.host = host
        work.upsert(added)
        sidebarItem = .folder(added.key)
    }

    /// One host's heading in the folder list. Several hosts, and the list is grouped
    /// under these; one host, and there is no heading, as on the Mac (058, frame H).
    struct HostSection: Identifiable {
        /// The id folders from this host are stamped with. The phone's own Mac is
        /// `.mac`, whichever id the control plane gave that host.
        var id: MachineRef
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

    /// Whether `host`'s folders are last known rather than current (frame H greys them).
    /// A host's name as a server folder's row leads with it (#145): `devbox:api`.
    func hostLabel(_ host: MachineRef) -> String {
        hostSections.first { $0.id == host }?.title ?? host.rawValue
    }

    func hostIsOffline(_ host: MachineRef) -> Bool {
        hostSections.first { $0.id == host }?.offline ?? false
    }
    /// Archived ones too, for the spending page. A folder put away still cost what it
    /// cost, and a grand total that quietly dropped it would be wrong rather than tidy.
    /// The archived ones are fetched when that page opens (`loadArchivedFolders`).
    var allFolders: [DaemonAPI.FolderSummary] {
        let held = Set(work.folders.map(\.key))
        return work.folders + archivedFolders.filter { !held.contains($0.key) }
    }
    /// The open folder's standing arrangements.
    var workflows: [WorkflowSummary] { work.workflows(in: selectedFolder) }
    var userWorkflows: [WorkflowSummary] { work.userWorkflows }

    /// The workflow whose page is open, if one is. Its id rather than a copy, for the
    /// Mac page's reason: the file is the truth, and a copy would show what it used to
    /// say. Pushed under the conversation, so a run opened from its page comes back to it.
    var openWorkflow: Workflow.ID?
    /// The folder's pinned page (#159) pushed over the folder page, by its path in it.
    var openPin: String?
    /// The folder's archive (#495, #498): its archived sessions and workflows, a page
    /// opened from one row in the sidebar rather than folds inside the folder's.
    var openArchive = false
    /// The folder's MCP servers (#753), a page opened from its row in the sidebar.
    var openMCPServers = false
    /// A change waiting for an OK, on its Review page (#1472), by its `Approval.id`: from
    /// Needs You, the detail's own page; from Review… on a chat's card, pushed over the chat.
    var openReview: String?
    /// The milestones this device has shown (#984); nil before its first look. See
    /// `RemoteModel+Milestones`.
    var milestonesSeen: Set<String>? = RemoteModel.keptMilestonesSeen
    /// The session opened while it was unread, kept in the sidebar's Unread until another
    /// is opened (#495), so it does not leave the list under the finger on the tap.
    private(set) var keptInUnread: UUID?
    /// One of the pages about all the work, from the sidebar's Activity (#226): Events,
    /// Resources, Runtimes or Spending. Nil, or one of those.
    var openActivity: SidebarItem? {
        didSet {
            if openActivity != nil, selectedFolder != nil { selectedFolder = nil }
        }
    }

    /// What the sidebar has picked (#226), the Mac's one value for it: the first of what is
    /// open over the folder — a pinned page, a workflow, a chat — and what
    /// was opened from that is pushed over it in the detail. A folder chosen with nothing
    /// open over it starts a new session in it, as the Mac's New session row does (#375):
    /// only that row and the folder's New Session (long press, swipe) choose it so; a
    /// tap on the folder's own row only folds it. Nothing open and no new session asked
    /// for, and nothing is picked (#2090).
    var sidebarItem: SidebarItem? {
        get {
            if let openActivity { return openActivity }
            guard let folder = selectedFolder else { return nil }
            let key = FolderKey(host: selectedSummary?.host ?? .mac, folder: folder)
            if openArchive { return .archive(key) }
            if openMCPServers { return .folderMCPServers(key) }
            if let openPin { return .pin(openPin, in: key) }
            if let openWorkflow { return .workflow(openWorkflow, in: key) }
            if let selection { return .session(selection) }
            if let openReview { return .review(openReview, in: key) }
            return composing ? .folder(key) : nil
        }
        set {
            defer {
                if case .folder = newValue { composing = true } else { composing = false }
            }
            switch newValue {
            case nil:
                openActivity = nil
                selectedFolder = nil
                selection = nil
                openWorkflow = nil
                openPin = nil
                openArchive = false
                openMCPServers = false
                openReview = nil
            case .folder(let key):
                selectedFolder = key.folder
                selection = nil
                openPin = nil
                openWorkflow = nil
                openArchive = false
                openMCPServers = false
                openReview = nil
                // The next New Session at the sidebar's top starts here too (#495).
                rememberNewSessionFolder(key)
            case .session(let id):
                if let folder = work.agent(id)?.folderPath { selectedFolder = folder }
                openPin = nil
                openWorkflow = nil
                openArchive = false
                openMCPServers = false
                openReview = nil
                selection = id
            case .workflow(let id, let key):
                selectedFolder = key.folder
                openPin = nil
                selection = nil
                openArchive = false
                openMCPServers = false
                openReview = nil
                openWorkflow = id
            case .pin(let path, let key):
                selectedFolder = key.folder
                openWorkflow = nil
                selection = nil
                openArchive = false
                openMCPServers = false
                openReview = nil
                openPin = path
            case .review(let id, let key):
                // A change waiting for an OK (#1472), from its row under Needs You.
                selectedFolder = key.folder
                selection = nil
                openPin = nil
                openWorkflow = nil
                openArchive = false
                openMCPServers = false
                openReview = id
            case .spending, .tokens, .time, .milestones, .resources, .events, .runtimes, .mcpServers, .worktrees:
                openActivity = newValue
            case .archive(let key):
                // The folder's archive page (#495, #498), with what is opened from it
                // pushed over it.
                selectedFolder = key.folder
                selection = nil
                openPin = nil
                openWorkflow = nil
                openMCPServers = false
                openReview = nil
                openArchive = true
            case .folderMCPServers(let key):
                // The folder's MCP servers (#753), with what is opened from it pushed over it.
                selectedFolder = key.folder
                selection = nil
                openPin = nil
                openWorkflow = nil
                openArchive = false
                openMCPServers = true
                openReview = nil
            }
        }
    }
    var selectedSummary: DaemonAPI.FolderSummary? { work.folder(selectedFolder) }

    /// The folder New Session at the top of the sidebar starts in (#495, #498, #2160): the
    /// window's rule, `NewSessionFolder`. A change of choice is said in remote.log.
    var newSessionFolder: FolderKey? {
        let chosen = NewSessionFolder.choose(live: folders.map(\.key), remembered: rememberedNewSessionFolder,
                                              selected: selectedSummary?.key)
        if chosen != saidNewSessionFolder {
            saidNewSessionFolder = chosen
            note("new session: \(chosen?.sentence ?? "no folder")")
        }
        return chosen?.key
    }
    @ObservationIgnored private var saidNewSessionFolder: NewSessionFolder?

    private var rememberedNewSessionFolder: FolderKey? =
        UserDefaults.standard.string(forKey: RemoteModel.newSessionFolderDefault).flatMap(FolderKey.init(stored:))

    static let newSessionFolderDefault = "newSessionFolder"

    /// Every way into a folder's New session calls this, and a start in it (#2160).
    func rememberNewSessionFolder(_ key: FolderKey) {
        guard rememberedNewSessionFolder != key else { return }
        rememberedNewSessionFolder = key
        UserDefaults.standard.set(key.stored, forKey: Self.newSessionFolderDefault)
    }
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

    func agents(group: AgentGroup) -> [Agent] { work.agents(in: selectedFolder, group: group) }

    // MARK: Starting an agent (029)

    /// The folder whose New session page (#366) is on screen, if one is: set by the page
    /// while it shows, so the runtime behind its choices is held only then, and cleared
    /// when the agent it started is ready to be looked at.
    var startingIn: URL? {
        didSet {
            guard startingIn != oldValue else { return }
            if let startingIn { queueOpenStart(startingIn) } else { closeStart() }
        }
    }

    /// The page goes to whichever showing holds it now (#2089): the one under the showing
    /// that went, or none. `afresh` opens it again even in the same folder, for a showing
    /// that has had nothing behind it since its agent started.
    private func startPageMoved(afresh: Bool) {
        let next = startPage.key
        note("start: page now held for \(next?.lastPathComponent ?? "nothing")")
        if afresh, let next, next == startingIn {
            closeStart()
            queueOpenStart(next)
        } else {
            startingIn = next
        }
        if next == nil { startPageLetGo += 1 }
    }

    /// The folders whose New session is asked for now (#2090): the sidebar's pick, and each
    /// folder scene's. What SwiftUI says came and went is not trusted beyond these (#2089).
    private var startPagesWanted: [URL] {
        var wanted: [URL] = []
        if case .folder(let key) = sidebarItem { wanted.append(key.folder) }
        for state in folderScenes.values {
            if case .folder(let key) = state.pick { wanted.append(key.folder) }
        }
        return wanted
    }

    /// What is picked moved, here or in a folder's scene: a showing of a page no longer
    /// asked for stops holding it, though it never said it went.
    func startPagesMoved() {
        let wanted = startPagesWanted
        startPage.keep { wanted.contains($0) }
        if startPage.key != startingIn, !isStarting { startPageMoved(afresh: false) }
    }

    /// Counts each time no showing holds the page any more (#2089), for a showing still on
    /// screen to hear it and hold it again.
    private(set) var startPageLetGo = 0

    /// The showing of the page that holds `startingIn` (#1044). The detail is rebuilt with
    /// each pick, and the page it replaced can say it went after the new one said it came:
    /// only the showing that holds the page lets it go.
    @ObservationIgnored private var startPage = PageHold<URL>()

    /// The page came on screen. Opened afresh each time, even in the same folder: a
    /// showing that went without saying so left nothing this one can trust.
    func startPageAppeared(in folder: URL, page: UUID) {
        startPage.appeared(folder, showing: page)
        note("start: page appeared for \(folder.lastPathComponent)")
        guard startingIn == folder else { startingIn = folder; return }
        closeStart()
        queueOpenStart(folder)
    }

    /// A showing that said it went is still on screen (#2089), and nothing holds the page:
    /// it holds it again. Not one whose agent has started, which is on its way out, nor
    /// while one starts.
    func startPageStillShown(in folder: URL, page: UUID) {
        guard startingIn == nil, !isStarting, !startedPages.contains(page),
              startPagesWanted.contains(folder) else { return }
        note("start: page still shown for \(folder.lastPathComponent), held again")
        startPageAppeared(in: folder, page: page)
    }

    /// The showings whose Send started an agent: they are going, and never hold the page again.
    @ObservationIgnored private var startedPages: Set<UUID> = []
    /// The showing whose Send is starting an agent.
    @ObservationIgnored private var startingPage: UUID?

    /// The page went. Nothing, when another showing has taken it since.
    func startPageDisappeared(_ page: UUID) {
        if startPage.disappeared(page) { startPageMoved(afresh: false) }
    }

    /// What a ui:// view filled the page with (#834), for the page in its folder to take
    /// once it is on screen. The person still presses Start.
    struct OfferedStart: Equatable {
        let folder: URL
        let start: AppViewStart
    }

    private(set) var offeredStart: OfferedStart?
    /// The offered worktree's name, chosen once the page's repository has answered: before
    /// then the page has no Worktree row, and opening it puts the place back.
    @ObservationIgnored private var offeredWorktree: (folder: URL, choice: WorktreeChoice)?

    /// Open the New session page in a view's folder, filled in (#834), as New Session
    /// opens it. Why it did not open, or nil.
    func offerStart(_ start: AppViewStart, in key: FolderKey) -> String? {
        guard let summary = work.folder(key) else { return "This folder isn’t one the phone knows." }
        guard !isStarting else { return "An agent is starting. Try again once it has." }
        offeredStart = OfferedStart(folder: summary.folder.folder, start: start)
        offeredWorktree = start.worktreeChoice.map { (folder: summary.folder.folder, choice: $0) }
        sidebarItem = .folder(summary.key)
        // Already open in this folder: its repository is asked again for the worktree.
        if start.worktreeChoice != nil, startingIn == summary.folder.folder {
            Task { await loadStartWorktrees(in: summary.folder.folder) }
        }
        return nil
    }

    /// The session a view's `agents/message-agent` goes to (#837): on the branch, in this folder.
    func recipient(of message: AppViewAgentMessage, in key: FolderKey) -> AppViewRecipient? {
        message.recipient(among: work.agents, host: key.host, folder: key.folder)
            .map { AppViewRecipient(id: $0.id, name: AppViewAgentMessage.name(of: $0)) }
    }

    /// The offer for the page in `folder`, taken once.
    func takeOfferedStart(in folder: URL) -> AppViewStart? {
        guard let offered = offeredStart, offered.folder == folder else { return nil }
        offeredStart = nil
        return offered.start
    }

    enum StartChoicesState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// The runtime the page will start. Seeded by the kit's rule from the one it was last
    /// left on (#264), as the window's start form and the page's.
    private(set) var startRuntimeID: String?
    private static let keptStartRuntime = DisplayPreference.startRuntimeID
    /// The choices follow the person to every client (#1033), kept on the Mac.
    private func persistStartChoices() {
        guard !startChosen.isEmpty, let startRuntimeID else { return }
        var choices = displayMirror.preferences[DisplayPreference.startChoices]?.objectValue ?? [:]
        guard choices[startRuntimeID] != .object(startChosen) else { return }
        choices[startRuntimeID] = .object(startChosen)
        displayMirror.set([DisplayPreference.startChoices: .object(choices)])
    }
    /// What that runtime offers, in the order they are drawn.
    private(set) var startOptions: [ConfigOption] = []
    /// What has been chosen, by option id. Sent as the start's options.
    private(set) var startChosen: [String: JSONValue] = [:] { didSet { persistStartChoices() } }
    var startFolders: [URL] = UserDefaults.standard.stringArray(forKey: "remote.startFolders")?.map { URL(fileURLWithPath: $0) } ?? [] {
        didSet { UserDefaults.standard.set(startFolders.map(\.path), forKey: "remote.startFolders") }
    }
    /// The new agent's own sandbox choice (064). Nil follows its runtime's default.
    var startSandbox: SandboxChoice?
    /// Each runtime's sandbox default, read from the Mac, for "Use runtime default (Off)".
    private(set) var sandboxSettings = SandboxSettings()
    /// The Mac-wide permission choice for Cursor, Grok and OpenCode (061).
    private(set) var clientPermissions = ClientPermissionSettings()
    /// The organisation's policy as the Mac's host follows it (#998): the red strip on every
    /// page and the composer's reason while the kill switch is on. Nil from an older Mac.
    private(set) var policyState: DaemonAPI.PolicyState?
    /// The person's own pass-through names on the Mac, each marked when the policy refuses it (#998).
    private(set) var passThrough = DaemonAPI.PassThroughState()
    private(set) var startChoicesState: StartChoicesState = .loading
    /// Why the last Send did not start anything, in one sentence. Shown in the page
    /// rather than as the app's alert.
    private(set) var startRefusal: String?
    /// A start sent whose answer never came back. Its request id is reused by every
    /// retry, so the Mac answers with the agent the first one made rather than
    /// starting the work twice.
    private(set) var unsettledStart: DaemonAPI.StartRequest?
    private(set) var isStarting = false
    /// Where in the folder the new agent works, when not the folder (030).
    /// Decided per agent, so it goes back to the folder each time the page
    /// opens and after every start.
    private(set) var startWorktree: WorktreeChoice?
    /// What the page's folder's repository has, for the Worktree row. Not a
    /// repository until the Mac says otherwise, which keeps the row hidden.
    private(set) var startWorktrees: DaemonAPI.WorktreesListResponse = .notARepository
    private var startDraftID: UUID?
    /// The host `startDraftID` was made on: the page's folder's (#240).
    private var startDraftHost: MachineRef = .mac
    /// Bumped by every fetch of a runtime's choices, so an answer for a runtime the
    /// person has since moved off is recognised as that and let go.
    private var startGeneration = 0

    /// The kinds of session the page's folder offers (#760), the folder's and the
    /// home's as its host lists them, and the one picked, by id.
    private(set) var startPersonas: [Persona] = []
    private(set) var startPersona: String?
    /// Picked while its runtime's choices were still to come: laid over them on arrival.
    private var pendingStartPersona: Persona?

    var startRuntime: RuntimeStatus? { startRuntimes.first { $0.runtime.id == startRuntimeID } }

    /// What the page offers: the runtimes of the folder's own host, the Mac's or a
    /// server's, as the window lists them (#240).
    var startRuntimes: [RuntimeStatus] { runtimes(on: startHost) }

    private var startAvailableRuntimeIDs: [String] {
        startRuntimes.filter(\.canStart).map(\.runtime.id)
    }

    /// What the page reads: the runtimes to choose from, and, for its runtime menu, what
    /// the Mac's allowances say, before it is opened rather than after whoever happens to
    /// visit the Runtimes page.
    private static let startParts: Set<CatchUpPart> = [.runtimes, .allowances, .modes, .sandbox]

    /// Opens the page, numbered as it is queued: an open queued before a later one is let go.
    private func queueOpenStart(_ folder: URL) {
        startOpens += 1
        let open = startOpens
        Task { await openStart(in: folder, open: open) }
    }

    private func openStart(in folder: URL, open: Int) async {
        guard open == startOpens else { return }
        startOpenedAt = .now
        startOpenedOn = startHost
        startAsks.opened()
        startRefusal = nil
        startWorktree = nil
        startWorktrees = .notARepository
        Task { await loadStartWorktrees(in: folder) }
        startPersona = nil
        pendingStartPersona = nil
        startPersonas = []
        Task { await loadStartPersonas(in: folder) }
        // Each with a deadline, and waited on only when the page has no runtimes to pick
        // from yet (#1096): one lost reply here used to hold the page on "Asking…" before
        // it had asked anything, with nothing that would ask again.
        let listPatience = StartPageAsks.patience(for: DaemonAPI.Method.runtimesList)
        if !startShowsParts {
            startShowsParts = true
            let parts = Task {
                await DaemonClient.$patience.withValue(listPatience) { await showing(Self.startParts) }
            }
            if startRuntimes.isEmpty { await parts.value }
        }
        // A server's list is not one of the parts: asked as its page opens (#977), and
        // waited on only when the page has none of its runtimes yet (#1171).
        if startHost != .mac {
            let host = startHost
            let listed = Task { await DaemonClient.$patience.withValue(listPatience) { await refreshServerRuntimes(host) } }
            if startRuntimes.isEmpty { await listed.value }
        }
        // Said, so a page left with no choices can be read from the log (#2089).
        guard startingIn == folder else {
            note("start: open of \(folder.lastPathComponent) gave way to \(startingIn?.lastPathComponent ?? "nothing")")
            return
        }
        // A later open of the page asks for the choices; one draft, not two.
        guard open == startOpens else { return }
        startRuntimeID = pickedStartRuntime
        startPicked = true
        if startRuntimeID == nil {
            note("start: no runtime to pick, \(startAvailableRuntimeIDs.count) of \(startRuntimes.count) can start")
        }
        await loadStartChoices()
    }

    /// Counts the page's opens, so only the last asks for its choices.
    @ObservationIgnored private var startOpens = 0
    /// The host the open page asked for runtimes, as it knew the folder then.
    @ObservationIgnored private var startOpenedOn: MachineRef?

    /// The folder list came after the page opened (#2089): a page that took the Mac's
    /// runtimes for a server's folder opens again on its own host's.
    private func startHostMoved() {
        guard let folder = startingIn, let opened = startOpenedOn, opened != startHost, !isStarting else { return }
        note("start: \(folder.lastPathComponent) is on \(hostName(startHost)), not \(hostName(opened)); opened again")
        closeStart()
        queueOpenStart(folder)
    }

    /// The runtime this page is on while it can start; when it first opens, use the most
    /// recently active runtime on this folder's host, then the kept choice (#264).
    private var pickedStartRuntime: String? {
        RuntimeCatalog.startFormRuntime(current: startRuntimeID,
                                        lastUsed: work.lastRuntimes[startHost],
                                        kept: UserDefaults.standard.string(forKey: Self.keptStartRuntime),
                                        available: startAvailableRuntimeIDs)
    }

    /// Set once the open page has picked its runtime, so a list that changes after that
    /// picks again rather than racing the opening.
    @ObservationIgnored private var startPicked = false

    /// The page's host listed its runtimes, or could not (#977). A page that opened before
    /// they came (during a reconnect, or just after launch) picks one now and asks it for its
    /// choices, rather than staying on "None set up" until it is closed and opened again.
    private func startRuntimesMoved() {
        guard startPicked, startingIn != nil else { return }
        let picked = pickedStartRuntime
        // With none to pick, the page's sentence is said again, for a list that failed.
        guard picked != startRuntimeID || picked == nil else { return }
        startRuntimeID = picked
        Task { await loadStartChoices() }
    }

    /// Back in touch (#1044): a page whose choices, personas or worktrees failed, or never
    /// came, asks again for each, as Try again would, rather than staying dead until the
    /// app is killed. A reply lost with the link is one that never came (#1096).
    private func reopenStartChoices() async {
        guard startPicked, let folder = startingIn, !isStarting else { return }
        let again = startAsks.toAskAgain
        guard !again.isEmpty else { return }
        note("start: back in touch; asking again for \(again.map(\.rawValue).sorted().joined(separator: ", "))")
        if again.contains(.personas) { Task { await loadStartPersonas(in: folder) } }
        if again.contains(.worktrees) { Task { await loadStartWorktrees(in: folder) } }
        guard again.contains(.choices) else { return }
        if startRuntimeID == nil { startRuntimeID = pickedStartRuntime }
        await loadStartChoices()
    }

    /// What the page has been answered since it opened (#1096).
    @ObservationIgnored private var startAsks = StartPageAsks()

    /// What each runtime offered the page last time, on each host (#1171): the page is
    /// drawn from it at once and put right by the draft's answer.
    @ObservationIgnored private var startMemory = StartChoicesMemory()
    /// When the page opened, until its rows are drawn: said in the log as how long that took.
    @ObservationIgnored private var startOpenedAt: ContinuousClock.Instant?

    /// One of the page's own calls (#1096): with a deadline, failed at once when the link
    /// drops under it, and said in the log with how long it took, so a page that stays on
    /// "Asking…" can be read from it.
    private func askForStart<T: Decodable>(_ method: String, _ params: some Encodable & Sendable,
                                           returning: T.Type) async throws -> T {
        let began = ContinuousClock.now
        note("start: \(method) sent")
        do {
            // Decoded here: the type's conformance may be this actor's own.
            let answer = try await client(for: params).callWithin(StartPageAsks.patience(for: method), method, params,
                                                                  returning: JSONValue.self).decode(T.self)
            note("start: \(method) answered in \(ContinuousClock.now - began)")
            return answer
        } catch {
            note("start: \(method) failed after \(ContinuousClock.now - began): \(error)")
            throw error
        }
    }

    /// Try again on the page: with no runtime to ask, the host's list is read again first.
    func retryStartChoices() async {
        if startRuntimeID == nil {
            if startHost == .mac { await refreshRuntimes() } else { await refreshServerRuntimes(startHost) }
            startRuntimeID = pickedStartRuntime
        }
        await loadStartChoices()
    }

    /// Put the page away. Its runtime is let go; what was typed is the keeper's.
    @ObservationIgnored private var startShowsParts = false

    private func closeStart() {
        startPicked = false
        startOpenedOn = nil
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

    /// The repository's worktrees for the page. Asked once when it opens, never polled.
    private func loadStartWorktrees(in folder: URL) async {
        let request = DaemonAPI.WorktreesListRequest(folder: folder)
        startAsks.asking(.worktrees)
        let answer: DaemonAPI.WorktreesListResponse
        do {
            answer = try await askForStart(DaemonAPI.Method.worktreesList, request,
                                           returning: DaemonAPI.WorktreesListResponse.self)
            guard startingIn == folder else { return }
            startAsks.answered(.worktrees)
        } catch {
            // Not a repository until the Mac says otherwise; asked again once it answers.
            guard startingIn == folder else { return }
            answer = .notARepository
        }
        startWorktrees = answer
        // A view's worktree (#834), when there is a repository to make it in.
        if let offered = offeredWorktree, offered.folder == folder {
            offeredWorktree = nil
            if answer.isRepository { await chooseWorktree(offered.choice) }
        }
    }

    /// The folder's personas (#760). A host too old to know the method offers none; one
    /// that did not answer is asked again once it does (#1096).
    private func loadStartPersonas(in folder: URL) async {
        let request = DaemonAPI.PersonasListRequest(folder: folder)
        startAsks.asking(.personas)
        let listed: [Persona]
        do {
            listed = try await askForStart(DaemonAPI.Method.personasList, request, returning: [Persona].self)
        } catch let error as JSONRPCError where error.isMethodNotFound {
            listed = []
        } catch {
            return
        }
        guard startingIn == folder else { return }
        startAsks.answered(.personas)
        startPersonas = listed
    }

    func agentConfigEditorFiles(in folder: URL?, kind: DaemonAPI.AgentConfigEditorKind)
        async -> [DaemonAPI.AgentConfigEditorFile]? {
        let request = DaemonAPI.AgentConfigEditorRequest(folder: folder, kind: kind)
        return try? await client(for: request).call(DaemonAPI.Method.agentConfigEditorFiles, request,
                                                     returning: [DaemonAPI.AgentConfigEditorFile].self)
    }

    func saveAgentConfigEditorFile(in folder: URL?, kind: DaemonAPI.AgentConfigEditorKind,
                                   path: String, content: String, delete: Bool) async -> String? {
        let request = DaemonAPI.AgentConfigEditorSaveRequest(folder: folder, kind: kind, path: path,
                                                               content: content, delete: delete)
        do {
            try await client(for: request).call(DaemonAPI.Method.agentConfigEditorSave, request)
            await refreshWorkflows()
            return nil
        } catch { return String(describing: error) }
    }

    /// Pick a kind of session (#760): every setting it names is set, every one it leaves
    /// out stays as the page has it. Nil picks none and changes nothing else.
    func choosePersona(_ persona: Persona?) async {
        startPersona = persona?.id
        pendingStartPersona = nil
        guard let persona else { return }
        if let runtimeID = persona.settings.runtimeID, runtimeID != startRuntimeID,
           startAvailableRuntimeIDs.contains(runtimeID) {
            pendingStartPersona = persona
            await chooseRuntime(runtimeID)
            return
        }
        if startChoicesState != .ready {
            pendingStartPersona = persona
        } else {
            startChosen.merge(persona.choices(against: startOptions)) { _, new in new }
        }
    }

    /// The branch an agent's folder is on, for the place over its prompt (#242).
    /// Nil outside a repository or when its host does not answer.
    func folderPathBranch(of agent: Agent) async -> String? {
        let request = DaemonAPI.WorktreesListRequest(folder: agent.folderPath)
        return (try? await client(for: request).call(DaemonAPI.Method.worktreesList, request,
                                                     returning: DaemonAPI.WorktreesListResponse.self))?
            .folderPathBranch
    }

    /// Where the draft is made: in a worktree already there when one is chosen, so the
    /// start can use it; otherwise the folder (030, research R2).
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
        UserDefaults.standard.set(runtimeID, forKey: Self.keptStartRuntime)
        startAccountID = nil
        startSandbox = nil
        startRefusal = nil
        await loadStartChoices()
    }

    func choose(_ value: JSONValue, for optionID: String) {
        startChosen[optionID] = value
    }

    /// A runtime is started behind the form so its choices are real ones; the start
    /// that follows uses it. Drawn at once from what it offered this page last time
    /// (#1171), then from the host's answer, and put right by `agents/draftOptions` if
    /// it has moved. A Send before the answer starts without the draft, with the
    /// choices on the page.
    func loadStartChoices() async {
        guard let folder = startOptionsFolder else { return }
        guard let runtimeID = startRuntimeID else {
            // Not "asking": there is nobody to ask.
            let host = startHost == .mac ? "the Mac" : hostName(startHost)
            if startRuntimes.isEmpty, let failure = runtimesFailure[startHost] {
                startChoicesState = .failed("Could not list the runtimes on \(host). \(failure)")
                return
            }
            startChoicesState = .failed(startRuntimes.isEmpty
                ? "No runtimes are set up on \(host). Set one up there to start an agent."
                : "None of \(host)'s runtimes can start right now.")
            return
        }
        startGeneration += 1
        let generation = startGeneration
        startAsks.asking(.choices)
        discardStartDraft()
        let host = startHost
        startChosen = displayMirror.preferences[DisplayPreference.startChoices]?.objectValue?[runtimeID]?.objectValue ?? [:]
        let remembered = startMemory.options(for: runtimeID, on: host)
        if let remembered {
            showStart(remembered, opening: true, answered: false)
        } else {
            startOptions = []
            startChoicesState = .loading
        }
        do {
            // Made on the folder's own host, where the agent will start (#240).
            let request = DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: folder)
            let response = try await askForStart(DaemonAPI.Method.agentsOptions, request,
                                                 returning: DaemonAPI.OptionsResponse.self)
            guard generation == startGeneration else { discard(draft: response.draftID, on: host); return }
            startDraftID = response.draftID
            startDraftHost = host
            startMemory.remember(response.options, for: runtimeID, on: host)
            // Over choices made from memory meanwhile: only the first draw opens.
            showStart(response.options, opening: remembered == nil)
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
    ///
    /// `answered` is false for a draw from memory: the host has still to say.
    private func showStart(_ options: [ConfigOption], opening: Bool = false, answered: Bool = true) {
        startOptions = PromptControlsState.drawable(agentOptions: nil, draftOptions: options)
        var kept = StartChoicesMemory.kept(startChosen, in: startOptions)
        if opening, let runtimeID = startRuntimeID, let mode = ModeMemory.modeOption(in: startOptions),
           let value = ModeMemory.startingValue(remembered: work.rememberedMode(for: runtimeID), for: mode) {
            kept[mode.id] = value
        }
        // Over the mode remembered, because the persona was picked after it (#760).
        if let persona = pendingStartPersona, !startOptions.isEmpty {
            kept.merge(persona.choices(against: startOptions)) { _, new in new }
            pendingStartPersona = nil
        }
        startChosen = kept
        startChoicesState = .ready
        if let openedAt = startOpenedAt {
            startOpenedAt = nil
            note("start: page ready \(answered ? "from the host" : "from memory") in \(ContinuousClock.now - openedAt)")
        }
        if answered { startAsks.answered(.choices) }
    }

    private func settleStartDraft(_ notification: DaemonAPI.DraftOptionsNotification) {
        guard notification.draftID == startDraftID else { return }
        if let failure = notification.failure {
            startDraftID = nil
            startOptions = []
            startChosen = [:]
            startChoicesState = .failed(failure)
            startAsks.asking(.choices)
            return
        }
        if let runtimeID = startRuntimeID {
            startMemory.remember(notification.options, for: runtimeID, on: startDraftHost)
        }
        showStart(notification.options)
    }

    private func discardStartDraft() {
        guard let startDraftID else { return }
        self.startDraftID = nil
        discard(draft: startDraftID, on: startDraftHost)
    }

    /// Not waited on: the page has moved on, and a Mac too old to know the method has
    /// nothing to be told. To the host the draft was made on (#240).
    private func discard(draft: UUID, on host: MachineRef) {
        let target = host == .mac ? client : otherHosts[host] ?? client
        Task { _ = try? await target.call(DaemonAPI.Method.agentsDiscardDraft,
                                          DaemonAPI.DiscardDraftRequest(draftID: draft)) }
    }

    /// Start an agent in the page's folder. Answers whether it started, so the page
    /// keeps what was typed when it did not.
    ///
    /// Refused here, before anything is sent, when the Mac is not answering or the
    /// folder cannot take a new agent. Refused by the Mac, its sentence is shown as it
    /// is. Lost on the way back, nothing is assumed: the start is kept, and settled by
    /// its request id once the Mac is heard from again.
    func startAgent(prompt: String, attachments: [Attachment] = [], labels: [String] = [],
                    in folder: URL, page: UUID) async -> Bool {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !isStarting else { return false }
        // On screen but not held (#1044): held again, and said, rather than a Send that
        // does nothing.
        guard let folder = startingIn, folder == folder else {
            startPageAppeared(in: folder, page: page)
            startRefusal = "This page was opened again. Check its choices, then send."
            return false
        }
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
        // The unsettled start's id only for the same folder: sent again there, the Mac
        // answers with the agent it made if it made one. Anywhere else it is a new
        // start, and reusing the id would be answered with the other folder's agent.
        let retrying = unsettledStart?.cwd == folder ? unsettledStart?.requestID : nil
        let request = DaemonAPI.StartRequest(
            runtimeID: runtimeID, cwd: folder, prompt: words, attachments: attachments,
            startOptions: StartOptions(values: startChosen), draftID: startDraftID,
            additionalDirectories: startFolders, worktree: startWorktree, requestID: retrying ?? UUID(), sandbox: startSandbox,
            labels: labels, persona: startPersona,
            accountID: startAccountChoices?.sent(startAccountID))
        startingPage = page
        defer { startingPage = nil }
        return await send(start: request)
    }

    func setLabels(on id: UUID, add: [String] = [], remove: [String] = []) async -> Bool {
        do {
            let request = DaemonAPI.SetLabelsRequest(agentID: id, add: add, remove: remove)
            let agent: Agent = try await client(for: request).call(DaemonAPI.Method.agentsSetLabels, request,
                                                                   returning: Agent.self)
            work.upsert(agent)
            await loadLabelVocabulary(in: agent.folderPath)
            return true
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That label change did not reach your Mac."
            return false
        }
    }

    func labelSuggestions(in folder: URL) -> [String] {
        labelVocabularies[Folder.standardize(folder)] ?? []
    }

    func loadLabelVocabulary(in folder: URL) async {
        let folder = Folder.standardize(folder)
        let request = DaemonAPI.LabelVocabularyRequest(folder: folder)
        guard let values = try? await client(for: request).call(DaemonAPI.Method.agentsLabelVocabulary, request,
                                                                returning: [String].self) else { return }
        labelVocabularies[folder] = values
    }

    private func send(start request: DaemonAPI.StartRequest) async -> Bool {
        isStarting = true
        defer { isStarting = false }
        startRefusal = nil
        // Its Live Activity begins once the Mac says which session it made (#1657).
        if let requestID = request.requestID { liveActivities.askedToStart(requestID) }
        // A stopped workspace that starts when used: kept, and shown on this page until the
        // agent it makes opens (#691 US3, layouts.md L6a).
        if let host = work.folder(request.cwd)?.host, host != .mac, isStale(on: host), startsWhenUsed(host) {
            var kept = request
            kept.draftID = nil
            guard let said = await keepThroughControl(host, DaemonAPI.Method.agentsStart, kept) else { return false }
            keptStartsShown.insert(said.id)
            StartDraftKeeper.shared.clear(in: request.cwd)
            return true
        }
        unsettledStart = request
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsStart, request).decode(UUID.self)
            // Taken by the start. One that answered after the Send (#1171) is let go as the
            // page closes.
            if startDraftID == request.draftID { startDraftID = nil }
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
            // Out of patience too (#208): the page is let go, and the start is settled
            // when the host is back, by its `requestID`.
            startRefusal = "\((error as? HostAway).map { hostName($0.host) } ?? "Your Mac") stopped answering before it said whether the agent "
                + "started. This will be checked when it is back."
            return false
        }
    }

    /// - Parameter open: go to it. True when the person is waiting on the page; false
    ///   when a lost answer is settled later, perhaps while they read something else,
    ///   and taking the screen from them would be the surprise.
    private func started(_ id: UUID, in folder: URL, open: Bool = true) async {
        // The last folder used is the one a session was started in, from any window (#2160).
        if let key = work.folder(folder)?.key ?? work.agent(id).map({ FolderKey(host: $0.host, folder: folder) }) {
            rememberNewSessionFolder(key)
        }
        unsettledStart = nil
        startWorktree = nil
        // Only now: a draft is kept until the agent it was typed for exists (FR-017).
        StartDraftKeeper.shared.clear(in: folder)
        guard open else { return }
        await loadWholeAgent(id)
        // The page that started it goes; one still on screen under it is opened again.
        if let startingPage { startedPages.insert(startingPage) }
        startPage.release()
        startPageMoved(afresh: true)
        // Started in a folder's own scene: it opens there (#1089).
        if let scene = composingScene.flatMap({ folderScenes[$0] }), scene.key.folder == folder {
            scene.pick = .session(id)
            return
        }
        selectedFolder = folder
        openWorkflow = nil
        // In the start page's place, which is the detail's own: no sheet to wait out (#366).
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
        let host = work.folder(folder)?.host ?? .mac
        if isStale(on: host), !(host != .mac && startsWhenUsed(host)) { return notAnswering(host, "nothing was started.") }
        guard let summary = work.folder(folder) else { return nil }
        if summary.folder.isArchived { return "This folder was archived on the Mac, so nothing was started." }
        if !summary.exists { return "This folder is not on the Mac any more, so nothing was started." }
        if let runtime = startRuntime, let reason = runtime.unavailableReason {
            return "\(runtime.runtime.name) cannot start: \(reason)"
        }
        return nil
    }

    private func sentence(for error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? "Your Mac did not answer."
    }

    /// Start a Machine from a Repository (#1809): its calls over the control plane, or nil
    /// while it isn't answering.
    var machineCalls: MachineFromRepositorySheet.Calls? { controlPlane.map(MachineFromRepositorySheet.Calls.through) }

    /// A refusal in the Remote's words.
    func refusal(_ error: any Error) -> String { sentence(for: error) }

    // MARK: The Mac's runtimes (029)

    /// Every runtime the Mac knows, in the Mac's order, startable or not. The start
    /// page lists the ones that cannot start too, with why, because a runtime that
    /// silently is not there reads as one the phone forgot.
    private(set) var runtimes: [RuntimeStatus] = [] { didSet { startRuntimesMoved() } }
    private var accounts: [String: RuntimeAccount] = [:]
    /// The accounts of the Mac's runtimes (#840), beside each runtime's own sign-in, the
    /// organisation's included (#999).
    private(set) var accountProfiles: [AccountProfile] = [] {
        didSet { accountProfilesRead = true }
    }
    /// Whether the Mac has listed them yet: until then no session is told its account is gone.
    private(set) var accountProfilesRead = false
    /// The account the start page uses (#840, #999), as `AccountChoices` keeps a choice: nil
    /// for the runtime's account for new sessions.
    var startAccountID: String?
    /// The accounts the start page's runtime offers beyond its own sign-in: the Mac's, so
    /// none for a server's folder. The picker shows only when there is one.
    var startAccounts: [AccountProfile] { startAccountChoices?.accounts ?? [] }
    var startAccountChoices: AccountChoices? {
        guard startHost == .mac, let startRuntimeID else { return nil }
        return AccountChoices(runtimeID: startRuntimeID, profiles: accountProfiles, policy: policyState?.policy)
    }

    /// Why a session on the Mac can no longer reach the model on its account (#999): the
    /// organisation removed it, or its policy refuses it now. Nil when it can.
    func accountMoveReason(_ agent: Agent) -> String? {
        guard agent.host == .mac, agent.state != .archived else { return nil }
        return AccountChoices(runtimeID: agent.runtimeID, profiles: accountProfiles, policy: policyState?.policy)
            .moveReason(accountID: agent.accountID, loaded: accountProfilesRead)
    }

    /// **Reaches the Model By** (#999): one of the Mac's runtimes' account for new sessions,
    /// nil for its own sign-in. Nil when it was set; else why not.
    func setDefaultAccount(runtimeID: String, accountID: String?) async -> String? {
        do {
            _ = try await client.call(DaemonAPI.Method.runtimesSetDefaultAccount,
                                      DaemonAPI.DefaultAccountRequest(runtimeID: runtimeID,
                                                                      accountID: accountID ?? AccountProfile.ownSignInID),
                                      returning: DaemonAPI.Empty.self)
            await refreshAccountProfiles()
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    func refreshAccountProfiles() async {
        if let listed = try? await client.call(DaemonAPI.Method.runtimesAccountProfiles, Optional<Int>.none,
                                               returning: [AccountProfile].self) {
            accountProfiles = listed
        }
    }

    /// Add an account to one of the Mac's runtimes (#840). Nil when it was added; else why not.
    func addAccount(runtimeID: String, name: String) async -> String? {
        do {
            let added = try await client.call(DaemonAPI.Method.runtimesAddAccount,
                                              DaemonAPI.AddAccountRequest(runtimeID: runtimeID, name: name),
                                              returning: AccountProfile.self)
            accountProfiles.removeAll { $0.id == added.id }
            accountProfiles.append(added)
            await refreshRuntimeAllowances()
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    /// The Mac's sessions an added account is running, which removing it stops (#2264).
    func agentsHolding(account: AccountProfile) -> [Agent] {
        work.agents.filter { $0.host == .mac && $0.accountID == account.id && $0.state.holdsRuntime }
    }

    func removeAccount(_ account: AccountProfile) async {
        do {
            _ = try await client.call(DaemonAPI.Method.runtimesRemoveAccount,
                                      DaemonAPI.AccountRequest(runtimeID: account.runtimeID, accountID: account.id),
                                      returning: [UUID].self)
        } catch {
            problem = sentence(for: error)
        }
        await refreshAccountProfiles()
        await refreshRuntimeAllowances()
    }

    /// Each other host's runtimes, as it last listed them (#240): a server folder's
    /// start page offers its server's, as the window's does (037).
    private(set) var serverRuntimes: [MachineRef: [RuntimeStatus]] = [:] { didSet { startRuntimesMoved() } }
    /// Why a host's last `runtimes/list` failed, until one is answered (#977): the start
    /// page says that, rather than "None set up".
    private var runtimesFailure: [MachineRef: String] = [:] { didSet { startRuntimesMoved() } }

    func runtimes(on host: MachineRef) -> [RuntimeStatus] {
        host == .mac ? runtimes : serverRuntimes[host] ?? []
    }

    private func refreshServerRuntimes(_ host: MachineRef) async {
        guard let other = otherHosts[host] else { return }
        do {
            let listed = try await other.call(DaemonAPI.Method.runtimesList, Optional<String>.none,
                                              returning: [RuntimeStatus].self)
            serverRuntimes[host] = RuntimeCatalog.sortedByName(listed)
            runtimesFailure[host] = nil
        } catch {
            runtimesFailure[host] = (error as? JSONRPCError)?.message ?? "\(hostName(host)) did not answer."
        }
    }

    /// What this runtime says it will take in a prompt, as the Mac reads it. Nothing
    /// is refused on a guess: unknown is the protocol's baseline.
    func promptCapabilities(for runtimeID: String?) -> ACP.PromptCapabilities {
        runtimeID.flatMap { accounts[$0]?.promptCapabilities } ?? ACP.PromptCapabilities()
    }

    /// Whether this runtime is signed in, as the window's runtime list says it (#538):
    /// "Needs signing in", else the account it is using ("Claude Max"). The accounts
    /// are the Mac's own.
    func signInNote(for runtimeID: String) -> String? {
        let account = accounts[runtimeID]
        if account?.state == .needsSignIn { return "Needs signing in" }
        return account?.signedInAs?.label
    }

    /// Whether this runtime said it takes words in the middle of a turn.
    func canSteer(_ runtimeID: String?) -> Bool {
        runtimeID.flatMap { accounts[$0]?.canSteer } ?? false
    }

    /// A folder's counts from the same grouping its page uses, so the list and the
    /// page cannot disagree about what needs attention.
    func counts(in folder: URL?) -> [AgentGroup: Int] { work.counts(in: folder) }
    func counts(in key: FolderKey) -> [AgentGroup: Int] { work.counts(in: key) }

    /// Whether the Mac is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

    /// "Started by …" for an agent another agent started, and nil otherwise (028).
    func startedByAgentLabel(_ agent: Agent) -> String? { work.startedByAgentLabel(agent) }

    /// Whether the menu offers Stop: the same answer the Mac gives.
    func canStop(_ agent: Agent) -> Bool { work.canStop(agent) }
    func blockLines(_ agent: Agent) -> [String] { work.blockLines(agent) }
    func queuedLine(_ agent: Agent) -> String? { work.queuedLine(agent) }
    func isBlocked(_ agent: Agent) -> Bool { work.openBlock(agent) != nil }
    /// End a block by hand (039), as the person. See the Mac's `carryOn`.
    func carryOn(_ agentID: UUID) async { _ = await send(Block.carryOnPrompt, to: agentID) }

    /// What a guarded file was and is (#502), for the person deciding.
    func readGuardedChange(_ change: GuardedChange, for key: FolderKey) async -> GuardedChangeReading? {
        let request = DaemonAPI.GuardedChangeRequest(folder: key.folder, path: change.path)
        do {
            return try await client(for: request).call(DaemonAPI.Method.foldersReadGuardedChange, request,
                                                       returning: GuardedChangeReading.self)
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// Keep (the change is used from now on) or Undo (the approved copy goes back), of the
    /// file as the person was shown it (#531). The folder's summary that comes back with
    /// it, or after it, takes the question away.
    func settleGuardedChange(_ reading: GuardedChangeReading, keep: Bool, for key: FolderKey) async {
        let request = DaemonAPI.GuardedChangeRequest(folder: key.folder, path: reading.path, digest: reading.digest)
        do {
            var summary: DaemonAPI.FolderSummary = try await client(for: request).call(
                keep ? DaemonAPI.Method.foldersKeepGuardedChange : DaemonAPI.Method.foldersUndoGuardedChange,
                request, returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            work.upsert(summary)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// What a waiting item in Needs You is (#773), for the person deciding.
    func readApproval(_ approval: Approval, for key: FolderKey) async -> GuardedChangeReading? {
        let request = ApprovalReadRequest(folder: key.folder, kind: approval.kind, key: approval.key)
        do {
            return try await client(for: request).call(DaemonAPI.Method.approvalsRead, request,
                                                       returning: GuardedChangeReading.self)
        } catch {
            problem = sentence(for: error)
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
            var summary: DaemonAPI.FolderSummary = try await client(for: answer).call(
                DaemonAPI.Method.approvalsAnswer, answer, returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            work.upsert(summary)
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    /// Approve or Deny from a row's long press, of the version the row shows.
    func settleApproval(_ approval: Approval, _ action: Approval.Action, for key: FolderKey) async {
        if let why = await answerApproval(approval, action, digest: approval.digest, note: nil, for: key) { problem = why }
    }

    /// Deny a session's ask to be archived (#773): the mark goes and the session stays.
    func keepSession(_ agent: Agent) async {
        let denial = ArchiveActions.denial(for: agent)
        await settleApproval(denial.approval, .deny, for: denial.folder)
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
        // And a scene of its own's page of it (#888).
        if let popped = popouts[agentID] { for entry in popped.work.entries { touched.absorb(entry) } }
        return touched
    }

    /// Read the part of the conversation the chat has not loaded, once, so a file the
    /// agent edited an hour ago is marked here as it is on the Mac (research §5). Paged,
    /// backwards, as "load earlier" is; kept apart from the chat's own page.
    func loadTouchedHistory(for agentID: UUID) async {
        guard !touchedHistoryAsked.contains(agentID) else { return }
        touchedHistoryAsked.insert(agentID)
        let request = DaemonAPI.AgentRequest(agentID: agentID)
        guard let paths = try? await client(for: request).call(
            DaemonAPI.Method.agentsTouchedPaths, request, returning: [String].self) else {
            touchedHistoryAsked.remove(agentID)
            return
        }
        touchedEarlier[agentID] = TouchedPaths(paths: paths)
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

    /// A file shown in the chat, opened again from its card (#836).
    func openShownFile(_ file: ShownFile) {
        guard let selection else { return }
        work.rememberChart(file)
        open(file, for: selection)
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

    /// Which way `link` last connected: its control plane connection's route, and
    /// direct for a link that has no relay (#883).
    nonisolated static func route(of link: any DaemonLink) -> RemoteLink {
        guard let control = link as? ControlPlaneLink, control.route.current != .none else { return .direct }
        return control.route.current
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
            link = Self.route(of: baseLink)
            note("link: connected \(link) after \(ContinuousClock.now - began)")
            refusals.connected()
            // A home host that is a server asks for a key as any other server does (#344).
            await client.setCredentialLender { [weak self] wanted in
                await self?.answerHomeCredentialWanted(wanted) ?? false
            }
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
            let reason = ControlPlaneLink.refused.take()
            // Suspended by the organisation (#1002): only that, with the pairing kept.
            signIn.refused(reason)
            if let reason, refusals.forgets(after: reason) {
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
    private func otherHost(named params: some Encodable) -> MachineRef? {
        guard !controlHosts.isEmpty, let value = try? JSONValue.encoding(params) else { return nil }
        if let id = (value["agentID"] ?? value["id"])?.stringValue.flatMap(UUID.init(uuidString:)),
           let host = work.agent(id)?.host, host != .mac {
            return host
        }
        for key in ["folder", "cwd"] {
            guard let folder = value[key]?.stringValue else { continue }
            if let folder = work.folders.first(where: { $0.folder.folder.absoluteString == folder && $0.host != .mac }) {
                return folder.host
            }
        }
        return nil
    }

    /// Another of the control plane's hosts, not reachable from here now (#208).
    struct HostAway: Error {
        let host: MachineRef
    }

    /// The home host did not come back within `sendPatience` (#208).
    struct MacAway: Error {}

    /// The other hosts this phone has a live connection to now (058, #208): an agent on
    /// one that is not is stale on its own, whatever the home host is doing.
    private(set) var reachableHosts: Set<MachineRef> = [] {
        didSet {
            for host in oldValue.subtracting(reachableHosts) where hostDownSince[host] == nil {
                hostDownSince[host] = Date()
            }
            for host in reachableHosts.subtracting(oldValue) { hostDownSince[host] = nil }
        }
    }

    /// Whether what is shown of `host`'s work can be trusted, and acted on: the home host's
    /// staleness for its own, that host's link for another's (#208).
    func isStale(on host: MachineRef) -> Bool {
        host == .mac ? isStale : !reachableHosts.contains(host)
    }

    func isStale(_ agent: Agent) -> Bool { isStale(on: agent.host) }

    /// Who something sent to `host` goes to, as the in-flight mark (`Telling`) names it:
    /// the Mac as "your Mac", a server by its name, as the window says it (#239).
    func recipient(on host: MachineRef) -> String {
        host == .mac ? "your Mac" : hostName(host)
    }

    /// Who something sent to this agent goes to (#239).
    func answerRecipient(_ agentID: UUID) -> String {
        recipient(on: work.agent(agentID)?.host ?? .mac)
    }

    /// The host of the folder the start page is open on: where the new agent starts.
    var startHost: MachineRef {
        startingIn.flatMap { work.folder($0)?.host } ?? .mac
    }

    /// Whether a host can do what `capability` names (#1748): its row's list, with `.mac`
    /// read as this phone's home host. True when the host said no list, or is not a
    /// control plane's.
    func host(_ host: MachineRef, has capability: String) -> Bool {
        let id = host == .mac ? (controlHome ?? host) : host
        return controlHosts.first { $0.id == id }?.has(capability) ?? true
    }

    /// Whether the host of an agent can do what `capability` names.
    func agent(_ id: UUID?, has capability: String) -> Bool {
        host(work.agent(id)?.host ?? .mac, has: capability)
    }

    /// A host's row as `hosts/list` last said it: its state, and the workspace it runs on (#691).
    func controlHost(_ host: MachineRef) -> DaemonAPI.ControlMachine? {
        controlHosts.first { $0.id == host }
    }

    /// The hosts whose `hosts/start` is out now, so the strip's Start waits for it (#691).
    private(set) var hostsBeingStarted: Set<MachineRef> = []
    /// Prompts and starts the control plane keeps for stopped workspaces (#691 US3), every host's.
    private(set) var kept: [DaemonAPI.KeptRequest] = []
    /// The kept starts the start page has shown here: the one that reaches its host opens.
    @ObservationIgnored private var keptStartsShown: Set<UUID> = []

    /// Whether a prompt or a start for `host` now is kept rather than refused: it is linked
    /// to a workspace that is stopped or starting, and starts when used (FR-020).
    func startsWhenUsed(_ host: MachineRef) -> Bool {
        guard let row = controlHosts.first(where: { $0.id == host }), row.workspace?.startWhenUsed == true else { return false }
        return row.state == "stopped" || row.state == "starting"
    }

    func kept(for agentID: UUID) -> [DaemonAPI.KeptRequest] {
        kept.filter { !$0.isStart && $0.agentID == agentID }
    }

    func keptStarts(in folder: URL) -> [DaemonAPI.KeptRequest] {
        let folder = Folder.standardize(folder)
        return kept.filter { $0.isStart && $0.folder.map(Folder.standardize) == folder }
    }

    /// A prompt or a start for a stopped workspace's host, whose link is closed while it is
    /// down, sent to the control plane to keep (#691 US3). What was kept, or nil with why not.
    private func keepThroughControl(_ host: MachineRef, _ method: String, _ params: some Encodable) async -> DaemonAPI.KeptRequest? {
        guard let control = controlPlane, let params = try? JSONValue.encoding(params) else {
            problem = "The control plane isn’t answering, so that was not sent."
            return nil
        }
        do {
            _ = try await control.call(DaemonAPI.Method.hostsKeep, DaemonAPI.KeepRequest(host: host, method: method, params: params))
            return nil
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.kept {
            guard let said = try? error.data?.decode(DaemonAPI.KeptRequest.self) else { return nil }
            if !kept.contains(where: { $0.id == said.id }) { kept.append(said) }
            return said
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// Approve or Deny on a machine's card (#994): a refusal is the app's alert.
    func answerJoin(_ request: DaemonAPI.JoinRequest, approve: Bool) async {
        if let refused = await people.answer(request, approve: approve, on: controlPlane) {
            problem = refused
        }
    }

    /// Approve or Deny on a GitHub sign-in's card (#995): a refusal is the app's alert.
    func answerSignIn(_ request: DaemonAPI.SignInRequest, approve: Bool, code: String? = nil) async {
        if let refused = await signIn.answer(request, approve: approve, code: code, on: controlPlane) {
            problem = refused
        }
    }

    /// Pair with no code, by signing in (#995): as `pair(scanned:)` does once paired.
    func pairBySigningIn(at url: URL, with signIn: @escaping ControlSignIn.Provider,
                         waiting: @escaping @Sendable (DaemonAPI.SignInWaiting) -> Void) async throws {
        let id = deviceID
        _ = try await RemoteControl.signIn(at: url, id: id, with: signIn, waiting: waiting)
        pairing = .paired
        note("pairing: paired with the control plane at \(url.host() ?? "?") by signing in")
        pairedWithControlPlane = true
    }

    /// Approve, Deny or Send on a channel link's card (#1762): a refusal is the app's alert.
    func answerLink(_ request: DaemonAPI.ChannelLinkRequest, approve: Bool, to person: String?) async {
        if let refused = await people.answerLink(request, approve: approve, to: person, on: controlPlane) {
            problem = refused
        }
    }

    private func loadKept(_ control: DaemonClient) async {
        kept = (try? await control.call(DaemonAPI.Method.hostsListKept, returning: DaemonAPI.KeptList.self))?.kept ?? []
    }

    private func heardKept(_ method: String, _ params: JSONValue?) async {
        if method == DaemonAPI.Notification.controlKeptChanged {
            kept = (try? params?.decode(DaemonAPI.KeptList.self))?.kept ?? []
            return
        }
        // A kept start reached its host: the agent it made opens, if this phone showed it.
        guard let delivered = try? params?.decode(DaemonAPI.KeptDelivered.self),
              keptStartsShown.remove(delivered.id) != nil, let agentID = delivered.agentID,
              let folder = startingIn else { return }
        await started(agentID, in: folder, open: true)
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
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering."
            return
        }
        do {
            _ = try await control.call(method, DaemonAPI.KeptRequestID(host: request.host, id: request.id))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Start the workspace `host` runs on (#691, the strip's Start). The control plane answers
    /// at once; the start's progress comes as `control/hostChanged`, and a refusal is said
    /// in `problem`.
    func startHost(_ host: MachineRef) async {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering, so \(hostName(host)) could not be started."
            return
        }
        hostsBeingStarted.insert(host)
        defer { hostsBeingStarted.remove(host) }
        do {
            let row = try await control.call(DaemonAPI.Method.hostsStart, DaemonAPI.MachineRequest(host: host),
                                             returning: DaemonAPI.ControlMachine.self)
            if let index = controlHosts.firstIndex(where: { $0.id == row.id }) { controlHosts[index] = row }
        } catch {
            problem = sentence(for: error)
        }
    }

    // MARK: Machine providers (#1819)

    /// The control plane's machine providers, as Settings ▸ Machine providers last listed
    /// them (the web page's Providers, the window's ControlProvidersPage); nil before the first.
    var machineProviders: [DaemonAPI.ProviderSummary]?
    /// Why none are shown: a control plane with several copies, or a list that failed.
    var machineProvidersProblem: String?
    /// Whether the control plane runs machine providers: one with several copies does not,
    /// so Settings lists no row for them, as the window does (#2260).
    private(set) var providersHere = true
    /// The groups providers are given to (#1761): every one for an admin, a member's own.
    var providerGroups: [DaemonAPI.Group] = []
    /// Whether this person is an admin, who adds and changes providers (#1761).
    var isAdmin: Bool { people.you?.isAdmin ?? true }

    /// Lists them, and asks every provider to list again (FR-004), as the page opens.
    func loadMachineProviders() async {
        guard let control = controlPlane else {
            // An empty list, so the page does not wait for one for ever (#2260).
            machineProviders = []
            machineProvidersProblem = "The control plane isn’t answering."
            return
        }
        do {
            let answer = try await control.call(DaemonAPI.Method.providersList, DaemonAPI.Empty())
            machineProviders = (try? answer["providers"]?.decode([DaemonAPI.ProviderSummary].self)) ?? []
            machineProvidersProblem = nil
            providersHere = true
            providerGroups = (try? await control.call(DaemonAPI.Method.groupsList, DaemonAPI.Empty(),
                                                      returning: DaemonAPI.GroupList.self))?.groups ?? []
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.providersNeedOneCopy {
            machineProviders = []
            machineProvidersProblem = MachineProviderWords.oneCopy
            providersHere = false
            return
        } catch {
            machineProviders = []
            machineProvidersProblem = sentence(for: error)
            return
        }
        await listMachinesAgain()
    }

    /// Whether Settings lists Machine providers: asks the control plane for its list, and
    /// asks no provider to list again (#2260). As the window's `providersHere`.
    func checkProvidersHere() async {
        guard let control = controlPlane else { return }
        do {
            _ = try await control.call(DaemonAPI.Method.providersList, DaemonAPI.Empty())
            providersHere = true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.providersNeedOneCopy
            || error.code == JSONRPCError.methodNotFound {
            providersHere = false
        } catch {}
    }

    /// List Again: one provider, or every one. The new list comes as control/providersChanged.
    func listMachinesAgain(_ provider: ProviderID? = nil) async {
        _ = try? await controlPlane?.call(DaemonAPI.Method.providersRefresh, DaemonAPI.ProviderRequest(id: provider))
    }

    /// Add or Save: nil, or why the control plane refused it, to say in the sheet.
    func saveWorkspaceProvider(_ request: DaemonAPI.ProviderAdd) async -> String? {
        guard let control = controlPlane else { return "The control plane isn’t answering." }
        do {
            let saved = try await control.call(request.id == nil ? DaemonAPI.Method.providersAdd : DaemonAPI.Method.providersUpdate,
                                               request, returning: DaemonAPI.ProviderSummary.self)
            var list = machineProviders ?? []
            if let index = list.firstIndex(where: { $0.id == saved.id }) { list[index] = saved } else { list.append(saved) }
            machineProviders = list
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    /// Gives a provider to a group, or with nil to the admins alone (#1761): nil, or why not.
    func setProviderGroup(_ provider: ProviderID, _ group: String?) async -> String? {
        await controlRequest(DaemonAPI.Method.providersSetGroup, DaemonAPI.ProviderGroup(provider: provider, group: group))
    }

    /// Remove, Link, Unlink: nil, or why the control plane refused it.
    func removeWorkspaceProvider(_ id: ProviderID) async -> String? {
        let refused = await controlRequest(DaemonAPI.Method.providersRemove, DaemonAPI.ProviderRequest(id: id))
        if refused == nil { machineProviders?.removeAll { $0.id == id } }
        return refused
    }

    func linkWorkspace(host: MachineRef, provider: ProviderID, workspace: String, startWhenUsed: Bool,
                       stopWhenIdleMinutes: Int) async -> String? {
        await controlRequest(DaemonAPI.Method.hostsLink,
                             DaemonAPI.MachineLink(host: host, provider: provider, workspace: workspace,
                                                startWhenUsed: startWhenUsed, stopWhenIdleMinutes: stopWhenIdleMinutes))
    }

    func unlinkWorkspace(host: MachineRef) async -> String? {
        await controlRequest(DaemonAPI.Method.hostsUnlink, DaemonAPI.MachineRequest(host: host))
    }

    /// Stop. With agents at work there and not `confirmed`, answers the question to ask first.
    func stopMachine(host: MachineRef, confirmed: Bool = false) async -> (refused: String?, ask: String?) {
        guard let control = controlPlane else { return ("The control plane isn’t answering.", nil) }
        do {
            _ = try await control.call(DaemonAPI.Method.hostsStop, DaemonAPI.MachineStop(host: host, confirmRunning: confirmed ? true : nil))
            return (nil, nil)
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.agentsWorking && !confirmed {
            return (nil, error.message)
        } catch {
            return (sentence(for: error), nil)
        }
    }

    private func controlRequest(_ method: String, _ params: some Encodable & Sendable) async -> String? {
        guard let control = controlPlane else { return "The control plane isn’t answering." }
        do {
            _ = try await control.call(method, params)
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    /// A host's git asking to use a Mac's git access (#1122), not answered here yet. Any
    /// client may answer it; the control plane takes the first answer.
    var gitLendAsk: GitLendAsk? {
        GitLendAsk.first(in: controlHosts, thisMac: nil, answered: gitAsksAnswered)
    }

    /// Allow or Don’t Allow on the ask.
    func answerGitLend(_ ask: GitLendAsk, allowed: Bool) async {
        gitAsksAnswered.insert(ask.id)
        await lendGit(host: ask.host, from: ask.from, server: ask.server, allowed: allowed)
    }

    /// Said to the control plane; Settings ▸ Git access takes one back with `allowed` false.
    func lendGit(host: MachineRef, from: MachineRef, server: String, allowed: Bool) async {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering, so that was not changed."
            return
        }
        do {
            _ = try await control.call(DaemonAPI.Method.hostsLendGit,
                                       DaemonAPI.LendGit(host: host, from: from, server: server, allowed: allowed))
            if !allowed, let index = controlHosts.firstIndex(where: { $0.id == host }) {
                controlHosts[index].gitFrom?[server] = nil
            }
        } catch {
            problem = sentence(for: error)
        }
    }

    /// When each other host was last seen to go, for the strip over its chats (#239):
    /// set as it leaves `reachableHosts`, cleared as it comes back.
    private(set) var hostDownSince: [MachineRef: Date] = [:]

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
                    self?.controlPlane = control
                    await self?.syncOtherHosts(control, link: link)
                    await self?.loadKept(control)
                    await self?.people.connected(control)
                    await self?.signIn.connected(control)
                    for await change in control.notifications() {
                        guard let self, !Task.isCancelled else { return }
                        if await self.people.heard(change.method, change.params, on: control) {
                            // A provider's group's name, on Settings ▸ Machine providers (#1761),
                            // from the groups people loaded once (#2055).
                            if change.method == DaemonAPI.Notification.controlGroupsChanged {
                                self.providerGroups = self.people.groups
                            }
                            continue
                        }
                        if self.signIn.heard(change.method, change.params) { continue }
                        if await self.userScope.heard(change.method, change.params, on: control) { continue }
                        if change.method == DaemonAPI.Notification.controlKeptChanged
                            || change.method == DaemonAPI.Notification.controlKeptDelivered {
                            await self.heardKept(change.method, change.params)
                            continue
                        }
                        // Settings ▸ Machine providers keeps up (#1819).
                        if change.method == DaemonAPI.Notification.controlProvidersChanged {
                            if let listed = try? change.params?["providers"]?.decode([DaemonAPI.ProviderSummary].self) {
                                self.machineProviders = listed
                            }
                            continue
                        }
                        guard change.method == DaemonAPI.Notification.controlHostChanged else { continue }
                        // A host back while this phone waits out its backoff: go back now (#172).
                        if !self.isConnected, DaemonAPI.ControlMachine.answers(change.params?["state"]?.stringValue) { self.backoff.nudge() }
                        await self.syncOtherHosts(control, link: link)
                    }
                    note("hosts: the control plane's watch closed")
                    if self?.controlPlane === control {
                        self?.controlPlane = nil
                        self?.people.went()
                        self?.signIn.went()
                    }
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
        controlPlane = nil
        people.went()
        signIn.went()
        listening?.cancel()
        listening = nil
        for (_, other) in otherHosts { await other.disconnect() }
        otherHosts = [:]
        reachableHosts = []
        await client.disconnect()
    }

    private func syncOtherHosts(_ control: DaemonClient, link: ControlLink) async {
        guard let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self),
              let listed = try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlMachine].self)
        else { return }
        controlHosts = listed.filter(\.runsAgents)
        gitAsksAnswered.formIntersection(GitLendAsk.waiting(in: listed))
        controlHome = status.homeHost
        controlStatus = status
        // The relay's key, from the control plane itself (T077): kept for when its address
        // cannot be reached.
        RemoteControl.keepRelayKey(status.relayKey)
        let others = listed.filter { $0.id != status.homeHost && $0.answers && $0.runsAgents }
        for host in others {
            let other = otherHosts[host.id] ?? DaemonClient(link: link.link(for: host.id))
            otherHosts[host.id] = other
            if await other.isConnected { continue }
            reachableHosts.remove(host.id)
            guard (try? await other.connect(startIfNeeded: false, timeout: .seconds(5))) != nil else { continue }
            let id = host.id
            reachableHosts.insert(id)
            // A start there with no key of its own asks this device for one (#344).
            await other.setCredentialLender { [weak self] wanted in
                await self?.answerCredentialWanted(wanted, on: id) ?? false
            }
            if let folders = try? await other.call(DaemonAPI.Method.foldersList,
                                                    DaemonAPI.FoldersListRequest(includeArchived: false),
                                                    returning: [DaemonAPI.FolderSummary].self) {
                work.replaceFolders(folders, from: id)
                startHostMoved()
            }
            // Its folders' MCP servers, for their rows in the sidebar (#753).
            if let health = try? await other.call(DaemonAPI.Method.mcpHealth, Optional<String>.none,
                                                  returning: DaemonAPI.MCPHealthSnapshot.self) {
                work.replaceMCPHealth(health, from: id)
            }
            if let agents = try? await other.listAgents(DaemonAPI.ListRequest(includeArchived: false, lean: true)) {
                work.replaceAgents(agents, from: id)
            }
            await refreshServerRuntimes(id)
            await refreshServerCost(id)
            await refreshServerDisk(id)
            let notes = other.notifications()
            let shown = work.shown
            // Read off the main actor, once, and applied there (#203).
            Task.detached(priority: .userInitiated) { [weak self] in
                for await note in notes {
                    // Its runtimes, and the start page's draft made there (#240).
                    if note.method == DaemonAPI.Notification.runtimeChanged
                        || note.method == DaemonAPI.Notification.costChanged
                        || note.method == DaemonAPI.Notification.draftOptions {
                        await self?.received(note.method, note.params, fromOther: id)
                        continue
                    }
                    if note.method == DaemonAPI.Notification.diskChanged {
                        await self?.received(note.method, note.params, fromOther: id)
                        continue
                    }
                    // Settings ▸ Backups is the Mac's (#1810).
                    if note.method == DaemonAPI.Notification.resourcesChanged
                        || note.method == DaemonAPI.Notification.mcpHostedChanged
                        || note.method == DaemonAPI.Notification.eventsChanged
                        || note.method == DaemonAPI.Notification.backupsChanged { continue }
                    guard let update = AgentsModel.read(note.method, note.params, showing: shown.id,
                                                         alsoShowing: shown.also) else { continue }
                    let added = await self?.work.addsFolder(update, from: id) ?? false
                    await self?.work.apply(update, from: id)
                    await self?.applyToPopouts(update)
                    if added { await self?.refreshWorkflows() }
                    if case .folderRemoved = update { await self?.forgetArchived(AgentsModel.stamp(update, host: id)) }
                }
                // Its connection ended: its cards are stale until the watch reaches it again.
                await MainActor.run { [weak self] in
                    if self?.otherHosts[id] === other { self?.reachableHosts.remove(id) }
                }
            }
            // A new connection is a new record there: where the person is, and what is open.
            presence?.connected()
        }
        // One offline or stopped when this started lists what it last did, greyed, as one that
        // went while it ran (#962).
        for host in controlHosts where host.id != status.homeHost && !host.answers
            && !work.holdsFolders(of: host.id) {
            if let heard = try? await control.call(DaemonAPI.Method.hostsLastHeard, DaemonAPI.MachineRequest(host: host.id),
                                                   returning: DaemonAPI.MachineLastHeard.self) {
                work.takeLastHeard(heard)
            }
        }
        // A host that went offline keeps its folders, greyed under its heading (frame H).
        // One the control plane no longer lists is gone, and so is what it showed.
        for id in otherHosts.keys where !others.contains(where: { $0.id == id }) {
            reachableHosts.remove(id)
            await otherHosts.removeValue(forKey: id)?.disconnect()
            if !listed.contains(where: { $0.id == id }) {
                work.replaceFolders([], from: id)
                work.replaceAgents([], from: id)
                serverRuntimes[id] = nil
                serverCosts[id] = nil
                serverDisks[id] = nil
            }
        }
    }

    /// What another host says that the shared model does not claim, and the phone wants:
    /// its runtimes changing, and the start page's draft settling there (#240).
    private func received(_ method: String, _ params: JSONValue?, fromOther host: MachineRef) async {
        switch method {
        case DaemonAPI.Notification.runtimeChanged:
            await refreshServerRuntimes(host)
        case DaemonAPI.Notification.costChanged:
            await refreshServerCost(host)
        case DaemonAPI.Notification.diskChanged:
            if let state = try? params?.decode(DiskState.self) { serverDisks[host] = state }
        case DaemonAPI.Notification.draftOptions:
            guard host == startDraftHost,
                  let change = try? params?.decode(DaemonAPI.DraftOptionsNotification.self) else { return }
            settleStartDraft(change)
        default:
            break
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
                let update = AgentsModel.read(notification.method, notification.params, showing: shown.id,
                                              alsoShowing: shown.also)
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
        var removedFolder: URL?
        if case .agentRemoved(let removed)? = update { removedFolder = self.work.agent(removed.agentID)?.folderPath }
        // Anything the shared model does not claim is the Mac's own — shells,
        // terminals — and a remote has no business with it.
        if let update {
            // A folder added has workflows no notification brings (#1798).
            let added = self.work.addsFolder(update)
            self.work.apply(update)
            applyToPopouts(update)
            forgetArchived(update)
            if added { Task { await refreshWorkflows() } }
        }
        // Nothing below waits on the network: one slow answer would hold every
        // notification after it (#175). What needs asking is asked beside the loop.
        if let updated, previousLabels != updated.labels,
           self.labelVocabularies[updated.folderPath] != nil {
            self.reloadLabelVocabulary(in: updated.folderPath)
        }
        if let removedFolder, self.labelVocabularies[removedFolder] != nil {
            self.reloadLabelVocabulary(in: removedFolder)
        }
        if notification.method == DaemonAPI.Notification.preferencesChanged,
           let preferences = try? notification.params?.decode(DaemonAPI.DisplayPreferences.self) {
            self.displayMirror.hostSaid(preferences)
        }
        if Self.attentionNotifications.contains(notification.method) {
            self.publishAttentionSoon()
        }
        // The Live Activity of a turn sent from here (#1657): what the session does, and asks.
        if case .agentChanged(let agent)? = update {
            liveActivities.changed(agent.id, in: work)
        } else if case .agentRemoved(let removed)? = update {
            liveActivities.changed(removed.agentID, in: work)
        } else if case .attention(let change)? = update, let agentID = change.need?.agentID {
            liveActivities.changed(agentID, in: work)
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
           let output = DaemonAPI.ShellOutputNotification(params: params) {
            self.shells[ShellKey(agentID: output.agentID, shell: output.shell)]?.received(output.bytes, at: output.offset)
        }
        if notification.method == DaemonAPI.Notification.shellStateChanged,
           let change = try? notification.params?.decode(DaemonAPI.ShellStateNotification.self) {
            self.shells[ShellKey(agentID: change.agentID, shell: change.shell)]?.received(change.state)
        }
        if notification.method == DaemonAPI.Notification.filesChanged,
           let change = try? notification.params?.decode(DaemonAPI.FilesChangedNotification.self) {
            self.files.apply(change)
        }
        if notification.method == DaemonAPI.Notification.runtimesAccountProfilesChanged,
           let list = try? notification.params?.decode([AccountProfile].self) {
            self.accountProfiles = list
        }
        if notification.method == DaemonAPI.Notification.sandboxChanged,
           let settings = try? notification.params?.decode(SandboxSettings.self) {
            self.sandboxSettings = settings
        }
        if notification.method == DaemonAPI.Notification.clientPermissionsChanged,
           let settings = try? notification.params?.decode(ClientPermissionSettings.self) {
            self.clientPermissions = settings
        }
        if notification.method == DaemonAPI.Notification.daemonPolicyStateChanged,
           let state = try? notification.params?.decode(DaemonAPI.PolicyState.self) {
            self.policyState = state
            // The marks on the lists change with the policy: read them again (#998).
            Task {
                await self.refreshRuntimes()
                await self.refreshSandboxSettings()
                await self.refreshCostState()
            }
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
    /// Only what is on screen: the folders, the first page of live agents and what is
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
        // The snapshot carries the parts on screen, the disk and the store notes (#884):
        // one round trip through the relay, not one a part. A host that predates that
        // carries none of them, and each is asked for on its own.
        var carried: DaemonAPI.CatchUpSnapshot?
        for step in plan.steps {
            switch step {
            case .snapshot: carried = await refreshSnapshot(with: plan.parts)
            case .chat: await loadTranscript()
            case .part(let part):
                if carried?.carried.contains(part) != true { await load(part) }
            }
        }
        // Sessions in scenes of their own (#888), as the main scene's chat.
        for chat in popouts.values { await loadTranscript(of: chat) }
        // The low-disk strip is under the banner on every page (#196), so it is read
        // on every catch-up, not when a page asks for it.
        if carried?.disk == nil { await refreshDisk() }
        // The person's display choices (#1033): the sidebar and every chat read them.
        await refreshDisplayPreferences()
        // The organisation's strip is on every page (#998), so it is read on every catch-up.
        await refreshPolicyState()
        // What the Mac could not read (#205, #223), at the foot of the folders list.
        if carried?.storeNotes == nil { await refreshStoreNotes() }
        // The milestones (#984), for the Time page and the iPad's card.
        if let milestones = carried?.milestones {
            takeMilestones(milestones)
        } else if let milestones = try? await client.call(DaemonAPI.Method.milestonesState, Optional<String>.none,
                                                          returning: Milestones.self) {
            takeMilestones(milestones)
        }
        await settleUnsettledStart()
        await reopenStartChoices()
        settleSelection()
        // Once the counts have landed, so the widget's number is this refresh's number.
        // Against the file, not the last write: a push may have laid a guess over it (#1046).
        lastPublished = nil
        publishAttention()
        liveActivities.settle(with: work)
        if let pendingOpen { open(pendingOpen) }
        if let pendingNeed {
            self.pendingNeed = nil
            if let agentID = agentID(forNeedToken: pendingNeed) { open(agentID) } else { openUnheld(needToken: pendingNeed) }
        }
        note("catch-up: \(plan.steps.count) steps (\(plan.parts.map(\.rawValue).sorted().joined(separator: ", "))), "
             + "\(carried?.carried.count ?? 0) carried, in \(ContinuousClock.now - began)")
    }

    /// Folders, the first page of live agents, and what waits on a person: one call to a
    /// host that knows `client/catchUp`, one per part to one that does not. With them,
    /// `parts`, the disk and the store notes, from a host that knows to send them (#884).
    /// The snapshot, or nil when it failed.
    private func refreshSnapshot(with parts: Set<CatchUpPart>) async -> DaemonAPI.CatchUpSnapshot? {
        let snapshot: DaemonAPI.CatchUpSnapshot
        do {
            snapshot = try await client.catchUp(.init(parts: CatchUpPart.allCases.filter(parts.contains)))
        } catch {
            note("catch-up: the snapshot failed: \(error)")
            return nil
        }
        work.replaceFolders(snapshot.folders, from: .mac)
        startHostMoved()
        takeLiveAgents(snapshot.agents, page: DaemonAPI.CatchUpRequest.firstPage)
        work.replacePermissions(snapshot.permissions)
        work.replaceElicitations(snapshot.elicitations)
        work.replaceAttention(snapshot.attention)
        work.setResuming(snapshot.resuming)
        toNotifier { [deviceID = self.deviceID] notifier in await notifier.sweep(keeping: snapshot.attention, me: .device(deviceID)) }
        if let disk = snapshot.disk { work.replaceDisk(disk) }
        if let notes = snapshot.storeNotes { work.replaceStoreNotes(notes) }
        if let workflows = snapshot.workflows { work.replaceWorkflows(workflows) }
        if let pins = snapshot.pins { work.replacePins(pins) }
        if let leases = snapshot.leases {
            work.replaceLeases(leases.leases)
            work.replaceHostedMCP(leases.hosted)
            work.replaceMCPHealth(leases.health)
        }
        if let selectedFolder { await fillFolder(selectedFolder) }
        return snapshot
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
        case .leases: await refreshLeases()
        case .runtimes: await refreshRuntimes()
        case .allowances: await refreshRuntimeAllowances()
        case .modes: await refreshModes()
        case .sandbox:
            await refreshSandboxSettings()
            await refreshClientPermissions()
        case .costs: await refreshCostState()
        }
    }

    // MARK: Where this device is (021)

    /// The app came to the front or went behind. `.active` is foreground and unlocked,
    /// which is what "in the person's hands" means on a device.
    ///
    /// Each scene says its own (#888): the app is in front while any of them is.
    func scenePhase(_ phase: ScenePhase, of scene: UUID) {
        if phase == .background { Self.scheduleWidgetRefresh() }
        let wasActive = scenesActive.isEmpty == false
        if phase == .active { scenesActive.insert(scene) } else { scenesActive.remove(scene) }
        let isActive = !scenesActive.isEmpty
        guard wasActive != isActive || !hasHeardAPhase else { return }
        hasHeardAPhase = true
        let phase: ScenePhase = isActive ? .active : phase
        presence?.scenePhase(phase)
        if phase == .active {
            attentionRefreshTask?.cancel()
            attentionRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { break }
                    self?.publishAttention()
                }
            }
            Task {
                await goBackNow(.wake)
                await refreshAttention()
                // A silent push is best effort, so a need that moved while the app was
                // shut may have been missed; the model is now as true as it can be.
                publishAttention()
                liveActivities.settle(with: work)
            }
        } else {
            attentionRefreshTask?.cancel()
            attentionRefreshTask = nil
            publishAttention()
        }
    }

    /// The scenes in front (#888): the main one, and any session's own.
    @ObservationIgnored private var scenesActive: Set<UUID> = []
    @ObservationIgnored private var hasHeardAPhase = false

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
        await sendPushToken()
        liveActivities.sayTokens()
    }

    /// This device's APNs token (#1460), as the system gave it.
    @ObservationIgnored private var pushToken: Data?

    /// The system gave this device its APNs token: the control plane hears it now if the
    /// link is up, else on the next announce.
    func pushTokenArrived(_ token: Data) {
        pushToken = token
        guard isConnected else { return }
        Task { await sendPushToken() }
    }

    /// `clients/setPushToken` (#1460): the token, to the control plane only, so it can push
    /// here when no Mac host relays notices. What it pushes is sealed to this device's key.
    /// A Mac's own daemon, with no control plane, does not know the method; nothing is lost.
    private func sendPushToken() async {
        guard let pushToken else { return }
        do {
            try await client.call(DaemonAPI.Method.clientsSetPushToken,
                                  DaemonAPI.PushToken(token: pushToken, environment: .ofThisBuild))
            note("push: token given to the control plane")
        } catch {
            note("push: the token was not taken: \(error)")
        }
    }

    /// `clients/setActivityToken` (#1744): a Live Activity's push token, to the control plane
    /// only, so it can update the activity while this app is not running; nil when it ended.
    /// A Mac's own daemon does not know the method; the app's own updates go on.
    private func sendActivityToken(_ agentID: UUID, _ token: Data?, _ startedAt: Date) async {
        do {
            try await client.call(DaemonAPI.Method.clientsSetActivityToken,
                                  DaemonAPI.ActivityToken(agentID: agentID, token: token, environment: .ofThisBuild,
                                                          startedAt: startedAt))
            note("live activity: token for \(agentID) \(token == nil ? "taken back" : "given") to the control plane")
        } catch {
            note("live activity: the token for \(agentID) was not taken: \(error)")
        }
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
        // The Mac's count moved (#1163): a need met there, a finish read. Nothing to show.
        if let count = CloudKitMailbox.pushedCount(from: userInfo) {
            note("push: count")
            await showOnTheWidget(count)
            return
        }
        // What kind of push, never its payload: that is the person's work (#175).
        let fromControl = ControlPush.isControlPush(userInfo)
        note("push: \(CloudKitRelayChannel.isRelayPush(userInfo) ? "relay wake-up" : fromControl ? "control plane" : "mailbox")")
        // The relay's wake-up: a relayed session polls, so there is nothing to poke.
        if CloudKitRelayChannel.isRelayPush(userInfo) { return }
        // The mailbox's, or the control plane's own when no Mac relays (#1460).
        guard let pushed = fromControl ? ControlPush.pushed(from: userInfo, key: key) : CloudKitMailbox.pushed(from: userInfo)
        else { return }
        let headline = pushed.headline
            ?? pushed.envelope.flatMap { envelope in key.flatMap { try? Envelope.open(envelope, with: $0) } }
        // A need has moved here or away, which is the one thing the widget counts (#1046).
        await showOnTheWidget(AttentionPush(need: pushed.needID, headline: headline,
                                            withdrawn: pushed.withdraws,
                                            count: pushed.count))
        if pushed.withdraws {
            notifier.withdraw(pushed.token)
            return
        }
        guard let headline else { return }
        notifier.show(headline, needID: pushed.needID, alert: pushed.alert)
    }

    /// A push, on the widget (#1046). Connected, the Mac is asked what waits and the whole
    /// is written. Woken in the background with no link, the push is laid over the file,
    /// since the model is as old as the last time the app ran; the count it carries is the
    /// Mac's, and the badge shows it too (#1163).
    private func showOnTheWidget(_ push: AttentionPush) async {
        if isConnected {
            // Whole, not only what waits: a guarded change's Needs You row rides on its
            // folder's summary, and the agent's state on its record (#1045).
            await catchUp()
        } else if let written = AttentionSnapshotStore.apply(push) {
            shownFromAPush(written)
        }
    }

    /// The Mac's count on its own (#1163). Connected, the model already says it.
    private func showOnTheWidget(_ count: AttentionCount) async {
        if isConnected {
            publishAttention()
        } else if let written = AttentionSnapshotStore.apply(count) {
            shownFromAPush(written)
        }
    }

    /// A push wrote the file: the widget and the badge show what it wrote.
    private func shownFromAPush(_ written: AttentionSnapshot) {
        lastPublished = nil
        notifier.setBadgeCount(written.total)
        WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
    }

    /// The background refresh's name, as `BGTaskSchedulerPermittedIdentifiers` lists it.
    nonisolated static let widgetRefreshTask = "com.alexecollins.agents.remote.widget-refresh"

    /// Ask for the next background refresh, a quarter of an hour on at the soonest: the
    /// widget's own staleness (#1046). The system decides when, or whether.
    nonisolated static func scheduleWidgetRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: widgetRefreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: AttentionSnapshot.staleness)
        BGTaskScheduler.shared.submitTaskRequest(request) { _ in }
    }

    /// The system's background refresh (#1046): back in touch for a moment, caught up,
    /// and the widget written, with no push and nobody opening the app.
    func refreshInBackground() async {
        note("widget: background refresh")
        await goBackNow(.wake)
        let deadline = ContinuousClock.now + .seconds(20)
        while !isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard isConnected else { return }
        await catchUp()
    }

    /// Open one conversation from a banner, as the sidebar's pick (#226). A banner tapped
    /// before the agents have arrived — a cold launch — is kept and honoured once they
    /// have.
    func open(_ agentID: UUID) {
        guard work.agent(agentID) != nil else {
            pendingOpen = agentID
            return
        }
        pendingOpen = nil
        // A banner is about the agent, not whatever page was open over the folder. The
        // chat is the detail's own page (#226), not a push over the folder's, so there
        // is no push for a collapsing split view to drop.
        sidebarItem = .session(agentID)
    }

    private var pendingOpen: UUID?

    /// A folder's page, from a banner with no session behind it (#531): where a change
    /// git brought to its files is asked. The phone holds the Mac's folders only.
    func openFolder(_ folder: URL) {
        sidebarItem = .folder(work.folder(folder)?.key ?? FolderKey(host: .mac, folder: folder))
    }

    /// Open what a need is about, from a banner or a widget row (#1046). A need the
    /// model does not hold yet (a cold launch, a wake) is kept and opened once caught up,
    /// as `open(_:)` keeps an agent (#1045).
    func open(needToken token: String) {
        if let agentID = agentID(forNeedToken: token) {
            pendingNeed = nil
            open(agentID)
        } else if catchingUp != nil || !isConnected {
            pendingNeed = token
        } else {
            pendingNeed = nil
            openUnheld(needToken: token)
        }
    }

    /// Caught up and still no session for it: a guarded change no agent made goes to its
    /// folder's page, where it is asked (#531); anything else, to whoever needs you.
    private func openUnheld(needToken token: String) {
        if let folder = NeedID.guardedFolder(fromToken: token) {
            sidebarItem = .folder(work.folder(folder)?.key ?? FolderKey(host: .mac, folder: folder))
        } else {
            showTheFirstFolderNeedingYou()
        }
    }

    private var pendingNeed: String?

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
        case let parts where parts.count == 2 && parts[0] == "guarded":
            // Made by an agent: opened in its chat, where it is asked (Alex, #1045).
            guard let folder = NeedID.guardedFolder(fromToken: token) else { return nil }
            let path = String(token.dropFirst("guarded:\(folder.path):".count))
            return work.folder(folder)?.guardedChanges?.first { $0.path == path }?.askedIn
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
    /// badge shows: the same sum over the same live folders.
    ///
    /// A push is also what tells the app something moved, so this runs on those too
    /// rather than waiting for the person to open the app.
    ///
    /// Dated when the model was last live (#1163), not when it is written: with no link
    /// it is what the phone last heard, and a push the notification extension laid over
    /// the file since is newer, so it stays, and the badge shows it.
    func publishAttention() {
        guard let knownAt = isConnected ? Date() : liveUntil else {
            // Nothing heard since launch: whatever is on file is all there is.
            if let total = AttentionSnapshotStore.read()?.total { notifier.setBadgeCount(total) }
            return
        }
        let snapshot = AttentionSnapshot.make(model: work, at: knownAt)
        // Live, the model is the newest there is. Not, the file may be newer than what
        // was last written here: the extension writes it too.
        if AttentionSnapshotStore.write(snapshot, over: isConnected ? lastPublished : nil) {
            lastPublished = snapshot
            notifier.setBadgeCount(snapshot.total)
            WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
        } else {
            let total = isConnected ? snapshot.total : (AttentionSnapshotStore.read()?.total ?? snapshot.total)
            notifier.setBadgeCount(total)
        }
    }

    /// What was last written for the widget, so the file is not read back each time.
    @ObservationIgnored private var lastPublished: AttentionSnapshot?

    /// The notifications that can move the number. The Mac sends a great deal more than
    /// this — a shell printing, a file changing, a runtime's status — and a widget does
    /// not redraw for any of those.
    private static let attentionNotifications: Set<String> = [
        DaemonAPI.Notification.attentionChanged,
    ]

    /// A tap on the widget: `agents://attention` for the body, `agents://agent/<id>` for
    /// a row.
    ///
    /// A body is showing one number over several folders, so it goes to the first
    /// folder with something waiting, and to the folders page when nothing is waiting
    /// or the app was launched cold and has not heard about any folders yet. A row
    /// names one agent, and `open(_:)` already knows how to get there.
    func openedFromTheWidget(_ url: URL) {
        switch AttentionLink.parse(url) {
        case .agent(let id):
            open(id)
            // A row drawn a few minutes ago can name a session that has gone since, and
            // a tap that names nothing left must not look like a tap that did nothing.
            // `open` has kept the id, so the conversation still opens if the agents are
            // merely late; a folder is shown until then.
            if work.agent(id) == nil { showTheFirstFolderNeedingYou() }
        case .need(let token):
            // A row a push drew without naming its session (#1046).
            if agentID(forNeedToken: token) == nil { showTheFirstFolderNeedingYou() }
            open(needToken: token)
        case .attention:
            showTheFirstFolderNeedingYou()
        case nil:
            break
        }
    }

    /// The folders page, with the first folder that has somebody waiting already open.
    private func showTheFirstFolderNeedingYou() {
        openWorkflow = nil
        selection = nil
        selectedFolder = work.liveFolders.first(where: needsYou)?.folder.folder
    }

    /// Whether anything in a folder is waiting on a person: the same sum the widget
    /// shows, asked of one folder. Counted from this model's own grouping, which is the
    /// one that knows whether a person has looked at an agent, and not the counts the
    /// daemon sent.
    private func needsYou(_ summary: DaemonAPI.FolderSummary) -> Bool {
        work.attentionCount(in: summary.folder.folder) > 0
    }

    private func identify() async {
        _ = try? await client.call(DaemonAPI.Method.surfaceIdentify,
                                   DaemonAPI.SurfaceIdentification(id: deviceID, name: UIDevice.current.name, kind: kind))
    }

    private func startPresence() {
        guard presence == nil else { return }
        notifier.authorisationChanged = { [weak self] in self?.presence?.connected() }
        let reporter = PresenceReporter { [weak self] watching, active, mayNotify, showing, popped in
            guard let self else { return }
            // Every host hears whether the person is here; only the open chat's host hears
            // which it is, and that is where its entries and output come from (#203).
            // Sessions in scenes of their own go to their own hosts the same way (#888).
            let hostOf = { (id: UUID) in self.work.agent(id)?.host ?? .mac }
            let owner = showing.map(hostOf)
            let watcher = watching.map(hostOf)
            let poppedHosts = popped.sorted { $0.uuidString < $1.uuidString }.map { ($0, hostOf($0)) }
            func report(for host: MachineRef) -> DaemonAPI.PresenceReport {
                DaemonAPI.PresenceReport(watching: watcher == host ? watching : nil, active: active,
                                         mayNotify: mayNotify, showing: owner == host ? showing : nil,
                                         alsoShowing: poppedHosts.filter { $0.1 == host }.map(\.0))
            }
            _ = try? await self.client.call(DaemonAPI.Method.presenceReport, report(for: .mac))
            for (id, other) in self.otherHosts where self.reachableHosts.contains(id) {
                _ = try? await other.call(DaemonAPI.Method.presenceReport, report(for: id))
            }
        }
        // Scenes of their own restored at launch opened before there was a reporter (#888).
        reporter.popped(Set(popouts.keys), inFront: popoutInFront)
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
    /// — a folder's Archived section, a workflow's runs — and not on every connection.
    private func refreshAgents() async {
        // Lean: no card or row reads the option and command lists, which were nearly all of
        // each record (#107). The open chat's come with `loadWholeAgent`.
        let page = DaemonAPI.CatchUpRequest.firstPage
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, page, returning: [Agent].self)
        else { return }
        takeLiveAgents(listed, page: page)
        if let selectedFolder { await fillFolder(selectedFolder) }
    }

    /// The first page of live agents, in place of what was held. Archived agents already
    /// fetched are kept only where a screen can still show them: the open folder, and an
    /// open archived chat (#175). One brought back while this phone was away is in the live
    /// list, and that copy wins.
    private func takeLiveAgents(_ listed: [Agent], page: DaemonAPI.ListRequest) {
        moreLiveAgents = page.next(after: listed) != nil
        filledFolders = []
        let live = Set(listed.map(\.id))
        let letGo = Set(archivedToLetGo(work.agents, folders: archivedHeldFor, chat: selection))
        // Only this host's: another host's agents come from that host (058, US4).
        let kept = work.agents.filter {
            $0.host == .mac && $0.state == .archived && !live.contains($0.id) && !letGo.contains($0.id)
        }
        work.replaceAgents(listed + kept, from: .mac)
    }

    /// The rest of a folder's live agents, when the first page did not hold them all:
    /// asked as its page opens, once per connection.
    func fillFolder(_ folder: URL) async {
        guard moreLiveAgents, filledFolders.insert(folder).inserted else { return }
        let request = DaemonAPI.ListRequest(includeArchived: false, folder: folder, lean: true)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request, returning: [Agent].self)
        else {
            filledFolders.remove(folder)
            return
        }
        work.takeListed(listed)
    }

    /// A folder page has gone: what only it could show is let go (#175). Its archived
    /// agents, its label suggestions, and the live agents beyond the first page that it
    /// filled in.
    private func letGoOfFolders(keeping folder: URL?) {
        work.forget(archivedToLetGo(work.agents, folders: archivedHeld(keeping: folder), chat: selection)
            .filter { !searched.contains($0) })
        labelVocabularies = labelVocabularies.filter { $0.key == folder.map(Folder.standardize) }
        if let folder { Task { await fillFolder(folder) } }
    }

    /// A chat has gone: what was read for it alone is let go (#175). Its earlier marks
    /// for Files, and an archived chat outside the open folder.
    private func letGoOfChats(keeping agentID: UUID?) {
        touchedEarlier = touchedEarlier.filter { $0.key == agentID || popouts[$0.key] != nil }
        touchedHistoryAsked = touchedHistoryAsked.filter { $0 == agentID || popouts[$0] != nil }
        work.forget(archivedToLetGo(work.agents, folders: archivedHeldFor, chat: agentID)
            .filter { !searched.contains($0) })
    }

    /// The newest `limit` archived agents in a folder, for its Archived section when
    /// it is opened. Without their slash commands: an archived chat has no prompt bar
    /// here to use them.
    /// The folders whose Archived fold is open in the sidebar (#226): each holds a page
    /// of its archived sessions while it is, as on the Mac (#165).
    private(set) var openArchivedFolds: Set<URL> = []

    /// The folders whose archived sessions a screen can show: the open folder, and
    /// every open Archived fold.
    private var archivedHeldFor: Set<URL> { archivedHeld(keeping: selectedFolder) }

    private func archivedHeld(keeping folder: URL?) -> Set<URL> {
        openArchivedFolds.union(folder.map { [Folder.standardize($0)] } ?? [])
    }

    /// A folder's Archived page has opened: a page of its newest archived sessions, from
    /// the folder's own host (#533), or the few its Recently archived sessions show (#2731).
    /// Answers whether the host did (#664).
    @discardableResult
    func loadArchived(in key: FolderKey, limit: Int = SidebarFolderFold.archivedShown) async -> Bool {
        openArchivedFolds.insert(Folder.standardize(key.folder))
        return await loadArchivedAgents(in: key, limit: limit)
    }

    /// A folder's Archived fold has closed: what it held is let go, but for the chat open
    /// and whatever the open folder's pages still show.
    func letGoOfArchived(in folder: URL) {
        let folder = Folder.standardize(folder)
        guard openArchivedFolds.remove(folder) != nil else { return }
        work.forget(archivedToLetGo(work.agents, folders: archivedHeldFor, chat: selection)
            .filter { !searched.contains($0) })
    }

    /// The most a search brings back from each host, a page at a time: the sidebar holds
    /// the live sessions and filters those itself (#165, #176).
    static let searchShown = 200
    /// Archived sessions a search brought in, let go when the search ends.
    private var searched: Set<UUID> = []
    /// The next page of matches, for each host whose last page was full (#176).
    private var searchNext: [MachineRef: DaemonAPI.ListRequest] = [:]
    /// Whether a host has more matches than it has sent: More matches… asks for them.
    var searchHasMore: Bool { !searchNext.isEmpty }

    /// The archived sessions matching `words`, a capped page from every host that answers,
    /// as the window asks (#533); nothing when it is empty.
    func searchSessions(_ words: String) async {
        let earlier = searched
        searched = []
        searchNext = [:]
        if !earlier.isEmpty {
            let unseen = Set(archivedToLetGo(work.agents, folders: archivedHeldFor, chat: selection))
            work.forget(earlier.filter { unseen.contains($0) })
        }
        work.saidLines = [:]
        guard !words.isEmpty else { return }
        let request = DaemonAPI.ListRequest(archivedCommands: false, limit: Self.searchShown, lean: true, query: words)
        let hosts: [MachineRef] = [.mac] + reachableHosts.sorted { $0.rawValue < $1.rawValue }
        for host in hosts {
            await search(request, on: host)
            // What was said (#1585): the sessions whose prompts or replies hold the words. Not
            // asked of a host too old to say (#1748).
            if self.host(host, has: Capability.agentsSaid1), let target = hostClient(host),
               let said = try? await target.call(DaemonAPI.Method.agentsSaid, DaemonAPI.SaidSearchRequest(text: words),
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
            guard let target = self.hostClient(host) else { return nil }
            return try? await target.call(DaemonAPI.Method.agentsList, request, returning: [Agent].self)
        }) else { return }
        searched.formUnion(page.agents.filter { work.agent($0.id) == nil }.map(\.id))
        work.takeListed(page.agents)
        searchNext[host] = page.next
    }

    /// A folder's newest archived sessions, asked of the folder's own host and stamped
    /// as its own, as the window's (#533). Answers whether the host did (#664).
    @discardableResult
    func loadArchivedAgents(in key: FolderKey, limit: Int) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedCommands: false, archivedOnly: true,
                                            folder: key.folder, limit: limit, lean: true)
        guard let target = hostClient(key.host),
              let listed = try? await target.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return false }
        work.takeListed(listed.map { var agent = $0; agent.host = key.host; return agent })
        return true
    }

    /// The client for `host`: the Mac's own, or a server's while it answers.
    func hostClient(_ host: MachineRef) -> DaemonClient? {
        if host == .mac { return client }
        guard reachableHosts.contains(host) else { return nil }
        return otherHosts[host]
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

    /// Archived folders, as each host listed them: for the sidebar's Archived folders
    /// (#343), and for Spending, where what they cost still counts. Asked for when either
    /// appears, since the catch-up leaves them out.
    private(set) var archivedFolders: [DaemonAPI.FolderSummary] = []

    /// Every host's archived folders, the latest archived first (#2153), as the window's
    /// Archived folders (#343): those listed, less any brought back since, and any put
    /// away since, as their hosts said.
    var shelvedFolders: [DaemonAPI.FolderSummary] {
        let held = Set(work.folders.map(\.key))
        return (work.archivedFolders + archivedFolders.filter { !held.contains($0.key) })
            .sorted(by: DaemonAPI.FolderSummary.byArchived)
    }

    func loadArchivedFolders() async {
        let request = DaemonAPI.FoldersListRequest(includeArchived: true)
        guard let listed = try? await client.call(DaemonAPI.Method.foldersList, request,
                                                  returning: [DaemonAPI.FolderSummary].self)
        else { return }
        var archived = listed.filter(\.folder.isArchived)
        // The control plane's other hosts that answer, each stamped as its own.
        for host in reachableHosts.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let other = otherHosts[host],
                  let theirs = try? await other.call(DaemonAPI.Method.foldersList, request,
                                                     returning: [DaemonAPI.FolderSummary].self)
            else { continue }
            archived += theirs.filter(\.folder.isArchived).map { var summary = $0; summary.host = host; return summary }
        }
        archivedFolders = archived
    }

    /// A deleted folder (#677) out of the archived ones listed, as the shared model
    /// takes it out of its own.
    func forgetArchived(_ update: AgentsModel.Update) {
        if case .folderRemoved(let key) = update { archivedFolders.removeAll { $0.key == key } }
    }

    /// The archived folder a Delete… is asking about, until it is answered (#677).
    var askingToDeleteFolder: DaemonAPI.FolderSummary?

    /// Delete an archived folder (#677), once asked, through its own host: every
    /// session in it and its record; its folder stays. A refusal says which sessions
    /// hold it.
    func deleteFolder(_ summary: DaemonAPI.FolderSummary) async {
        let host = summary.host
        let target = host == .mac ? client : otherHosts[host]
        guard let target, !isStale(on: host), host == .mac || reachableHosts.contains(host) else {
            problem = "\(hostLabel(host)) is not answering, so that could not be sent."
            return
        }
        do {
            _ = try await target.call(DaemonAPI.Method.foldersDelete, DaemonAPI.FolderRequest(folder: summary.folder.folder),
                                      returning: DaemonAPI.Empty.self)
            work.removeFolder(summary.key)
            archivedFolders.removeAll { $0.key == summary.key }
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = sentence(for: error)
        }
    }

    /// A folder pinned to the top of the sidebar, or not, through its own host.
    /// The folder joins a project (#2317), through its own machine, as the window's Folder
    /// Settings ▸ Project. Nil, or why not.
    func setProject(_ project: String, for summary: DaemonAPI.FolderSummary) async -> String? {
        let host = summary.host
        guard let target = host == .mac ? client : otherHosts[host] else { return "The folder's machine is not connected." }
        do {
            var changed = try await target.call(DaemonAPI.Method.foldersSetProject,
                                                DaemonAPI.SetFolderProjectRequest(folder: summary.folder.folder,
                                                                                  project: project),
                                                returning: DaemonAPI.FolderSummary.self)
            changed.host = host
            work.upsert(changed)
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    func setPinned(_ pinned: Bool, for summary: DaemonAPI.FolderSummary) async {
        let host = summary.host
        guard let target = host == .mac ? client : otherHosts[host] else { return }
        do {
            var changed = try await target.call(DaemonAPI.Method.foldersSetPinned,
                                                DaemonAPI.SetPinnedRequest(folder: summary.folder.folder, pinned: pinned),
                                                returning: DaemonAPI.FolderSummary.self)
            changed.host = host
            work.upsert(changed)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// The folder an Archive… is asking about, until it is answered (#668).
    var askingToArchiveFolder: DaemonAPI.FolderSummary?

    /// Put a folder away (#668), once asked, through its own host, as the window's
    /// Archive: it moves to Archived folders, its sessions and folder kept. A refusal
    /// names the sessions to stop first.
    func archiveFolder(_ summary: DaemonAPI.FolderSummary) async {
        let host = summary.host
        let target = host == .mac ? client : otherHosts[host]
        guard let target, !isStale(on: host), host == .mac || reachableHosts.contains(host) else {
            problem = "\(hostLabel(host)) is not answering, so that could not be sent."
            return
        }
        do {
            var archived = try await target.call(DaemonAPI.Method.foldersArchive,
                                                 DaemonAPI.FolderRequest(folder: summary.folder.folder),
                                                 returning: DaemonAPI.FolderSummary.self)
            archived.host = host
            work.upsert(archived)
            if sidebarItem == .folder(summary.key) { sidebarItem = nil }
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Bring an archived folder back (#343), through its own host, as the window's Bring
    /// Back does: a folder again, with its new-session form open.
    func unarchiveFolder(_ summary: DaemonAPI.FolderSummary) async {
        let host = summary.host
        let target = host == .mac ? client : otherHosts[host]
        guard let target, host == .mac || reachableHosts.contains(host) else { return }
        do {
            var brought = try await target.call(DaemonAPI.Method.foldersUnarchive,
                                                DaemonAPI.FolderRequest(folder: summary.folder.folder),
                                                returning: DaemonAPI.FolderSummary.self)
            brought.host = host
            work.upsert(brought)
            archivedFolders.removeAll { $0.key == summary.key }
            sidebarItem = .folder(brought.key)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// What today has cost and what the reader will allow. The phone shows limits
    /// and never sets them. A daemon too old to know the method leaves this nil, and
    /// every surface shows what it showed before this feature.
    private func refreshCostState() async {
        guard let state = try? await client.call(DaemonAPI.Method.costState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.CostState.self) else { return }
        work.replaceCostState(state)
        for host in reachableHosts { await refreshServerCost(host) }
    }

    /// Cancel the wait shown in Waiting now, on the agent's own host (#2068), then refresh
    /// the authoritative list. A failure says why.
    func cancelWait(of agentID: UUID) async {
        let host = work.agent(agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "the wait could not be stopped.")
            return
        }
        do {
            let request = DaemonAPI.CancelWaitRequest(agentID: agentID)
            _ = try await client(for: request).call(DaemonAPI.Method.eventsCancelWait, request,
                                                    returning: [DaemonAPI.WaitingAgent].self)
        } catch {
            problem = away(error, "the wait could not be stopped.") ?? sentence(for: error)
        }
        await refreshEvents()
    }

    /// What the work used by hour and by day (#823), for the charts on Cost: the Mac's and
    /// every reachable server's, each moved into this device's days (#1267). Nil when no
    /// host knows the method.
    func usageHistory() async -> UsageHistory? {
        var histories: [UsageHistory] = []
        for host in chartHosts {
            if let history = try? await host.call(DaemonAPI.Method.usageHistory, Optional<String>.none,
                                                  returning: UsageHistory.self) {
                histories.append(history)
            }
        }
        return histories.isEmpty ? nil : .merged(histories)
    }

    /// Where the time of running chats went (#852), for the Time page, from every host as
    /// `usageHistory` is. The recap is the Mac's. Nil when no host knows the method.
    func timeHistory() async -> TimeHistory? {
        var histories: [TimeHistory] = []
        for host in chartHosts {
            if let history = try? await host.call(DaemonAPI.Method.timeHistory, Optional<String>.none,
                                                  returning: TimeHistory.self) {
                histories.append(history)
            }
        }
        return histories.isEmpty ? nil : .merged(histories)
    }

    /// The Mac first, then every other host reachable now.
    private var chartHosts: [DaemonClient] {
        [client] + reachableHosts.compactMap { otherHosts[$0] }
    }

    private func refreshServerCost(_ host: MachineRef) async {
        guard let other = otherHosts[host], reachableHosts.contains(host),
              let state = try? await other.call(DaemonAPI.Method.costState,
                                                Optional<String>.none,
                                                returning: DaemonAPI.CostState.self) else { return }
        serverCosts[host] = state
    }

    private func refreshServerDisk(_ host: MachineRef) async {
        guard let other = otherHosts[host], reachableHosts.contains(host),
              let state = try? await other.call(DaemonAPI.Method.diskState,
                                                Optional<String>.none, returning: DiskState.self) else { return }
        serverDisks[host] = state
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
        guard let snapshot = try? await client.call(DaemonAPI.Method.resourcesSnapshot,
                                                    Optional<String>.none,
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
        // The servers the Mac hosts for every agent (#488), read with them for their page (#589).
        if let hosted = try? await client.call(DaemonAPI.Method.mcpHosted, Optional<String>.none,
                                               returning: DaemonAPI.HostedMCPSnapshot.self) {
            work.replaceHostedMCP(hosted)
        }
        // Every MCP server on the Mac and how each is doing (#753).
        if let health = try? await client.call(DaemonAPI.Method.mcpHealth, Optional<String>.none,
                                               returning: DaemonAPI.MCPHealthSnapshot.self) {
            work.replaceMCPHealth(health)
        }
    }

    /// Check Now on the person's own servers (no folder) or a folder's (#753), on the
    /// folder's own host.
    func checkMCPHealth(folder: FolderKey?) async {
        let host = folder?.host ?? .mac
        guard let target = hostClient(host),
              let snapshot = try? await target.call(DaemonAPI.Method.mcpHealthCheck,
                                                    DaemonAPI.MCPHealthCheckRequest(folder: folder?.folder.path),
                                                    returning: DaemonAPI.MCPHealthSnapshot.self) else { return }
        work.replaceMCPHealth(snapshot, from: host)
    }

    /// Every folder's worktrees on the Mac, for Activity ▸ Worktrees (#790). Sizes not
    /// measured yet come later, on `worktrees/sized`.
    func loadWorktrees() async {
        guard let listed = try? await client.call(DaemonAPI.Method.worktreesAll, DaemonAPI.Empty(),
                                                  returning: [DaemonAPI.FolderWorktrees].self) else { return }
        work.replaceWorktrees(listed)
    }

    /// What removing one of a folder's worktrees would lose; nil when it could not be
    /// asked, and `problem` says why.
    func checkWorktreeRemoval(_ root: URL, in folder: URL) async -> DaemonAPI.RemovalCheck? {
        do {
            return try await client.call(DaemonAPI.Method.worktreesCheck,
                                         DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root),
                                         returning: DaemonAPI.RemovalCheck.self)
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// Remove one of a folder's worktrees; the Mac checks again either way.
    func removeWorktree(_ root: URL, in folder: URL, confirmed: Bool) async {
        do {
            _ = try await client.call(DaemonAPI.Method.worktreesRemove,
                                      DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root, confirmed: confirmed),
                                      returning: DaemonAPI.WorktreeRemoved.self)
        } catch {
            problem = sentence(for: error)
        }
        await loadWorktrees()
    }

    /// Delete an idle worktree's build output, and say what it freed; nil when it could not.
    func removeBuildOutput(_ root: URL, in folder: URL) async -> String? {
        defer { Task { await loadWorktrees() } }
        do {
            let removed = try await client.call(DaemonAPI.Method.worktreesRemoveBuildOutput,
                                                DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root),
                                                returning: DaemonAPI.BuildOutputRemoved.self)
            return WorktreeTally.freedWords(removed)
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// Clean up worktrees (030): the folder's new session, its prompt offered the words
    /// after anything half-typed there (#1863), as the window's does.
    func offerCleanUp(in folder: URL) {
        let keeper = StartDraftKeeper.shared
        let draft = Draft.givingBack(WorktreeTally.cleanUpPrompt, to: keeper.draft(in: folder))
        keeper.note(draft.text, draft.attachments, in: folder)
        StartDraftKeeper.shared.flush()
        openActivity = nil
        // With its own host: a server's folder kept as the Mac's was never found again (#2160).
        sidebarItem = .folder(work.folder(folder)?.key ?? FolderKey(host: .mac, folder: folder))
    }

    /// Every volume on the Mac low on space (#196), for the strip under the banner. A Mac
    /// too old to know the method leaves it empty, and no strip is drawn.
    private func refreshDisk() async {
        guard let state = try? await client.call(DaemonAPI.Method.diskState, Optional<String>.none,
                                                 returning: DiskState.self) else { return }
        work.replaceDisk(state)
    }

    /// The files the Mac's host could not read in this run (#205, #223), then heard as
    /// they change. A Mac too old to know the method leaves the list empty, as it would
    /// be with nothing to say.
    private func refreshStoreNotes() async {
        guard let notes = try? await client.call(DaemonAPI.Method.storeNotes, Optional<String>.none,
                                                 returning: DaemonAPI.StoreNotes.self) else { return }
        work.replaceStoreNotes(notes)
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
    /// Every folder's, in one call, the way the window asks for them. `workflow/changed`
    /// keeps them current afterwards; without this first fetch the section would stay
    /// empty until something happened to a workflow, which on a quiet folder is never.
    func refreshWorkflows() async {
        guard let listed = try? await client.call(DaemonAPI.Method.workflowsList,
                                                  DaemonAPI.WorkflowsListRequest(),
                                                  returning: [WorkflowSummary].self) else { return }
        work.replaceWorkflows(listed)
    }

    func writeUserWorkflow(id: String, content: String) async -> String? {
        do {
            let request = DaemonAPI.WorkflowWriteRequest(workflowID: id, content: content)
            _ = try await client(for: request).call(DaemonAPI.Method.workflowsWrite, request,
                                                    returning: WorkflowSummary.self)
            await refreshWorkflows()
            return nil
        } catch {
            await refreshWorkflows()
            return sentence(for: error)
        }
    }

    /// One of a view's calls (#187), to the Mac.
    func viewCall(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await client.call(method, params)
    }

    // MARK: Pinned pages (#159)

    /// What this agent changed, from the daemon's bounded change list (#245).
    func changes(for agentID: UUID) async throws -> ChangesList {
        try await client.call(DaemonAPI.Method.changesList,
                              DaemonAPI.ChangesListRequest(agentID: agentID),
                              returning: ChangesList.self)
    }

    func changeDetail(for agentID: UUID, path: String, whole: Bool = false) async throws -> ChangedFileDetail {
        try await client.call(DaemonAPI.Method.changesFile,
                              DaemonAPI.ChangesFileRequest(agentID: agentID, path: path, whole: whole),
                              returning: ChangedFileDetail.self)
    }

    func pins(in folder: URL?) -> [PinView] { work.pins(in: folder) }
    /// The folder's servers' list views (#2032), the hidden ones too.
    func serverViews(in folder: URL?) -> [PinView] { work.serverViews(in: folder) }

    /// Hide or Show on a server's list view (#2032): shown at once, then the host told.
    func setViewHidden(_ uri: String, _ hidden: Bool, in folder: URL) async {
        work.setViewHidden(uri, hidden, in: folder)
        if hidden, openPin == uri { openPin = nil }
        do {
            try await client.call(DaemonAPI.Method.pinsHideView,
                                  DaemonAPI.PinHideViewRequest(folder: folder, uri: uri, hidden: hidden))
        } catch {
            problem = sentence(for: error)
        }
    }

    func refreshPins() async {
        guard let listed = try? await client.call(DaemonAPI.Method.pinsList, DaemonAPI.Empty(),
                                                  returning: [FolderPins].self) else { return }
        work.replacePins(listed)
    }

    /// A file of the folder's: a pinned page, a page tile's, or what an HTML page draws.
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

    /// Pin a view under a folder (#189), from its menu in a chat. Why it was not, or nil.
    func pinView(_ view: ViewPin, in folder: URL) async -> String? {
        do {
            let pins = try await client.call(DaemonAPI.Method.pinsPin, DaemonAPI.PinRequest(folder: folder, view: view),
                                             returning: [PinView].self)
            work.setPins(pins, in: folder)
            return nil
        } catch {
            return sentence(for: error)
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
        pinnedSessions(in: agent.folderPath).contains(agent.id)
    }

    /// Pin or Unpin from a card's menu or swipe: shown at once, then the Mac told.
    func setPinned(_ agent: Agent, _ pinned: Bool) async {
        let folder = agent.folderPath
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

    // MARK: Pinned workflows (#432)

    func pinnedWorkflows(in folder: URL?) -> [String] { work.pinnedWorkflows(in: folder) }

    func isPinned(_ summary: WorkflowSummary) -> Bool {
        pinnedWorkflows(in: summary.folder).contains(summary.workflowID)
    }

    /// Pin or Unpin from a workflow's menu, swipe or page: shown at once, then the host told.
    func setPinned(_ summary: WorkflowSummary, _ pinned: Bool) async {
        let folder = summary.folder
        let held = pinnedWorkflows(in: folder).filter { $0 != summary.workflowID }
        work.setWorkflowPins(pinned ? held + [summary.workflowID] : held, in: folder)
        do {
            let request = DaemonAPI.WorkflowRequest(folder: folder, workflowID: summary.workflowID)
            try await client(for: request).call(
                pinned ? DaemonAPI.Method.pinsPinWorkflow : DaemonAPI.Method.pinsUnpinWorkflow, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Move Up or Move Down among the pinned workflows: shown at once, the order sent once.
    func arrangeWorkflowPins(_ ids: [String], in folder: URL) async {
        work.setWorkflowPins(ids, in: folder)
        do {
            let request = DaemonAPI.PinArrangeWorkflowsRequest(folder: folder, workflowIDs: ids)
            try await client(for: request).call(DaemonAPI.Method.pinsArrangeWorkflows, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    // MARK: Driving a workflow

    /// Run one now. The Mac still applies the in-flight, ceiling and archive rules and
    /// says so on the summary, which is why nothing here second-guesses it first.
    func runWorkflow(_ summary: WorkflowSummary) async {
        do {
            let request = DaemonAPI.WorkflowRequest(folder: summary.folder, workflowID: summary.workflowID)
            try await client(for: request).call(DaemonAPI.Method.workflowsRun, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Put one away, or bring it back. `workflow/changed` redraws the page.
    func setWorkflowArchived(_ summary: WorkflowSummary, _ archived: Bool) async {
        do {
            let request = DaemonAPI.WorkflowArchiveRequest(folder: summary.folder,
                                                           workflowID: summary.workflowID,
                                                           archived: archived)
            try await client(for: request).call(DaemonAPI.Method.workflowsArchive, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Delete a workflow's file from its folder (#605).
    func deleteWorkflow(_ summary: WorkflowSummary) async -> Bool {
        do {
            let request = DaemonAPI.WorkflowRequest(folder: summary.workflow.folder,
                                                    workflowID: summary.workflow.workflowID)
            try await client(for: request).call(DaemonAPI.Method.workflowsDelete, request)
            return true
        } catch {
            problem = sentence(for: error)
            return false
        }
    }

    /// Let a waiting one run as its file now reads (#142): the digest is what the page
    /// was showing, so a file changed since is still waiting afterwards.
    func approveWorkflow(_ summary: WorkflowSummary) async {
        await answerWorkflow(summary, DaemonAPI.Method.workflowsApprove)
    }

    /// Deny it on its host only (#391): it does not run there, its file is not touched,
    /// and Approve takes it back.
    func denyWorkflow(_ summary: WorkflowSummary) async {
        await answerWorkflow(summary, DaemonAPI.Method.workflowsDeny)
    }

    private func answerWorkflow(_ summary: WorkflowSummary, _ method: String) async {
        guard let waiting = summary.approvable else { return }
        do {
            let request = DaemonAPI.WorkflowApproveRequest(folder: summary.folder,
                                                            workflowID: summary.workflowID,
                                                            digest: waiting.digest)
            let updated: WorkflowSummary = try await client(for: request).call(
                method, request, returning: WorkflowSummary.self)
            keepWorkflow(updated, named: request)
        } catch {
            problem = sentence(for: error)
            await refreshWorkflows()
        }
    }

    /// Turn one on or off, keeping its place on the list (#100).
    func setWorkflowEnabled(_ summary: WorkflowSummary, _ enabled: Bool) async {
        do {
            let request = DaemonAPI.WorkflowEnableRequest(folder: summary.folder,
                                                          workflowID: summary.workflowID,
                                                          enabled: enabled)
            try await client(for: request).call(DaemonAPI.Method.workflowsEnable, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Whether a workflow's host can mute its runs: one from before #2003 cannot.
    func canMute(_ summary: WorkflowSummary) -> Bool {
        let host = work.folders.first { $0.folder.folder.absoluteString == summary.folder.absoluteString }?.host ?? .mac
        return !summary.isArchived && self.host(host, has: Capability.mute1)
    }

    /// Mute Notifications for a workflow's runs, or Unmute (#2003): `muted: true` in its file.
    func setWorkflowMuted(_ summary: WorkflowSummary, _ muted: Bool) async {
        do {
            let request = DaemonAPI.WorkflowMuteRequest(folder: summary.folder, workflowID: summary.workflowID, muted: muted)
            try await client(for: request).call(DaemonAPI.Method.workflowsSetMuted, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Clear a server's event trigger's missed-events mark (#383).
    func clearMCPMissed(_ summary: WorkflowSummary, _ status: MCPTriggerStatus) async {
        do {
            let request = DaemonAPI.WorkflowMCPClearMissedRequest(folder: summary.folder, workflowID: summary.workflowID,
                                                                  name: status.name, server: status.server)
            try await client(for: request).call(DaemonAPI.Method.workflowsClearMCPMissed, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Change what a workflow is allowed to do. The Mac's daemon writes the file and
    /// answers with what it now says; a refusal has to reach the person, and the list
    /// is asked again so the menu goes back to what the file still holds (FR-025).
    func setWorkflowSettings(_ summary: WorkflowSummary, _ settings: WorkflowSettings,
                             cooldown: String? = nil, labels: [String]? = nil,
                             runsOn: [String]? = nil, whenDone: String? = nil,
                             continueWhenBack: Bool? = nil) async {
        do {
            let request = DaemonAPI.WorkflowSettingsRequest(folder: summary.folder,
                                                            workflowID: summary.workflowID,
                                                            settings: settings, cooldown: cooldown,
                                                            labels: labels, runsOn: runsOn, whenDone: whenDone,
                                                            continueWhenBack: continueWhenBack)
            let updated: WorkflowSummary = try await client(for: request).call(
                DaemonAPI.Method.workflowsSettings, request, returning: WorkflowSummary.self)
            keepWorkflow(updated, named: request)
        } catch {
            problem = sentence(for: error)
            await refreshWorkflows()
        }
    }

    /// The computers the workflow page can pin to, under the names already on screen.
    var workflowHostChoices: [WorkflowHostChoice] {
        WorkflowHosts.choices(from: controlHosts, thisMachine: nil)
    }

    /// Keep a workflow the host still runs (#317). The host is the one the call named.
    private func keepWorkflow(_ summary: WorkflowSummary, named params: some Encodable) {
        let host = otherHost(named: params) ?? controlHome ?? .mac
        if !summary.workflow.runs(on: controlHosts.first(where: { $0.id == host })?.machineID) {
            work.removeWorkflow(summary.workflowID, in: summary.folder)
        } else {
            work.upsert(summary)
        }
    }

    /// What a runtime last advertised for a folder, for the workflow page's menus.
    /// Empty is an answer: nothing has been remembered for it there yet.
    func rememberedOptions(runtimeID: String, cwd: URL) async -> [ConfigOption] {
        let request = DaemonAPI.RememberedOptionsRequest(runtimeID: runtimeID, cwd: cwd)
        return (try? await client(for: request).call(DaemonAPI.Method.optionsRemembered, request,
                                                     returning: [ConfigOption].self)) ?? []
    }

    /// The mode last chosen for each runtime, on any device. `modes/changed` keeps it
    /// current afterwards. A Mac too old to know the method leaves the sheet opening
    /// on each runtime's own current mode.
    /// The person's display choices (#1033), kept on the Mac. This device's defaults mirror
    /// them, so every view reads them where it always did.
    @ObservationIgnored lazy var displayMirror = DisplayPreferenceMirror(defaults: .standard) { [weak self] changes in
        self?.sendDisplayPreferences(changes)
    }

    private func sendDisplayPreferences(_ changes: DaemonAPI.DisplayPreferences) {
        Task { _ = try? await client.call(DaemonAPI.Method.preferencesSet, changes,
                                         returning: DaemonAPI.DisplayPreferences.self) }
    }

    /// A Mac too old to know the method leaves this device's own choices as they are.
    private func refreshDisplayPreferences() async {
        guard let preferences = try? await client.call(DaemonAPI.Method.preferencesGet, Optional<Int>.none,
                                                       returning: DaemonAPI.DisplayPreferences.self) else { return }
        displayMirror.hostSaid(preferences)
    }

    private func refreshModes() async {
        guard let modes = try? await client.call(DaemonAPI.Method.modesRemembered, Optional<Int>.none,
                                                 returning: DaemonAPI.RememberedModes.self) else { return }
        work.replaceRememberedModes(modes)
    }

    /// Settings ▸ Backups (#1810): the Mac's. A Mac too old to keep backups answers
    /// nothing, which leaves the section out.
    func refreshBackupState() async {
        guard let state = try? await client.call(DaemonAPI.Method.backupsState, DaemonAPI.Empty(),
                                                 returning: DaemonAPI.BackupState.self) else { return }
        work.replaceBackupState(state)
    }

    func configureBackups(_ settings: DaemonAPI.BackupSettings) async throws {
        work.replaceBackupState(try await client.call(DaemonAPI.Method.backupsConfigure, settings,
                                                      returning: DaemonAPI.BackupState.self))
    }

    func makeBackup() async throws {
        work.replaceBackupState(try await client.call(DaemonAPI.Method.backupsMake, DaemonAPI.BackupMakeRequest(),
                                                      returning: DaemonAPI.BackupState.self))
    }

    func restoreBackup(_ backup: DaemonAPI.Backup) async throws -> DaemonAPI.BackupRestoreResult {
        try await client.call(DaemonAPI.Method.backupsRestore, DaemonAPI.BackupRestoreRequest(id: backup.id),
                              returning: DaemonAPI.BackupRestoreResult.self)
    }

    /// The Runtimes page's pass-through names; none from a Mac too old to say.
    func refreshPassThrough() async {
        passThrough = (try? await client.call(DaemonAPI.Method.settingsPassThrough, DaemonAPI.Empty(),
                                              returning: DaemonAPI.PassThroughState.self)) ?? DaemonAPI.PassThroughState()
    }

    /// A Mac too old to know the method has no policy to follow.
    private func refreshPolicyState() async {
        policyState = try? await client.call(DaemonAPI.Method.daemonPolicyState, DaemonAPI.Empty(),
                                             returning: DaemonAPI.PolicyState.self)
    }

    /// A Mac too old to know the method leaves every runtime as configured, which is
    /// what it does.
    private func refreshSandboxSettings() async {
        guard let settings = try? await client.call(DaemonAPI.Method.sandboxState, Optional<String>.none,
                                                    returning: SandboxSettings.self) else { return }
        sandboxSettings = settings
    }

    /// The permission choice is Mac-wide, even when the open folder is on a server.
    private func refreshClientPermissions() async {
        guard let settings = try? await client.call(DaemonAPI.Method.clientPermissionsState,
                                                    Optional<String>.none,
                                                    returning: ClientPermissionSettings.self) else { return }
        clientPermissions = settings
    }

    func setClientPermissions(_ settings: ClientPermissionSettings) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        do {
            clientPermissions = try await client.call(DaemonAPI.Method.clientPermissionsSet, settings,
                                                       returning: ClientPermissionSettings.self)
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    /// One agent's own sandbox choice from the phone (064); nil follows the default.
    func setAgentSandbox(_ agentID: UUID, _ choice: SandboxChoice?) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        do {
            let request = DaemonAPI.SetSandboxRequest(agentID: agentID, choice: choice)
            try await client(for: request).call(DaemonAPI.Method.agentsSetSandbox, request)
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    /// The sandbox card's answer, from the phone (064, FR-007a).
    func answerSandbox(_ agentID: UUID, carryOn: Bool) async {
        do {
            let request = DaemonAPI.AnswerSandboxRequest(agentID: agentID, carryOn: carryOn)
            try await client(for: request).call(DaemonAPI.Method.agentsAnswerSandbox, request)
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    private func refreshRuntimes() async {
        do {
            let listed = try await client.call(DaemonAPI.Method.runtimesList,
                                               Optional<String>.none,
                                               returning: [RuntimeStatus].self)
            runtimes = RuntimeCatalog.sortedByName(listed)
            runtimesFailure[.mac] = nil
        } catch {
            runtimesFailure[.mac] = sentence(for: error)
        }
        if let listed = try? await client.call(DaemonAPI.Method.runtimesAccounts,
                                               Optional<Int>.none,
                                               returning: [RuntimeAccount].self) {
            accounts = Dictionary(uniqueKeysWithValues: listed.map { ($0.runtimeID, $0) })
        }
        await refreshAccountProfiles()
    }

    /// A folder archived on the Mac while it is being read here moves the selection
    /// rather than leaving an empty screen.
    private func settleSelection() {
        guard let selectedFolder else { return }
        if !folders.contains(where: { $0.folder.folder == selectedFolder }) {
            self.selectedFolder = nil
        }
    }

    // MARK: The conversation

    /// The open chat's record whole, with the menus and plan a lean list leaves out (#107).
    /// A Mac too old to know `agentID` lists its newest instead, which is not this one.
    /// Whether its host answered, with it or without it (#2743).
    @discardableResult
    func loadWholeAgent(_ id: UUID) async -> Bool {
        let request = DaemonAPI.ListRequest.whole(id)
        guard let listed = try? await client(for: request).call(DaemonAPI.Method.agentsList, request,
                                                                returning: [Agent].self) else { return false }
        guard var whole = listed.first(where: { $0.id == id }) else { return true }
        whole.host = work.agent(id)?.host ?? whole.host
        work.takeListed([whole])
        return true
    }

    func loadTranscript() async {
        guard let selection else { work.clearTranscript(); return }
        // Beside the transcript rather than before it, and not cancelled by its returns.
        let whole = Task { await loadWholeAgent(selection) }
        // The last few finished turns as summaries, as the window opens with (#242), then
        // the turn in progress. A Mac too old to keep turns gives the lot. Both from the
        // chat's own host (058).
        //
        // Only the latest load puts its answer on screen: opening the chat and a
        // catch-up both load it, and the older answer could land last (#400).
        let load = work.beginTranscriptLoad()
        let turnsRequest = DaemonAPI.TurnsRequest.opening(selection)
        let pageSize = firstPageSize
        // Whether its host answered: with the history, or that it has no such session.
        var answered = true
        do {
            let opening = try await ChatOpening.load(
                limit: pageSize,
                turns: {
                    try await client(for: turnsRequest).call(DaemonAPI.Method.agentsTurns, turnsRequest,
                                                             returning: TurnsPage.self)
                },
                transcript: { from, limit in
                    let request = DaemonAPI.TranscriptRequest(agentID: selection, limit: limit, from: from)
                    return try await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                               returning: TranscriptPage.self)
                },
                describe: Self.describeLoadFailure)
            // A chat left before its page arrived does not get that page shown under the
            // next one's name.
            guard self.selection == selection else { return }
            work.takeOpening(opening, load: load)
            if let why = opening.turnsFailure { note("chat: turns of \(selection) did not load: \(why)") }
        } catch {
            // Said in the chat, with Try Again, where it used to stay blank without a
            // word until the next reconnect (#400).
            note("chat: history of \(selection) did not load: \(error)")
            guard self.selection == selection else { return }
            work.failOpening(Self.describeLoadFailure(error), load: load)
            answered = ChatOpening.saysGone(error)
        }
        // Looked for once its host has answered both: from here a session not in hand has
        // gone (#2652). A call that failed is no answer, and the chat says it with Try
        // Again rather than calling the session deleted (#2743).
        guard await whole.value, answered, self.selection == selection else { return }
        lookedForSelection = selection
    }

    /// A chat's history that did not come, in words (#400).
    private static func describeLoadFailure(_ error: any Error) -> String {
        switch error {
        // The strip over the chat says why; this, what is shown, in the window's words (#963).
        case is HostAway: OfflineWords.lastHeard
        case let error as JSONRPCError where error.code == DaemonAPI.Failure.hostOffline: OfflineWords.lastHeard
        case is MacAway: "your Mac can't be reached right now."
        case is DaemonClient.NoAnswer: "no answer from your Mac in time."
        case let error as JSONRPCError: error.message
        default: "the connection to your Mac was lost."
        }
    }

    /// An entry its host sent as a stub, too big to send to every chat (#203), read here.
    func loadOversized(_ entryID: UUID, of agentID: UUID, at index: Int?) async {
        let request = DaemonAPI.TranscriptRequest.around(index, of: agentID)
        guard let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                              returning: TranscriptPage.self),
              let entry = page.entries.first(where: { $0.id == entryID }) else { return }
        work.fillOversized(entry, for: agentID)
        popouts[agentID]?.work.fillOversized(entry, for: agentID)
    }

    /// A finished turn's entries, for the chat to open it: the last page of them when
    /// the turn is longer than a host gives in one answer (#200).
    /// Nil when they did not come, which the chat says and asks again for (#400).
    func turnEntries(_ agentID: UUID, _ range: Range<Int>) async -> TranscriptPage? {
        let request = DaemonAPI.TranscriptRequest(agentID: agentID, before: range.upperBound,
                                                  limit: min(range.count, DaemonAPI.TranscriptRequest.limitCeiling),
                                                  from: range.lowerBound)
        do {
            return try await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                       returning: TranscriptPage.self)
        } catch {
            note("chat: steps of \(agentID) did not load: \(error)")
            return nil
        }
    }

    /// Another page, backwards. Never the whole history: that is the difference
    /// between a conversation opening in a second and one opening on a train.
    /// A source file's problems, from its language server on the agent's host (#844).
    /// A failure is thrown, for the editor to say (#1687).
    func diagnose(path: String, text: String, of agentID: UUID) async throws -> DaemonAPI.FileDiagnostics {
        let request = DaemonAPI.FileDiagnosticsRequest(agentID: agentID, path: path, text: text)
        return try await client(for: request).call(DaemonAPI.Method.filesDiagnostics, request,
                                                   returning: DaemonAPI.FileDiagnostics.self)
    }

    /// What the file's language server would write at a line and column (#1603), or why
    /// there is nothing: the host's reason, or the failure (#1688).
    func complete(path: String, text: String, line: Int, column: Int, of agentID: UUID) async -> DaemonAPI.FileCompletions {
        let request = DaemonAPI.FileCompletionRequest(agentID: agentID, path: path, text: text, line: line, column: column)
        do {
            return try await client(for: request).call(DaemonAPI.Method.filesComplete, request,
                                                       returning: DaemonAPI.FileCompletions.self)
        } catch {
            return DaemonAPI.FileCompletions(items: [], reason: DaemonAPI.FileCompletions.failure(error))
        }
    }

    /// The Simulator pane's calls (#842), to the session's host.
    func simulatorCalls(for agentID: UUID) -> SimulatorCalls {
        let host = { try self.client(for: DaemonAPI.AgentRequest(agentID: agentID)) }
        return SimulatorCalls(
            list: { try await host().call(DaemonAPI.Method.simulatorsList, Optional<String>.none,
                                          returning: DaemonAPI.SimulatorList.self) },
            boot: { udid in _ = try await host().call(DaemonAPI.Method.simulatorsBoot,
                                                      DaemonAPI.SimulatorRequest(udid: udid)) },
            shutdown: { udid in _ = try await host().call(DaemonAPI.Method.simulatorsShutdown,
                                                          DaemonAPI.SimulatorRequest(udid: udid)) },
            screen: { udid, maxHeight in try await host().call(
                DaemonAPI.Method.simulatorsScreen, DaemonAPI.SimulatorScreenRequest(udid: udid, maxHeight: maxHeight),
                                                    returning: DaemonAPI.SimulatorScreen.self) },
            tap: { udid, x, y in _ = try await host().call(
                DaemonAPI.Method.simulatorsTap, DaemonAPI.SimulatorTapRequest(udid: udid, x: x, y: y)) },
            home: { udid in _ = try await host().call(
                DaemonAPI.Method.simulatorsHome, DaemonAPI.SimulatorRequest(udid: udid)) })
    }

    /// Find in Chat (#1532): what was said in a chat that holds `text`, found by its host.
    func find(_ text: String, in agentID: UUID) async -> DaemonAPI.FindResult? {
        let request = DaemonAPI.FindRequest(agentID: agentID, text: text)
        return try? await client(for: request).call(DaemonAPI.Method.agentsFind, request,
                                                    returning: DaemonAPI.FindResult.self)
    }

    /// Go to a match in the open chat: earlier pages come in until its turn is in hand
    /// (`AgentsModel.reveal`, bounded), then the chat goes to it, or as near as it can.
    func reveal(_ match: DaemonAPI.FindMatch) async {
        await work.reveal(index: match.index) { await self.loadEarlier(turns: $0) }
        focusedIndex = match.index
        focusedEntry = match.entryID
    }

    func loadEarlier(turns limit: Int = 50) async {
        guard let selection, work.hasMoreOfTheConversation, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        // Past the start of the turn in progress, the turns before it.
        if !work.hasMoreBefore {
            let turnsRequest = DaemonAPI.TurnsRequest(agentID: selection, before: work.firstTurn, limit: limit)
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
        let host = work.agent(request.agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that could not be sent.")
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
        let host = work.agent(request.agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that could not be sent.")
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

    /// An answer pressed on a banner (#1170): the card's own answer, the same call to the
    /// same host, sent with the app in the background, perhaps just woken for it.
    ///
    /// Back in touch first, as a background refresh is, and caught up when the question
    /// is not held yet. A question no longer asked was answered somewhere else: nothing
    /// is sent, and the catch-up's sweep takes its banner away. An answer that did not go
    /// puts the banner back, silently, so the question is not lost with it. The log says
    /// the need, the button and how it went, never what was typed.
    @discardableResult
    func answerFromBanner(_ token: String, _ quick: QuickAnswer, typed: String?) async -> Bool {
        let began = ContinuousClock.now
        note("banner: \(token) \(quick.kind.rawValue) pressed")
        if !isConnected {
            if !reconnect.isRunning { Task { await connect() } }
            await goBackNow(.wake)
            let deadline = ContinuousClock.now + Self.bannerPatience
            while !isConnected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if bannerQuestion(token) == nil { await catchUp() }
        let sent: Bool
        switch bannerQuestion(token) {
        case .permission(let request):
            sent = await answer(request, optionID: quick.id)
        case .elicitation(let request):
            guard let content = quick.content(typed: typed) else {
                note("banner: \(token) nothing to send")
                return false
            }
            sent = await answer(request, action: .accept, content: content)
        case nil:
            note("banner: \(token) is over, nothing sent, in \(ContinuousClock.now - began)")
            return false
        }
        note("banner: \(token) \(sent ? "answered" : "not sent"), in \(ContinuousClock.now - began)")
        if !sent, let need = work.needs.first(where: { $0.key.token == token })?.value {
            notifier.showAgain(need)
        }
        return sent
    }

    /// How long a banner's answer waits for the link: inside the half minute iOS gives an
    /// app woken for a notification's button.
    static let bannerPatience: Duration = .seconds(20)

    private enum BannerQuestion {
        case permission(PermissionRequest)
        case elicitation(ElicitationRequest)
    }

    /// The question a banner's token names, while it is still asked.
    private func bannerQuestion(_ token: String) -> BannerQuestion? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "permission":
            return work.permissions.first { $0.id.uuidString == parts[1] }.map(BannerQuestion.permission)
        case "elicitation":
            return work.elicitations.first { $0.id.uuidString == parts[1] }.map(BannerQuestion.elicitation)
        default:
            return nil
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
    /// `voice`: sent from voice mode (#2322), so the reply is short and fit to be heard.
    func send(_ what: String, attachments: [Attachment] = [], to agentID: UUID, voice: Bool = false) async -> Bool {
        let host = work.agent(agentID)?.host ?? .mac
        // A stopped workspace that starts when used: kept by the control plane (#691 US3).
        if host != .mac, isStale(on: host), startsWhenUsed(host) {
            guard attachments.isEmpty else {
                problem = "Attachments can’t wait for \(hostName(host)) to start. Send the words alone, or start it first."
                return false
            }
            guard await keepThroughControl(host, DaemonAPI.Method.agentsPrompt,
                                           DaemonAPI.PromptRequest(agentID: agentID, text: what, sendID: UUID(), voice: voice ? true : nil)) != nil
            else { return false }
            turnSent(to: agentID)
            return true
        }
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that was not sent.")
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
                                                       attachments: attachments, sendID: UUID(),
                                                       voice: voice ? true : nil))
            turnSent(to: agentID)
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
        } catch let error where DaemonAPI.PolicyRefusal(error: error) != nil {
            // The organisation's policy refused the turn (#998): its own words, not a lost Mac.
            problem = DaemonAPI.PolicyRefusal(error: error)!.line + " What you typed is still there."
            return false
        } catch {
            problem = (away(error, "that was not sent.") ?? "That did not reach your Mac.") + " What you typed is still there."
            return false
        }
    }

    /// A prompt went from here: its turn as a Live Activity (#1657).
    private func turnSent(to agentID: UUID) {
        let agent = work.agent(agentID)
        let folder = agent.map { work.folder($0.folderPath)?.name ?? $0.folderPath.lastPathComponent } ?? ""
        liveActivities.sent(to: agent, id: agentID, folder: folder)
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
                let request = DaemonAPI.SetOptionRequest(agentID: agentID, optionID: optionID, value: value)
                try await client(for: request).call(DaemonAPI.Method.agentsSetOption, request)
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
            let request = agent.goOnRequest(under: costLimits)
            let changed = try await client(for: request).call(DaemonAPI.Method.agentsSetCeiling, request,
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

    /// New words for a queued prompt, in its place in the queue (#1552). When it was sent or
    /// taken back first, the words go into the prompt bar, so nothing typed is lost.
    func editQueued(_ prompt: QueuedPrompt, text: String, of agentID: UUID) async {
        guard !isStale else {
            offeredPrompt = PromptOffer(agentID: agentID, words: text)
            problem = "Your Mac is not answering, so that could not be changed. Your words are in the prompt bar."
            return
        }
        do {
            let request = DaemonAPI.EditQueuedRequest(agentID: agentID, promptID: prompt.id, text: text)
            let result = try await client(for: request).call(DaemonAPI.Method.agentsEditQueued, request,
                                                             returning: DaemonAPI.EditQueuedResult.self)
            guard !result.edited else { return }
            offeredPrompt = PromptOffer(agentID: agentID, words: text)
            problem = QueuedPrompt.sentBeforeEdit
        } catch {
            offeredPrompt = PromptOffer(agentID: agentID, words: text)
            problem = "That did not reach your Mac. Your words are in the prompt bar."
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
        await act(.stop, on: agentID, DaemonAPI.Method.agentsStop, DaemonAPI.AgentStopRequest(agentID: agentID))
    }
    /// Stop a session and every session it started that is running (#835).
    func stopAll(_ agentID: UUID) async {
        for agent in [work.agent(agentID)].compactMap({ $0 }) + work.liveDescendants(of: agentID) where canStop(agent) {
            await stop(agent.id)
        }
    }

    func archive(_ agentID: UUID, andLeave: Bool = false) async {
        guard let undo = await ArchiveActions.archiveWithChildren(agentID, in: work, andLeave: andLeave,
                                                                   archiveOne: archiveOne) else { return }
        // Undo for a few seconds, at the foot of the screen (#1534).
        archiveUndo = undo
    }

    /// The last Archive, while Undo is offered for it (#1534).
    var archiveUndo: ArchiveUndo?

    /// Undo after Archive (#1534): Unarchive what that Archive put away.
    func undoArchive() async {
        guard let undo = archiveUndo else { return }
        archiveUndo = nil
        for id in undo.agentIDs { await unarchive(id) }
    }

    func dismissArchiveUndo(_ undo: ArchiveUndo) {
        if archiveUndo?.id == undo.id { archiveUndo = nil }
    }

    @discardableResult
    private func archiveOne(_ agentID: UUID, andLeave: Bool) async -> Bool {
        let archived = await act(.archive, on: agentID, DaemonAPI.Method.agentsArchive,
                                 DaemonAPI.AgentRequest(agentID: agentID))
        // Not when it failed: the chat stays in front, under the reason why.
        if archived, andLeave {
            if selection == agentID { selection = nil }
            // A folder's own screen or scene goes back to its list (#2090).
            for state in folderScenes.values where state.pick == .session(agentID) { state.pick = nil }
        }
        return archived
    }

    /// **Continue in New** (#999): a session in the same folder that reads this one and
    /// carries on, on the runtime's account for new sessions, and open it.
    @discardableResult
    func continueInNew(_ agentID: UUID) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsContinueInNew,
                                        DaemonAPI.ContinueInNewRequest(agentID: agentID, requestID: UUID())).decode(UUID.self)
            await loadWholeAgent(id)
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

    /// Continue in the folder (#119): a successor that reads this session and
    /// carries on, with whatever was typed, opened once the Mac has started it.
    @discardableResult
    func continueInFolder(_ agentID: UUID, text: String = "", attachments: [Attachment] = []) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        let folder = work.agent(agentID)?.folderPath
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsContinueInFolder,
                                        DaemonAPI.ContinueInFolderRequest(agentID: agentID, text: text,
                                                                           attachments: attachments,
                                                                           requestID: UUID())).decode(UUID.self)
            await loadWholeAgent(id)
            if let folder { selectedFolder = folder }
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
            await loadWholeAgent(agentID)
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = "That did not reach your Mac."
        }
    }
    /// Carry on when the allowance is back, or no longer (#1859).
    func continueWhenBack(_ agentID: UUID) async { await waitForAllowance(agentID, DaemonAPI.Method.agentsContinueWhenBack) }
    func cancelContinue(_ agentID: UUID) async { await waitForAllowance(agentID, DaemonAPI.Method.agentsCancelContinue) }

    private func waitForAllowance(_ agentID: UUID, _ method: String) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await sendOnce(method, DaemonAPI.AgentRequest(agentID: agentID))
            await loadWholeAgent(agentID)
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// Branch (#342): a new session that carries the history so far, the original left
    /// alone, as the Mac's row has it. Opened once its host has started it.
    func fork(_ agentID: UUID) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        let folder = work.agent(agentID)?.folderPath
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsFork,
                                        DaemonAPI.AgentRequest(agentID: agentID)).decode(UUID.self)
            await loadWholeAgent(id)
            if let folder { selectedFolder = folder }
            selection = id
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }
    /// Branch from Here (#1658): a new session from just before one of the person's prompts,
    /// opened as Branch opens one, with that prompt in its bar to change and send. The words
    /// go in as the new session's draft, so its bar has them however it comes on screen.
    func branch(from entryID: UUID, of agentID: UUID, text: String) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        let folder = work.agent(agentID)?.folderPath
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsBranchFrom,
                                        DaemonAPI.BranchFromRequest(agentID: agentID, entryID: entryID))
                .decode(UUID.self)
            StartDraftKeeper.shared.note(text, [], for: .agent(id))
            await loadWholeAgent(id)
            if let folder { selectedFolder = folder }
            selection = id
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }
    func unarchive(_ agentID: UUID) async { await act(DaemonAPI.Method.agentsUnarchive, agentID) }

    /// The archived session a menu's Delete… is asking about, until it is answered (#398).
    var askingToDelete: Agent?

    /// The session a menu's Rename… is asking a title for, until it is answered (#751),
    /// and what has been typed.
    var renaming: Agent?
    var renameText = ""

    /// Rename… from a row's menu or the chat's ···: the field starts on the title it has.
    func askToRename(_ agent: Agent) {
        renameText = agent.title ?? ""
        renaming = agent
    }

    /// The person's title for a session (#751), kept by its host and told to every client.
    /// Empty, the runtime names it again.
    func rename(_ agentID: UUID, to title: String) async {
        let host = work.agent(agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that could not be sent.")
            return
        }
        do {
            let request = DaemonAPI.RenameRequest(agentID: agentID, title: title)
            try await client(for: request).call(DaemonAPI.Method.agentsRename, request)
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// Delete an archived session (#398), once asked. A refusal says why it cannot go yet.
    func delete(_ agentID: UUID) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await sendOnce(DaemonAPI.Method.agentsDelete, DaemonAPI.AgentRequest(agentID: agentID))
            if selection == agentID { selection = nil }
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }
    /// What is on its way to this agent, if anything: for the control that sent it to
    /// show, and the others to hold (#87).
    func acting(_ agentID: UUID) -> AgentAct? { work.acting[agentID] }

    /// Ask the Mac to start a session's runtime ahead of a prompt (#183): the chat was
    /// opened, or somebody is typing in it. Once per session and reason in a while,
    /// however many keys; the Mac debounces too. Silent: nothing is said if it fails.
    func prewarm(_ agentID: UUID, _ why: DaemonAPI.PrewarmRequest.Why) async {
        guard let agent = agent(agentID), !isStale(agent),
              agent.state == .finished || agent.state == .stopped else { return }
        let key = "\(agentID) \(why.rawValue)"
        if let last = prewarmed[key], Date().timeIntervalSince(last) < 15 { return }
        prewarmed[key] = Date()
        if prewarmed.count > 64 { prewarmed = prewarmed.filter { Date().timeIntervalSince($0.value) < 15 } }
        // To the agent's own host, which is the one with its runtime to start (#238).
        let request = DaemonAPI.PrewarmRequest(agentID: agentID, why: why)
        _ = try? await client(for: request).call(DaemonAPI.Method.agentsPrewarm, request)
    }

    /// Mark as Unread / Mark as Read, from the card's menu (#70).
    func setUnread(_ agentID: UUID, _ unread: Bool) async {
        let host = work.agent(agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that could not be sent.")
            return
        }
        do {
            // The mark is kept by the agent's own host, and told from there (#238).
            let request = DaemonAPI.SetUnreadRequest(agentID: agentID, unread: unread)
            try await client(for: request).call(DaemonAPI.Method.agentsSetUnread, request)
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// Mute Notifications, or Unmute, from the row's menu or the chat's ··· (#2003).
    func setMuted(_ agentID: UUID, _ muted: Bool) async {
        let host = work.agent(agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that could not be sent.")
            return
        }
        do {
            // The mark is kept by the agent's own host, which sends no push for it.
            let request = DaemonAPI.SetMutedRequest(agentID: agentID, muted: muted)
            try await client(for: request).call(DaemonAPI.Method.agentsSetMuted, request)
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// Whether this session's host can mute it: one from before #2003 cannot.
    func canMute(_ agent: Agent) -> Bool {
        agent.state != .archived && host(agent.host, has: Capability.mute1)
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
            // the home host's to stop or archive (073).
            let request = DaemonAPI.AgentRequest(agentID: agentID)
            try await sendOnce(method, request)
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// What to say when a send did not go because its host is away (#208): the home host
    /// or another of the control plane's, by name. Nil for any other failure.
    private func away(_ error: any Error, _ outcome: String) -> String? {
        if error is MacAway { return notAnswering(.mac, outcome) }
        guard let away = error as? HostAway else { return nil }
        return notAnswering(away.host, outcome)
    }

    /// "… is not answering, so …", naming the host: the home host as the Mac, another
    /// by its name (#238).
    private func notAnswering(_ host: MachineRef, _ outcome: String) -> String {
        "\(host == .mac ? "Your Mac" : hostName(host)) is not answering, so \(outcome)"
    }

    /// Another of the control plane's hosts, by the name it was given.
    func hostName(_ host: MachineRef) -> String {
        controlHosts.first { $0.id == host }.map { $0.name.isEmpty ? $0.id.rawValue : $0.name } ?? "That machine"
    }

    func dismissProblem() { problem = nil }

#if DEBUG
    /// Open a named folder, and optionally a named agent, straight after connecting.
    ///
    /// Scaffolding for the phase this app is in: there is no Simulator window on this
    /// machine to tap, and a layout nobody can look at is a layout nobody can settle.
    /// `-folder Agents -agent "Lay the remote out for a phone"` lands on that screen.
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
        if let name = value("-folder"),
           let summary = work.folders.first(where: { $0.name == name }) {
            // Its page is New session (#366).
            selectedFolder = summary.folder.folder
            composing = true
        }
        if let title = value("-agent"),
           let agent = work.agents.first(where: { $0.title == title }) {
            selectedFolder = agent.folderPath
            // A beat, so the folder has been pushed before the conversation is. Two
            // pushes in one turn of the loop is not something to ask of a split view.
            try? await Task.sleep(for: .milliseconds(600))
            selection = agent.id
            // `-archive-open`: then Archive from the chat's bar, for a walk (#2090): the walk
            // socket presses no menu.
            if arguments.contains("-archive-open") {
                try? await Task.sleep(for: .seconds(2))
                await archive(agent.id, andLeave: true)
            }
        }
        // `-workflow` opens a workflow's page on the chosen folder, by its name.
        if let name = value("-workflow"),
           let workflow = work.workflows.first(where: { $0.workflow.name == name }) {
            selectedFolder = workflow.folder
            try? await Task.sleep(for: .milliseconds(600))
            openWorkflow = workflow.id
        }
    }
#endif
}

/// A send refused because the agent's folder has gone (#119): what the Mac said, and what
/// was typed, for Continue in the folder to carry on with.
struct FolderGoneAsk: Identifiable, Equatable {
    let id = UUID()
    let agentID: UUID
    let message: String
    let text: String
    let attachments: [Attachment]
}

// MARK: Sessions in scenes of their own (#888)

extension RemoteModel {
    /// A scene of its own has opened on this session: its page of the transcript, loaded,
    /// and its host told to send it the session's entries, as the Mac's windows (#826).
    func openPopout(_ id: UUID) -> PoppedChat {
        let chat = popouts[id] ?? PoppedChat(id: id)
        chat.scenes += 1
        guard popouts[id] == nil else { return chat }
        chat.work.onOversized = { [weak self] agentID, entryID, index in
            Task { await self?.loadOversized(entryID, of: agentID, at: index) }
        }
        popouts[id] = chat
        popoutsChanged()
        Task { await loadTranscript(of: chat) }
        return chat
    }

    /// Its scene has closed. The last one lets the page go.
    func closePopout(_ chat: PoppedChat) {
        chat.scenes -= 1
        guard chat.scenes <= 0, popouts[chat.id] === chat else { return }
        popouts[chat.id] = nil
        if popoutInFront == chat.id { popoutInFront = nil }
        popoutsChanged()
    }

    /// Whether the scene showing this session is the key window: while it is, it is the
    /// one being watched, and a turn finishing there is read (#70).
    func popout(_ id: UUID, isInFront: Bool) {
        if isInFront {
            popoutInFront = id
        } else if popoutInFront == id {
            popoutInFront = nil
        }
        presence?.popped(Set(popouts.keys), inFront: popoutInFront)
    }

    /// Where an entry or terminal output for a session in a scene of its own goes too.
    func applyToPopouts(_ update: AgentsModel.Update) {
        switch update {
        case .entry(let note): popouts[note.agentID]?.work.apply(update)
        case .terminalOutput(let note): popouts[note.agentID]?.work.apply(update)
        default: break
        }
    }

    /// The page of transcript a chat draws: its scene's own, or the main scene's.
    func page(_ popped: PoppedChat?) -> AgentsModel { popped?.work ?? work }

    /// The session a chat shows: its scene's own, or the main scene's selection.
    func chatID(_ popped: PoppedChat?) -> UUID? { popped?.id ?? selection }

    private func popoutsChanged() {
        work.shown.also = Set(popouts.keys)
        presence?.popped(Set(popouts.keys), inFront: popoutInFront)
    }

    /// Archived sessions no screen shows any more, less those in scenes of their own.
    fileprivate func archivedToLetGo(_ agents: [Agent], folders: Set<URL>, chat: UUID?) -> [UUID] {
        ClientHolding.archivedToLetGo(agents, folders: folders, chat: chat).filter { popouts[$0] == nil }
    }

    /// A session's transcript in a scene of its own, loaded as the main scene's is, into
    /// that scene's own page of it.
    func loadTranscript(of chat: PoppedChat) async {
        let id = chat.id
        let whole = Task { await loadWholeAgent(id) }
        let load = chat.work.beginTranscriptLoad()
        let turnsRequest = DaemonAPI.TurnsRequest.opening(id)
        let pageSize = firstPageSize
        var answered = true
        do {
            let opening = try await ChatOpening.load(
                limit: pageSize,
                turns: {
                    try await client(for: turnsRequest).call(DaemonAPI.Method.agentsTurns, turnsRequest,
                                                             returning: TurnsPage.self)
                },
                transcript: { from, limit in
                    let request = DaemonAPI.TranscriptRequest(agentID: id, limit: limit, from: from)
                    return try await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                               returning: TranscriptPage.self)
                },
                describe: Self.describeLoadFailure)
            // A scene closed while it loaded has nothing to put it in.
            guard popouts[id] === chat else { return }
            _ = chat.work.takeOpening(opening, load: load)
        } catch {
            note("chat: history of \(id) did not load in its own scene: \(error)")
            guard popouts[id] === chat else { return }
            chat.work.failOpening(Self.describeLoadFailure(error), load: load)
            answered = ChatOpening.saysGone(error)
        }
        // Looked for once its host has answered both, as the main scene's (#2743).
        guard await whole.value, answered else { return }
        chat.looked = true
    }

    /// An earlier page of a session in a scene of its own, as `loadEarlier`.
    func loadEarlier(of chat: PoppedChat) async {
        let id = chat.id
        let work = chat.work
        guard work.hasMoreOfTheConversation, !chat.isLoadingEarlier else { return }
        chat.isLoadingEarlier = true
        defer { chat.isLoadingEarlier = false }
        if !work.hasMoreBefore {
            let turnsRequest = DaemonAPI.TurnsRequest(agentID: id, before: work.firstTurn)
            guard let turns = try? await client(for: turnsRequest).call(
                DaemonAPI.Method.agentsTurns, turnsRequest, returning: TurnsPage.self),
                popouts[id] === chat else { return }
            work.prependTurns(turns)
            return
        }
        let request = DaemonAPI.TranscriptRequest(agentID: id, before: work.firstEntryIndex,
                                                  limit: firstPageSize, from: work.openTurnStart)
        guard let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                              returning: TranscriptPage.self),
              popouts[id] === chat else { return }
        work.prepend(page)
    }
}
