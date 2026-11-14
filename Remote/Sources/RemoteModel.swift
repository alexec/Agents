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
    /// This device's local copy (#4791): sessions and chat ends kept in the app's Caches,
    /// drawn at launch before the Mac answers. The Mac always wins.
    @ObservationIgnored var localCopy: LocalCopyKeeper?
    var labelVocabularies: [URL: [String]] = [:]
    @ObservationIgnored var attentionRefreshTask: Task<Void, Never>?

    /// Whether the Mac is answering, and when it last did.
    var isConnected = false {
        didSet { if oldValue, !isConnected { liveUntil = Date() } }
    }
    /// When what the phone holds was last live with the Mac (#1163): the moment touch was
    /// lost. Nil before the first connection since launch, when the phone holds nothing.
    var liveUntil: Date?
    /// When the Needs you count was last true, for the "Last update" line beside it: nil
    /// while live, when it is true now (#1163, #5141).
    var needsYouUpdatedAt: Date? { isConnected ? nil : lastReadAt }
    var lastHeardFrom: Date?
    var problem: String?
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

    /// Which folder is being looked at, with its host: two machines can each have a folder
    /// at one path (#3446), as the window's `selectedFolderHost` and the web's route keep.
    /// Not the daemon's business: it owns what is true about the work, and which of it
    /// somebody happens to be reading is not that.
    var selectedKey: FolderKey? {
        didSet {
            guard selectedKey != oldValue else { return }
            composing = false
            selection = nil
            openWorkflow = nil
            openPin = nil
            openArchive = nil
            if selectedKey != nil { openActivity = nil }
            letGoOfFolders(keeping: selectedFolder)
        }
    }

    /// The selected folder's path, whichever host it is on.
    var selectedFolder: URL? { selectedKey?.folder }

    /// A folder known by its path alone, on whichever host the list has it: what a launch
    /// argument names. The Mac's when the list has none.
    func folderKey(_ folder: URL) -> FolderKey {
        work.folder(folder)?.key ?? FolderKey(host: .mac, folder: folder)
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
            // From For Review when it had a file to see (#3194): that group keeps it instead.
            keptHadFile = selection.flatMap { work.agent($0) }?.fileToSee != nil
            letGoOfChats(keeping: selection)
            Task { await loadTranscript() }
        }
    }

    /// The selection once it has been looked for, as `PoppedChat.looked`: from then a
    /// selected session not in hand is one that has gone (#2652).
    var lookedForSelection: UUID?

    /// The sessions open in scenes of their own on an iPad (#888), each with its own page
    /// of its transcript. See `PoppedChat`.
    var popouts: [UUID: PoppedChat] = [:]
    /// The folders open on their own (#1089): a scene each on an iPad, the screen on an
    /// iPhone. Each with what it has picked, so a notification can open a session in it.
    var folderScenes: [FolderKey: RemoteFolderState] = [:]
    /// The folder an iPhone shows alone, over the sidebar of every folder (#1089).
    var phoneFolder: FolderKey?
    /// The agent browser or a simulator taken over on an iPhone (#4141), as a full-screen
    /// cover; an iPad opens a scene of its own instead.
    var takeOver: TakeOverKey?
    /// The folder whose own scene's start page the start form is for, while one is (#1089).
    var composingScene: FolderKey?
    /// Brings a folder's scene forward, or opens it: handed over by a view that has the
    /// scene's action, for what is not a view (a notification).
    @ObservationIgnored var openFolderScene: ((FolderKey) -> Void)?
    /// The one of them in the key window, if one is: what the person is watching.
    @ObservationIgnored var popoutInFront: UUID?

    let client: DaemonClient
    /// 021: this device's banner, and its report of where the person is. Neither
    /// decides anything; the Mac routes and these two obey.
    let notifier = DeviceNotifier()
    /// A turn sent from here, on the Lock Screen and in the Dynamic Island (#1657).
    @ObservationIgnored let liveActivities = TurnActivities()
    var presence: PresenceReporter?
    /// Which device this is, minted once and kept. Told to the Mac right after every
    /// connection (`surface/identify`), so every later request on it is this device's.
    let deviceID = RemoteModel.deviceID

    nonisolated static var deviceID: UUID {
        let key = "device.id"
        if let text = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
    /// This device's key, made once and kept in this device's keychain. The Mac only
    /// ever sees the public half.
    let key: DeviceKey? = try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup)
    /// The mailbox's subscriptions are saved once per launch, the first time the Mac
    /// answers the announce.
    var subscribed = false
    /// This device, as the Mac has it: `nil` until the Mac has answered the announce.
    var thisDevice: Device?
    var listening: Task<Void, Never>?
    /// The loop looking for the Mac, so two of them never run at once; what a send lost
    /// with the connection waits on, for at most `sendPatience` (#208); stopped for good
    /// by a new pairing.
    @ObservationIgnored lazy var reconnect = ReconnectLoop(backoff: backoff) { [weak self] in
        guard let self else { return .forgotten }
        // Lost again while this attempt was still settling in: `lostTouch` found this
        // loop running and left it to go round once more.
        if await self.tryOnce(), self.isConnected { return .connected }
        // Forgotten: nothing to dial until a new pairing starts a loop of its own (#81).
        if self.forgottenByControlPlane { return .forgotten }
        note("link: no answer; waiting before the next try")
        return .failed
    }
    var isLoadingEarlier = false
    /// What the pages on screen show, and what has been read on this connection (#175).
    @ObservationIgnored var parts = OnScreenParts()
    /// The catch-up under way, so a pull to refresh during a reconnect waits for it
    /// rather than starting a second.
    @ObservationIgnored var catchingUp: Task<Void, Never>?
    /// The first page of live agents was full: the rest come a folder at a time, as each
    /// folder's page opens.
    @ObservationIgnored var moreLiveAgents = false
    @ObservationIgnored var filledFolders: Set<URL> = []

    /// The agent's files as the Mac reads them, and where each agent's pane is (034).
    let files: RemoteFiles
    let panes = RemotePanes()
    let pictures: PhonePictures
    /// This device's end of each of an agent's shells it has opened (034), one per
    /// terminal tab (055, #345). The shells are the Mac's; these only know how to reach them.
    @ObservationIgnored var shells: [ShellKey: ShellClient] = [:]
    /// The Agent Browser pane's view of each host's browser (#3800), made once per host.
    @ObservationIgnored var machineBrowsers: [MachineRef: MachineBrowser] = [:]
    /// Shells no screen shows that still hold their emulator, most recent last, so going
    /// back to an agent's terminal finds it as it was instead of rebuilding it and
    /// replaying megabytes on the main thread (#419, as the Mac since #401). A few, not
    /// all: `shells` keeps a client for every shell ever opened, and each emulator holds
    /// a screen's worth of scrollback.
    @ObservationIgnored var parkedScreens: [ShellKey] = []
    static let parkedScreenLimit = 6
    /// When this device last asked to warm each session, and why (#183).
    @ObservationIgnored var prewarmed: [String: Date] = [:]

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

    func folderHostClient(for folder: URL) -> DaemonClient {
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
    @ObservationIgnored let baseLink: any DaemonLink
    /// Every host a control plane has besides the one this phone paired with, each with
    /// a client of its own over one more connection (058, US4). Empty against a bridge
    /// with no control plane.
    @ObservationIgnored var otherHosts: [MachineRef: DaemonClient] = [:]
    @ObservationIgnored var hostWatch: Task<Void, Never>?
    /// The watch's own client of the control plane while it is connected, for the control
    /// plane's own requests (`machines/start`, #691). Nil against a bridge with no control plane.
    @ObservationIgnored var controlPlane: DaemonClient?
    /// The names of the projects the sidebar groups (#3278).
    let projectNames = ProjectNames()
    /// People (#994): the machines waiting for this person's approval, fed from the watch.
    let people = PeopleState()
    /// The GitHub sign-ins waiting for this person's Approve (#995).
    let signIn = SignInState()
    /// This device's place in the person's machine lock, and the clients asking to join it (#3490).
    let lock = LockState(pins: LockPins(defaults: .standard, name: RemoteControl.lockPinName), name: UIDevice.current.name,
                         kind: RemoteControl.kind, account: "lock-signing-key")
    /// What `machines/list` last said, so the folder list can name each host (058, frame H).
    /// Empty when this phone is not a client of a control plane.
    var controlHosts: [DaemonAPI.ControlMachine] = []
    /// Git asks answered on this device, until the control plane's list drops them (#1122).
    var gitAsksAnswered: Set<String> = []
    /// The host this phone's own connection reaches. Its folders are stamped `.mac`.
    var controlHome: MachineRef?
    /// Work's places (#3256), as the window keeps them: the list or the item's page open, and
    /// the ones before and after it, for Back and Forward.
    var workHistory = LineageHistory<WorkPlace>()
    /// Each Work list's filters, sort and rows (#3257), so a page goes through its list and Back finds it as left.
    let workLists = WorkLists()
    /// The person's settings and the names of their secrets (#1760), for Settings ▸ You ▸ Secrets
    /// (#4032), fed from the control plane's watch.
    let userScope = UserScopeState()
    /// What `control/status` last said: its version and capabilities, for Settings (#1748).
    var controlStatus: DaemonAPI.ControlStatus?
    /// Where the control plane runs, for the words said when it can't be reached (#4916):
    /// "your Mac" when it is in Agents on the home Mac, the control plane and its address
    /// when it is not. Kept across launches, so a phone opened while nothing answers still
    /// names the right one.
    var controlPlaneReach = ControlPlaneReach(
        onHomeMac: WindowDefaults.store.object(forKey: RemoteModel.planeOnMacKey) as? Bool ?? true,
        address: ControlPlaneReach.address(of: RemoteControl.membership?.url))
    static let planeOnMacKey = "controlPlaneOnHomeMac"

    init(link: any DaemonLink) {
        baseLink = link
        // Each request to the home host checked end to end once this device is in its lock (#3492),
        // and each line wrapped for it, as every other client's is (#3234).
        let lock = lock
        client = DaemonClient(link: LockedLink(HomeLink(link), host: .mac) { await lock.channelSigner() }, machine: .mac)
        // A secret is sealed only to the machines the lock names (#3491, D8).
        userScope.lock = lock
        files = RemoteFiles(client: client)
        pictures = PhonePictures(files: files)
        // At once, so the list and a chat restored at launch draw before the Mac answers.
        // An unpaired device has none: a forget deletes it.
        let localCopy = LocalCopyKeeper(copy: .remote(), work: work)
        self.localCopy = localCopy
        Task { await localCopy.drawMachines() }
        #if DEBUG
        WalkNotify.model = work
        WalkNotify.also = { [weak self] method, params in
            guard method == DaemonAPI.Notification.moveChanged,
                  let change = try? params?.decode(DaemonAPI.MoveNotification.self) else { return false }
            self?.moveChanged(change)
            return true
        }
        #endif
        // From the start, not once connected: a banner tapped to launch or wake the app
        // arrives before then, and was dropped (#1045).
        notifier.open = { [weak self] agentID, line in
            // A notice's line (#2860): gone to and lit once its chat has settled.
            if let line { self?.focusedEntry = line }
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

    /// Nothing to reach the control plane with: never paired, or forgotten (FR-009).
    var needsPairing: Bool { baseLink is NotPairedLink || forgottenByControlPlane }

    /// The control plane refused this device's key: forgotten, or never known (058, US5).
    var forgottenByControlPlane = false

    /// Where a pairing started from the scanner has got to.
    enum Pairing: Equatable {
        case idle
        case pairing
        case paired
        case failed(String)
    }

    var pairing: Pairing = .idle

    /// Set once this phone has paired with a control plane: the app makes a new model on
    /// that link (058, US5).
    var pairedWithControlPlane = false

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
    var forgotItself = false

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
        forgetKept()
        forgotItself = true
        return nil
    }

    /// The pairing is gone (#3670): what this device kept of that control plane goes with
    /// it. The widget's headlines and the badge, the drafts, the Live Activity's turns, and
    /// every banner delivered from it.
    func forgetKept() {
        StartDraftKeeper.shared.forgetAll()
        // The copy of its sessions and chats goes with the pairing (#4791).
        Task { [localCopy] in await localCopy?.forget() }
        liveActivities.endAll()
        notifier.forgetAll()
        AttentionSnapshotStore.clear()
        // What was shared for New session is not for the next pairing (#4915).
        SharedInbox.clear()
        sharedFor = nil
        lastPublished = nil
        notifier.setBadgeCount(0)
        WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
    }

    /// The workflow whose page is open, if one is. Its id rather than a copy, for the
    /// Mac page's reason: the file is the truth, and a copy would show what it used to
    /// say. Pushed under the conversation, so a run opened from its page comes back to it.
    var openWorkflow: Workflow.ID?

    /// The folder's pinned page (#159) pushed over the folder page, by its path in it.
    var openPin: String?

    /// Which of the folder's archive pages is open (#495, #4448), Archived Sessions or
    /// Archived Workflows, each from its own row in the sidebar; nil when neither is.
    var openArchive: ArchiveKind?

    /// A change waiting for an OK, on its Review page (#1472), by its `Approval.id`: from
    /// Needs You, the detail's own page; from Review… on a chat's card, pushed over the chat.
    var openReview: String?

    /// The session opened while it was unread, kept in the sidebar's Unread until another
    /// is opened (#495), so it does not leave the list under the finger on the tap.
    var keptInUnread: UUID?

    /// Whether `keptInUnread` had a file to see when opened, so For Review keeps it (#3194).
    var keptHadFile = false

    /// A chat's lease line asked for This Mac's resources (#4027): its page scrolls to them
    /// once, then clears this.
    var resourcesAsked = false

    /// One of the pages about all the work, from the sidebar's Activity (#226): Events,
    /// Runtimes or Spending, or a machine's page. Nil, or one of those.
    var openActivity: SidebarItem? {
        didSet {
            if openActivity != nil, selectedKey != nil { selectedKey = nil }
        }
    }

    /// The sidebar's search field (#3898): the model's, so a label's chip in a card or the
    /// chat can ask it for that label.
    var sidebarSearch = ""

    /// The ⌘K command menu (#4792) while it is open: what is typed in it to start with, the
    /// sidebar's search when a phone with no keyboard opens it from there. Nil when shut.
    var commandMenu: String?

    /// What the command menu asked the open chat to do (#4792): the chat does it and clears it.
    var chatAsk: RemoteChatAsk?

    @ObservationIgnored var saidNewSessionFolder: NewSessionFolder?

    var rememberedNewSessionFolder: FolderKey? =
        UserDefaults.standard.string(forKey: RemoteModel.newSessionFolderDefault).flatMap(FolderKey.init(stored:))

    static let newSessionFolderDefault = "newSessionFolder"

    /// The folder last used in each project, by the project's id (#3279).
    var rememberedProjectFolders: [String: String] =
        UserDefaults.standard.dictionary(forKey: RemoteModel.newSessionProjectFoldersDefault) as? [String: String] ?? [:]

    static let newSessionProjectFoldersDefault = "newSessionProjectFolders"

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
    var firstPageSize = defaultPageSize

    /// A phone's, near enough, for the first conversation opened before anything has
    /// been measured. Every one after it uses the real height.
    static let defaultPageSize = 60

    /// About as tall as an entry draws: a line of tool call, a short paragraph, a
    /// state change. Measured by eye rather than computed, and the clamp either side
    /// is what keeps a bad guess from becoming a bad fetch.
    static let entryHeight: CGFloat = 80

    /// Screens' worth to hold: enough to scroll a couple before going back for more.
    static let screensHeld: CGFloat = 3

    /// Somebody asked for the end of the conversation: a prompt went. A counter, so two
    /// asks in a row both land (033, the Mac's own rule).
    var scrollToEndToken = 0

    /// The folder whose New session page (#366) is on screen, if one is: set by the page
    /// while it shows, so the runtime behind its choices is held only then, and cleared
    /// when the agent it started is ready to be looked at. With its host: a folder at the
    /// same path on another machine is another page (#3446).
    var startingIn: FolderKey? {
        didSet {
            guard startingIn != oldValue else { return }
            if let startingIn { queueOpenStart(startingIn) } else { closeStart() }
        }
    }

    /// Counts each time no showing holds the page any more (#2089), for a showing still on
    /// screen to hear it and hold it again.
    var startPageLetGo = 0

    /// The showing of the page that holds `startingIn` (#1044). The detail is rebuilt with
    /// each pick, and the page it replaced can say it went after the new one said it came:
    /// only the showing that holds the page lets it go.
    @ObservationIgnored var startPage = PageHold<FolderKey>()

    /// The showings whose Send started an agent: they are going, and never hold the page again.
    @ObservationIgnored var startedPages: Set<UUID> = []

    /// The showing whose Send is starting an agent.
    @ObservationIgnored var startingPage: UUID?

    var offeredStart: OfferedStart?

    /// The offered worktree's name, chosen once the page's repository has answered: before
    /// then the page has no Worktree row, and opening it puts the place back.
    @ObservationIgnored var offeredWorktree: (folder: FolderKey, choice: WorktreeChoice)?

    /// The folder whose New session is to take what the share sheet left, until its page
    /// takes it.
    var sharedFor: FolderKey?

    /// Counts each time something shared is offered, for a page already on screen to hear.
    var sharedArrivals = 0

    /// The runtime the page will start. Seeded by the kit's rule from the one it was last
    /// left on (#264), as the window's start form and the page's.
    var startRuntimeID: String?

    static let keptStartRuntime = DisplayPreference.startRuntimeID

    /// What that runtime offers, in the order they are drawn.
    var startOptions: [ConfigOption] = []

    /// What has been chosen, by option id. Sent as the start's options.
    var startChosen: [String: JSONValue] = [:] { didSet { persistStartChoices() } }

    var startFolders: [URL] = UserDefaults.standard.stringArray(forKey: "remote.startFolders")?.map { URL(fileURLWithPath: $0) } ?? [] {
        didSet { UserDefaults.standard.set(startFolders.map(\.path), forKey: "remote.startFolders") }
    }

    /// The new agent's own sandbox choice (064). Nil follows its runtime's default.
    var startSandbox: SandboxChoice? { didSet { if isAutoStart { Task { await refreshStartAutoPreview() } } } }

    /// The new agent's values in the shared words (#2658), kept when the runtime changes.
    var startLevels = Levels(model: .balanced, permission: .ask)

    /// The new agent's own answer to permission requests (#2658); nil follows Settings.
    var startClientPermission: ClientPermissionMode?

    /// What Auto would pick now for the page, for "Auto (Claude)".
    var startAutoPreview: AutoPreview?

    /// What the page's attachments need its runtime to take (#3162): Auto's preview picks a
    /// runtime that takes them, as the start does.
    var startAttachmentNeeds: ACP.PromptCapabilities?

    /// Every runtime's cells for the shared words (#2658), as the Mac's host has them. Auto's
    /// own settings are Mac + web (#2923).
    var autoMappings = AutoMappings()

    /// The daily summary's Off / Summary control and its time (#3351), from the Mac's host. Nil
    /// until it has said, or from a host too old to know the method.
    var dailySummarySettings: DailySummarySettings?

    /// The daily summary's saved pages on the Mac's host, newest first (#3721): the Summary row
    /// and page. Empty from a host too old to know `summaries/list`.
    var summaryPages: [SummaryPage] = []

    /// Each runtime's sandbox default, read from the Mac, for "Use runtime default (Off)".
    var sandboxSettings = SandboxSettings()

    /// The Mac-wide permission choice for Cursor, Grok and OpenCode (061).
    var clientPermissions = ClientPermissionSettings()

    /// The organisation's policy as the Mac's host follows it (#998): the red strip on every
    /// page and the composer's reason while the kill switch is on. Nil from an older Mac.
    var policyState: DaemonAPI.PolicyState?

    /// Moves when the Mac's host says a policy layer changed (#2957, `policy/effectiveChanged`):
    /// Settings ▸ Agents ▸ Policy reads the layers again.
    var policyRevision = 0

    /// The person's own pass-through names on the Mac, each marked when the policy refuses it (#998).
    var passThrough = DaemonAPI.PassThroughState()

    var startChoicesState: StartChoicesState = .loading

    /// Why the last Send did not start anything, in one sentence. Shown in the page
    /// rather than as the app's alert.
    var startRefusal: String?

    /// A start sent whose answer never came back. Its request id is reused by every
    /// retry, so the Mac answers with the agent the first one made rather than
    /// starting the work twice.
    var unsettledStart: DaemonAPI.StartRequest?

    /// The host `unsettledStart` was sent to: its `cwd` alone could be a folder on another (#3446).
    @ObservationIgnored var unsettledStartOn: MachineRef = .mac

    var isStarting = false

    /// Where in the folder the new agent works, when not the folder (030).
    /// Decided per agent, so it goes back to the folder each time the page
    /// opens and after every start.
    var startWorktree: WorktreeChoice?

    /// What the page's folder's repository has, for the Worktree row. Not a
    /// repository until the Mac says otherwise, which keeps the row hidden.
    var startWorktrees: DaemonAPI.WorktreesListResponse = .notARepository

    var startDraftID: UUID?

    /// The host `startDraftID` was made on: the page's folder's (#240).
    var startDraftHost: MachineRef = .mac

    /// Bumped by every fetch of a runtime's choices, so an answer for a runtime the
    /// person has since moved off is recognised as that and let go.
    var startGeneration = 0

    /// The kinds of session the page's folder offers (#760), the folder's and the
    /// home's as its host lists them, and the one picked, by id.
    var startPersonas: [Persona] = []

    var startPersona: String?

    /// Picked while its runtime's choices were still to come: laid over them on arrival.
    var pendingStartPersona: Persona?

    /// What the page reads: the runtimes to choose from, and, for its runtime menu, what
    /// the Mac's allowances say, before it is opened rather than after whoever happens to
    /// visit the Runtimes page.
    static let startParts: Set<CatchUpPart> = [.runtimes, .allowances, .modes, .sandbox]

    /// Counts the page's opens, so only the last asks for its choices.
    @ObservationIgnored var startOpens = 0

    /// The host the open page asked for runtimes, as it knew the folder then.
    @ObservationIgnored var startOpenedOn: MachineRef?

    /// Set once the open page has picked its runtime, so a list that changes after that
    /// picks again rather than racing the opening.
    @ObservationIgnored var startPicked = false

    /// What the page has been answered since it opened (#1096).
    @ObservationIgnored var startAsks = StartPageAsks()

    /// What each runtime offered the page last time, on each host (#1171): the page is
    /// drawn from it at once and put right by the draft's answer.
    @ObservationIgnored var startMemory = StartChoicesMemory()

    /// When the page opened, until its rows are drawn: said in the log as how long that took.
    @ObservationIgnored var startOpenedAt: ContinuousClock.Instant?

    /// Put the page away. Its runtime is let go; what was typed is the keeper's.
    @ObservationIgnored var startShowsParts = false

    /// Every runtime the Mac knows, in the Mac's order, startable or not. The start
    /// page lists the ones that cannot start too, with why, because a runtime that
    /// silently is not there reads as one the phone forgot.
    var runtimes: [RuntimeStatus] = [] { didSet { startRuntimesMoved() } }

    var accounts: [String: RuntimeAccount] = [:]

    /// The accounts of the Mac's runtimes (#840), beside each runtime's own sign-in, the
    /// organisation's included (#999).
    var accountProfiles: [AccountProfile] = [] {
        didSet { accountProfilesRead = true }
    }

    /// Whether the Mac has listed them yet: until then no session is told its account is gone.
    var accountProfilesRead = false

    /// The account the start page uses (#840, #999), as `AccountChoices` keeps a choice: nil
    /// for the runtime's account for new sessions.
    var startAccountID: String?

    /// Each other host's runtimes, as it last listed them (#240): a server folder's
    /// start page offers its server's, as the window's does (037).
    var serverRuntimes: [MachineRef: [RuntimeStatus]] = [:] { didSet { startRuntimesMoved() } }

    /// Why a host's last `runtimes/list` failed, until one is answered (#977): the start
    /// page says that, rather than "None set up".
    var runtimesFailure: [MachineRef: String] = [:] { didSet { startRuntimesMoved() } }

    /// A file being read, by path, or nothing.
    ///
    /// On the model rather than in a view's `@State` because the tap that opens one is
    /// a tool call's file name, several views down inside the transcript, and passing a
    /// binding through every row to reach it would be a worse thing than this.
    var fileOnScreen: String?

    /// What the agent touched in the part of its conversation before the page loaded,
    /// per agent. Fetched once, when Files first opens for it.
    var touchedEarlier: [UUID: TouchedPaths] = [:]

    var touchedHistoryAsked: Set<UUID> = []

    /// Something is being typed on this device: the prompt, a passage on a page, the
    /// terminal. While it is, an agent asking to be looked at is offered, not opened,
    /// so the screen is not taken from under somebody's fingers (034 FR-005).
    var isTyping = false

    /// The control plane's address itself refused the connection (suspended, over a
    /// plan's limit, #2235): its words, shown in the stale banner in place of "last
    /// heard from your Mac".
    var controlPlaneRefusalLine: String?

    /// How long the loop waits before the next attempt, and the wait itself, which coming
    /// back to the app or a network change cuts short (#82); and the other hosts' watch's.
    @ObservationIgnored let backoff = Backoff()

    @ObservationIgnored let otherHostsBackoff = Backoff(first: .seconds(5), longest: .seconds(60))

    @ObservationIgnored var checkingConnection = false

    @ObservationIgnored lazy var networkChanges = ReconnectTriggers { [weak self] reason in
        Task { @MainActor in await self?.goBackNow(reason) }
    }

    /// Whether a refusal is believed yet (#81).
    @ObservationIgnored var refusals = RefusalPatience()

    /// How long each call that catches up after connecting is given.
    static let catchUpPatience = Duration.seconds(20)

    /// The other hosts this phone has a live connection to now (058, #208): an agent on
    /// one that is not is stale on its own, whatever the home host is doing.
    var reachableHosts: Set<MachineRef> = [] {
        didSet {
            for host in oldValue.subtracting(reachableHosts) where hostDownSince[host] == nil {
                hostDownSince[host] = Date()
            }
            for host in reachableHosts.subtracting(oldValue) { hostDownSince[host] = nil }
        }
    }

    /// The hosts whose `machines/start` is out now, so the strip's Start waits for it (#691).
    var hostsBeingStarted: Set<MachineRef> = []

    /// Prompts and starts the control plane keeps for stopped workspaces (#691 US3), every host's.
    var kept: [DaemonAPI.KeptRequest] = []

    /// The kept starts the start page has shown here: the one that reaches its host opens.
    @ObservationIgnored var keptStartsShown: Set<UUID> = []

    /// Each other machine's disks, as it last said them (#3628), for its row's red and its page.
    var serverDisks: [MachineRef: DiskState] = [:]

    /// Every machine provider this person may use: the Machines group shows each one's
    /// machines that have not joined (#4978, as the window's).
    var listedProviders: [DaemonAPI.ProviderSummary] = []

    /// How each tap on a machine that never joined goes (#4978), by its row's id.
    var machineJoins: [String: MachineJoin] = [:]

    /// The New Machine sheet (#4634), or nil while it is shut. A make the provider refused
    /// opens it again on its choices, with the reason.
    var newMachineAsk: NewMachineAsk?

    /// How many New Machine calls wait for the provider's answer (#4612, as the window's #4610):
    /// a *Making…* row each, until the control plane lists the machine as joining.
    var machinesBeingMade = 0

    /// When each other host was last seen to go, for the strip over its chats (#239):
    /// set as it leaves `reachableHosts`, cleared as it comes back.
    var hostDownSince: [MachineRef: Date] = [:]

    @ObservationIgnored var labelsReloading: Set<URL> = []

    @ObservationIgnored var runtimesReloading = false

    /// The banners, in the order the Mac said: each waits for the one before.
    @ObservationIgnored var notifierTail: Task<Void, Never>?

    @ObservationIgnored var attentionPublishing: Task<Void, Never>?

    /// How long a send waits for the Mac to come back, and between its pings while it
    /// waits for an answer (#208).
    static let sendPatience = catchUpPatience

    /// The scenes in front (#888): the main one, and any session's own.
    @ObservationIgnored var scenesActive: Set<UUID> = []

    @ObservationIgnored var hasHeardAPhase = false

    /// This device's APNs token (#1460), as the system gave it.
    @ObservationIgnored var pushToken: Data?

    /// The background refresh's name, as `BGTaskSchedulerPermittedIdentifiers` lists it.
    nonisolated static let widgetRefreshTask = "com.alexecollins.agents.remote.widget-refresh"

    var pendingOpen: UUID?

    var pendingNeed: String?

    /// What was last written for the widget, so the file is not read back each time.
    @ObservationIgnored var lastPublished: AttentionSnapshot?

    /// The notifications that can move the number. The Mac sends a great deal more than
    /// this — a shell printing, a file changing, a runtime's status — and a widget does
    /// not redraw for any of those.
    static let attentionNotifications: Set<String> = [
        DaemonAPI.Notification.attentionChanged,
        DaemonAPI.Notification.requestsChanged,
    ]

    /// The newest `limit` archived agents in a folder, for its Archived section when
    /// it is opened. Without their slash commands: an archived chat has no prompt bar
    /// here to use them.
    /// The folders whose Archived fold is open in the sidebar (#226): each holds a page
    /// of its archived sessions while it is, as on the Mac (#165).
    var openArchivedFolds: Set<URL> = []

    /// The most a search brings back from each host, a page at a time: the sidebar holds
    /// the live sessions and filters those itself (#165, #176).
    static let searchShown = 200

    /// Archived sessions a search brought in, let go when the search ends.
    var searched: Set<UUID> = []

    /// The next page of matches, for each host whose last page was full (#176).
    var searchNext: [MachineRef: DaemonAPI.ListRequest] = [:]

    /// The folder whose Project Settings page is open (#2798 reversed for Work at Once,
    /// Sessions and Policy), asked at the root as Move to Machine… is: the menu is gone by now.
    var projectSettingsFolder: FolderKey?

    /// The mode last chosen for each runtime, on any device. `modes/changed` keeps it
    /// current afterwards. A Mac too old to know the method leaves the sheet opening
    /// on each runtime's own current mode.
    /// The person's display choices (#1033), kept on the Mac. This device's defaults mirror
    /// them, so every view reads them where it always did.
    /// A change shows at once; one the Mac did not take goes back, and says so (#4814).
    @ObservationIgnored lazy var displayMirror = makeDisplayMirror()

    /// What a host says about its browser (#3800): for the agent browser's take-over window alone (#4141).
    nonisolated static let browserNotifications: Set<String> = [
        DaemonAPI.Notification.browserFrame, DaemonAPI.Notification.browserPageChanged,
    ]

    /// How long a banner's answer waits for the link: inside the half minute iOS gives an
    /// app woken for a notification's button.
    static let bannerPatience: Duration = .seconds(20)

    /// The last Archive, while Undo is offered for it (#1534).
    var archiveUndo: ArchiveUndo?

    /// The last Unarchive, Rename, label change, Mute or Later, while Undo is offered for it
    /// (#4793). One toast at a time: it and Archive's replace each other.
    var sessionUndo: SessionUndo?

    /// The session a menu's Move to Machine… is moving (#4037), asked at the root as Rename… is.
    var movingToMachine: Agent?

    /// The server runtime being signed in (#4035), asked at the root (#5203): the sheet stays
    /// while the person goes to other pages, and the page under it works.
    var signingIn: RuntimeSignInTarget?

    /// Moves to another machine under way, by session, and those that stopped with a problem
    /// until they are put away (#4641): a line on the session's card, as on the Mac's row.
    var moves: [UUID: DaemonAPI.MoveNotification] = [:]

    /// Where a session this phone moved goes on, so a chat open on it follows it there once
    /// that machine has it (#4641).
    var moveFollows: [UUID: FolderKey] = [:]

    /// The archived session a menu's Delete… is asking about, until it is answered (#398).
    var askingToDelete: Agent?

    /// The session a menu's Rename… is asking a title for, until it is answered (#751),
    /// and what has been typed.
    var renaming: Agent?

    var renameText = ""
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

/// Work (#3256): `RemoteModel+Work.swift`. Declared here, as Sendable conformance must be.
extension RemoteModel: WorkModel {}

/// Settings ▸ You ▸ Secrets ▸ For One Session (#4032), through the Mac's host.
extension RemoteModel: LocalSecretsSource {}

/// Which of a folder's two archive pages (#4448): its archived sessions or its archived workflows.
enum ArchiveKind: Hashable {
    case sessions
    case workflows
}
