import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Share ▸ Agent Loops (#4915)

    /// What the share extension left in the app group, if anything, offered to New session in
    /// the folder last used there (`newSessionFolder`), which the person can change with the
    /// folder chip before Send. Asked when the Remote comes to the front, when the extension
    /// opens `agents://start`, and when a machine lists its folders: until then there is no
    /// folder to offer it in, and it waits in the app group.
    func lookForShared() {
        guard SharedInbox.hasItems(), !isStarting, let key = newSessionFolder else { return }
        note("share: offered to New session in \(key.folder.lastPathComponent)")
        sharedFor = key
        sharedArrivals += 1
        sidebarItem = .folder(key)
    }

    /// What was shared, for the page in `folder`, taken once. Read from the app group now, so
    /// a share that landed since it was offered comes too.
    func takeShared(in folder: FolderKey) -> SharedItems? {
        guard sharedFor == folder else { return nil }
        sharedFor = nil
        return SharedInbox.take()
    }

    /// The offer for the page in `folder`, taken once.
    func takeOfferedStart(in folder: FolderKey) -> AppViewStart? {
        guard let offered = offeredStart, offered.folder == folder else { return nil }
        offeredStart = nil
        return offered.start
    }

    enum StartChoicesState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// The choices follow the person to every client (#1033), kept on the Mac.
    func persistStartChoices() {
        guard !startChosen.isEmpty, let startRuntimeID else { return }
        var choices = displayMirror.preferences[DisplayPreference.startChoices]?.objectValue ?? [:]
        guard choices[startRuntimeID] != .object(startChosen) else { return }
        choices[startRuntimeID] = .object(startChosen)
        displayMirror.set([DisplayPreference.startChoices: .object(choices)])
    }

    /// The page's attachments moved: on Auto, ask again what it would pick.
    func startAttachmentsChanged(_ attachments: [Attachment]) {
        let needs = Attachment.needs(attachments)
        guard needs != startAttachmentNeeds else { return }
        startAttachmentNeeds = needs
        if isAutoStart { Task { await refreshStartAutoPreview() } }
    }

    var isAutoStart: Bool { startRuntimeID == LevelWords.autoID }

    /// The machine that keeps your layer of the policy: the Mac's own host.
    var policyHost: DaemonClient { client }

    var startRuntime: RuntimeStatus? { startRuntimes.first { $0.runtime.id == startRuntimeID } }

    /// What the page offers: the runtimes of the folder's own host, the Mac's or a
    /// server's, as the window lists them (#240).
    var startRuntimes: [RuntimeStatus] { runtimes(on: startHost) }

    var startAvailableRuntimeIDs: [String] {
        let ids = startRuntimes.filter(\.canStart).map(\.runtime.id)
        // Auto is a choice wherever a runtime is (#2658).
        return ids.isEmpty ? ids : [LevelWords.autoID] + ids
    }

    /// Opens the page, numbered as it is queued: an open queued before a later one is let go.
    func queueOpenStart(_ folder: FolderKey) {
        startOpens += 1
        let open = startOpens
        Task { await openStart(in: folder, open: open) }
    }

    func openStart(in folder: FolderKey, open: Int) async {
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
            note("start: open of \(folder.folder.lastPathComponent) gave way to \(startingIn?.folder.lastPathComponent ?? "nothing")")
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

    /// The folder list came after the page opened (#2089): a page that took the Mac's
    /// runtimes for a server's folder opens again on its own host's.
    func startHostMoved() {
        guard let folder = startingIn, let opened = startOpenedOn, opened != startHost, !isStarting else { return }
        note("start: \(folder.folder.lastPathComponent) is on \(hostName(startHost)), not \(hostName(opened)); opened again")
        closeStart()
        queueOpenStart(folder)
    }

    /// The runtime this page is on while it can start; when it first opens, use the most
    /// recently active runtime on this folder's host, then the kept choice (#264).
    var pickedStartRuntime: String? {
        RuntimeCatalog.startFormRuntime(current: startRuntimeID,
                                        lastUsed: work.lastRuntimes[startHost],
                                        kept: UserDefaults.standard.string(forKey: Self.keptStartRuntime),
                                        available: startAvailableRuntimeIDs)
    }

    /// The page's host listed its runtimes, or could not (#977). A page that opened before
    /// they came (during a reconnect, or just after launch) picks one now and asks it for its
    /// choices, rather than staying on "None set up" until it is closed and opened again.
    func startRuntimesMoved() {
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
    func reopenStartChoices() async {
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

    /// One of the page's own calls (#1096): with a deadline, failed at once when the link
    /// drops under it, and said in the log with how long it took, so a page that stays on
    /// "Asking…" can be read from it.
    func askForStart<T: Decodable>(_ method: String, _ params: some Encodable & Sendable,
                                           returning: T.Type) async throws -> T {
        let began = ContinuousClock.now
        note("start: \(method) sent")
        do {
            // Decoded here: the type's conformance may be this actor's own.
            let answer = try await client(for: params, on: startHost).callWithin(StartPageAsks.patience(for: method), method, params,
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

    func closeStart() {
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
    func loadStartWorktrees(in folder: FolderKey) async {
        let request = DaemonAPI.WorktreesListRequest(folder: folder.folder)
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
    func loadStartPersonas(in folder: FolderKey) async {
        let request = DaemonAPI.PersonasListRequest(folder: folder.folder)
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
    var startOptionsFolder: URL? {
        if case .existing(let root) = startWorktree { return root }
        return startingIn?.folder
    }

    /// Choose where the new agent works, and make the draft there if that moved it.
    func chooseWorktree(_ choice: WorktreeChoice?) async {
        let before = startOptionsFolder
        startWorktree = choice
        startRefusal = nil
        if startOptionsFolder != before { await loadStartChoices() }
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

    func chooseRuntime(_ runtimeID: String) async {
        guard runtimeID != startRuntimeID else { return }
        startRuntimeID = runtimeID
        UserDefaults.standard.set(runtimeID, forKey: Self.keptStartRuntime)
        startAccountID = nil
        startSandbox = nil
        startRefusal = nil
        await loadStartChoices()
    }

    /// A value chosen on the page (#2658): kept for the next runtime too, and on a named
    /// one put into its own options at once.
    func chooseStartLevel(_ field: AutoField, _ level: String) {
        switch field {
        case .model: startLevels.model = ModelLevel(rawValue: level)
        case .permission: startLevels.permission = PermissionLevel(rawValue: level)
        case .permissionRequests: startClientPermission = ClientPermissionMode(rawValue: level)
        case .sandbox: startSandbox = SandboxChoice(rawValue: level)
        }
        if field == .model || field == .permission {
            // Kept for the next session, on every client (#3798).
            let change = DisplayPreference.keeping(startLevels, in: displayMirror.preferences)
            if !change.isEmpty { displayMirror.set(change) }
        }
        if isAutoStart {
            Task { await refreshStartAutoPreview() }
        } else {
            applyStartLevel(field)
        }
    }

    func applyStartLevel(_ field: AutoField) {
        guard let runtimeID = startRuntimeID, !isAutoStart else { return }
        let level: String? = switch field {
        case .model: startLevels.model?.rawValue
        case .permission: startLevels.permission?.rawValue
        default: nil
        }
        guard let level, let cell = autoMappings.cell(runtimeID, field, level),
              cell.mark != .notPossible, cell.mark != .dropped else { return }
        let offered = Set(startOptions.map(\.id))
        for (id, value) in cell.native?.options ?? [:] where offered.contains(id) {
            startChosen[id] = value
        }
    }

    /// The value of a field the page's own options are now, or nil (Custom).
    func startLevel(_ field: AutoField) -> String? {
        if isAutoStart {
            return field == .model ? startLevels.model?.rawValue : startLevels.permission?.rawValue
        }
        guard let runtimeID = startRuntimeID else { return nil }
        let chosen = field == .model ? startLevels.model?.rawValue : startLevels.permission?.rawValue
        return LevelMatch.level(field, runtimeID: runtimeID, mappings: autoMappings, preferring: chosen) { id in
            self.startChosen[id] ?? self.startOptions.first { $0.id == id }?.currentValue
        }
    }

    /// What Auto would pick now, on the page's machine.
    func refreshStartAutoPreview() async {
        guard isAutoStart, let folder = startOptionsFolder else { startAutoPreview = nil; return }
        let request = AutoPreviewRequest(cwd: folder, levels: startLevels, sandbox: startSandbox, needs: startAttachmentNeeds)
        startAutoPreview = try? await askForStart(DaemonAPI.Method.autoPreview, request, returning: AutoPreview.self)
    }

    func refreshDailySummarySettings() async {
        dailySummarySettings = try? await client.call(DaemonAPI.Method.dailySummarySettings, DaemonAPI.Empty(),
                                                      returning: DailySummarySettings.self)
    }
}
