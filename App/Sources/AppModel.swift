import AgentsKit
import Foundation
import Observation

/// The window's state, which is a view of the daemon's and never a copy of it.
///
/// Everything here either came from the daemon or is on its way to it. Nothing about an
/// agent is decided in this process, which is what makes two windows agree and makes
/// reconnecting after a crash the same three steps as opening for the first time:
/// connect, list, subscribe.
@MainActor
@Observable
final class AppModel {
    private(set) var agents: [Agent] = []
    private(set) var runtimes: [RuntimeStatus] = []
    private(set) var permissions: [PermissionRequest] = []
    /// What each runtime last said about itself: signed in or not, what it takes in a
    /// prompt, which provider is answering.
    private(set) var accounts: [String: RuntimeAccount] = [:]
    /// Outstanding forms, held by the daemon and answerable from any window.
    private(set) var elicitations: [ElicitationRequest] = []
    /// What the terminals the daemon is running for an agent have printed so far.
    private(set) var terminalOutput: [String: String] = [:]
    private(set) var entries: [TranscriptEntry] = []
    private(set) var transcriptHasMore = false
    private(set) var isConnected = false
    private(set) var problem: String?

    /// The folders the work happens in. Worked out by the daemon, so two windows agree
    /// about which projects exist and which of them want the user.
    private(set) var projects: [DaemonAPI.ProjectSummary] = []

    /// Which project this window is looking at.
    ///
    /// Kept here and in `UserDefaults` rather than in the daemon: the daemon owns what
    /// is true about the work, and which of it somebody happens to be reading is not
    /// that. It is also what keeps two windows independent.
    var selectedProject: URL? {
        didSet {
            guard selectedProject != oldValue else { return }
            UserDefaults.standard.set(selectedProject?.path, forKey: Self.selectedProjectKey)
            // Picking a project shows the project, not a conversation. A chat is
            // something you go into from here, and come back out of.
            selection = nil
        }
    }

    static let selectedProjectKey = "selectedProjectFolder"

    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            entries = []
            Task { await loadTranscript() }
        }
    }

    // What the prompt bar is holding before there is an agent to hold it. It lives
    // here rather than in the view so that starting an agent does not throw it away
    // half way through the bar moving down the pane.
    var draftCwd: URL?
    var draftRuntimeID: String?
    private(set) var draftOptions: [ConfigOption] = []
    private(set) var draftCommands: [SlashCommand] = []
    var draftChosen: [String: JSONValue] = [:]
    /// Folders beyond the working one, and MCP servers, for the agent about to start.
    var draftFolders: [URL] = []
    var draftServers: [MCPServer] = []
    private(set) var isLoadingDraftOptions = false
    private var draftID: UUID?

    private let client = DaemonClient()
    private var listening: Task<Void, Never>?
    private var firstTranscriptIndex = 0

    /// The panes listening for shell output, one per agent in this window. Shell
    /// notifications are broadcast to every window, so each one keeps only the agents
    /// it is actually showing and ignores the rest.
    @ObservationIgnored private var shellClients: [UUID: ShellClient] = [:]

    var selectedAgent: Agent? {
        guard let selection else { return nil }
        return agents.first { $0.id == selection }
    }

    var permissionForSelection: PermissionRequest? {
        guard let selection else { return nil }
        return permissions.first { $0.agentID == selection }
    }

    var availableRuntimes: [RuntimeStatus] {
        runtimes.filter { $0.availability.isAvailable }
    }

    // MARK: Projects

    /// The ones the sidebar lists.
    var liveProjects: [DaemonAPI.ProjectSummary] {
        projects.filter { !$0.project.isArchived }
    }

    var archivedProjects: [DaemonAPI.ProjectSummary] {
        projects.filter { $0.project.isArchived }
    }

    var selectedProjectSummary: DaemonAPI.ProjectSummary? {
        guard let selectedProject else { return nil }
        return projects.first { $0.folder == selectedProject }
    }

    /// A project's agents in one group, newest first.
    ///
    /// Filtered from the agents this window already holds, so no call is made and the
    /// archived list's "show more" is a number in a view rather than a fetch.
    func agents(in folder: URL?, group: AgentGroup) -> [Agent] {
        guard let folder else { return [] }
        return agents
            .filter { Project.standardize($0.cwd) == folder && $0.group == group }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func refreshProjects() async {
        do {
            projects = try await client.call(DaemonAPI.Method.projectsList,
                                             DaemonAPI.ProjectsListRequest(),
                                             returning: [DaemonAPI.ProjectSummary].self)
            settleProjectSelection()
        } catch {
            // A list that failed is not worth an alert: the notification that follows
            // the next change will bring it back.
        }
    }

    /// Pick a project when there is none, or when the one we had has gone or been
    /// archived. Falls back to the most recently active, which is what the sidebar
    /// puts at the top.
    private func settleProjectSelection() {
        let live = liveProjects
        if let selectedProject, live.contains(where: { $0.folder == selectedProject }) { return }
        let stored = UserDefaults.standard.string(forKey: Self.selectedProjectKey)
            .map { Project.standardize(URL(filePath: $0)) }
        if let stored, live.contains(where: { $0.folder == stored }) {
            selectedProject = stored
        } else {
            selectedProject = live.first?.folder
        }
    }

    func addProject(_ folder: URL) async {
        await callProject(DaemonAPI.Method.projectsAdd, folder) { [weak self] summary in
            self?.selectedProject = summary.folder
        }
    }

    func archiveProject(_ folder: URL) async {
        await callProject(DaemonAPI.Method.projectsArchive, folder)
    }

    func unarchiveProject(_ folder: URL) async {
        await callProject(DaemonAPI.Method.projectsUnarchive, folder) { [weak self] summary in
            self?.selectedProject = summary.folder
        }
    }

    private func callProject(_ method: String, _ folder: URL,
                             then: ((DaemonAPI.ProjectSummary) -> Void)? = nil) async {
        do {
            let summary = try await client.call(method, DaemonAPI.ProjectRequest(folder: folder),
                                                returning: DaemonAPI.ProjectSummary.self)
            upsert(summary)
            then?(summary)
            settleProjectSelection()
        } catch {
            // A refusal here is the daemon naming the agents to stop, which is exactly
            // what the user needs to read.
            problem = describe(error)
        }
    }

    func upsert(_ summary: DaemonAPI.ProjectSummary) {
        if let index = projects.firstIndex(where: { $0.folder == summary.folder }) {
            projects[index] = summary
        } else {
            projects.append(summary)
        }
        projects.sort { $0.lastActivityAt > $1.lastActivityAt }
        settleProjectSelection()
    }

    // MARK: Connecting

    /// The daemon exits when it has nothing in hand and nobody watching, so a window
    /// that has been sitting idle will outlive it. Noticing and going back is ordinary,
    /// not an error worth showing.
    private func lostConnection() async {
        isConnected = false
        listening = nil
        try? await Task.sleep(for: .seconds(1))
        guard !isConnected else { return }
        await connect()
    }

    func connect() async {
        do {
            try await client.connect()
            isConnected = true
            problem = nil
            listen()
            await refreshEverything()
        } catch {
            isConnected = false
            problem = describe(error)
        }
    }

    private func listen() {
        listening?.cancel()
        let notifications = client.notifications()
        listening = Task { [weak self] in
            for await notification in notifications {
                await self?.received(notification.method, notification.params)
            }
            // The daemon went, or the connection did. A list that has quietly stopped
            // being true is worse than an empty one, so the window says so and goes
            // back for another connection, starting the daemon again if it has to.
            await self?.lostConnection()
        }
    }

    private func received(_ method: String, _ params: JSONValue?) async {
        switch method {
        case DaemonAPI.Notification.agentChanged:
            guard let agent = try? params?.decode(Agent.self) else { return }
            upsert(agent)

        case DaemonAPI.Notification.projectChanged:
            guard let summary = try? params?.decode(DaemonAPI.ProjectSummary.self) else { return }
            upsert(summary)

        case DaemonAPI.Notification.agentEntry:
            guard let entry = try? params?.decode(DaemonAPI.EntryNotification.self) else { return }
            if entry.agentID == selection { entries.append(entry.entry) }

        case DaemonAPI.Notification.agentPermission:
            guard let notification = try? params?.decode(DaemonAPI.PermissionNotification.self) else { return }
            permissions.removeAll { $0.agentID == notification.agentID }
            if let request = notification.request { permissions.append(request) }

        case DaemonAPI.Notification.shellOutput:
            guard let notification = try? params?.decode(DaemonAPI.ShellOutputNotification.self) else { return }
            shellClients[notification.agentID]?.received(notification.bytes)

        case DaemonAPI.Notification.shellStateChanged:
            guard let notification = try? params?.decode(DaemonAPI.ShellStateNotification.self) else { return }
            shellClients[notification.agentID]?.received(notification.state)

        case DaemonAPI.Notification.runtimeChanged:
            await refreshRuntimes()

        case DaemonAPI.Notification.runtimeAccountChanged:
            guard let account = try? params?.decode(RuntimeAccount.self) else { return }
            accounts[account.runtimeID] = account

        case DaemonAPI.Notification.agentUsage:
            guard let notification = try? params?.decode(DaemonAPI.UsageNotification.self) else { return }
            if let index = agents.firstIndex(where: { $0.id == notification.agentID }) {
                agents[index].usage = notification.usage
            }

        case DaemonAPI.Notification.agentElicitation:
            guard let notification = try? params?.decode(DaemonAPI.ElicitationNotification.self) else { return }
            elicitations.removeAll { $0.id == notification.requestID }
            if let request = notification.request { elicitations.append(request) }

        case DaemonAPI.Notification.agentTerminalOutput:
            guard let notification = try? params?.decode(DaemonAPI.TerminalOutputNotification.self) else { return }
            terminalOutput[notification.terminalID, default: ""] += notification.chunk

        default:
            break
        }
    }

    private func upsert(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
        } else {
            agents.append(agent)
        }
        agents.sort { $0.lastActivityAt > $1.lastActivityAt }
    }

    // MARK: Asking

    func refreshEverything() async {
        await refreshAgents()
        // After the agents, because a project's counts are worked out from them and a
        // sidebar drawn before them would say every project is empty.
        await refreshProjects()
        await refreshRuntimes()
        await refreshAccounts()
        await refreshPermissions()
        await refreshElicitations()
        await loadTranscript()
    }

    func refreshElicitations() async {
        guard let list = try? await client.call(DaemonAPI.Method.elicitationsPending,
                                                Optional<Int>.none,
                                                returning: [ElicitationRequest].self) else { return }
        elicitations = list
    }

    /// The form waiting for this agent, if there is one. Held by the daemon, so it is
    /// here whether or not this window was open when it was asked.
    var elicitationForSelection: ElicitationRequest? {
        guard let selection else { return nil }
        return elicitations.first { $0.agentID == selection }
    }

    func refreshAgents() async {
        await attempt {
            self.agents = try await self.client.call(DaemonAPI.Method.agentsList,
                                                     DaemonAPI.ListRequest(),
                                                     returning: [Agent].self)
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
        }
    }

    func refreshRuntimes() async {
        await attempt {
            self.runtimes = try await self.client.call(DaemonAPI.Method.runtimesList,
                                                       Optional<String>.none,
                                                       returning: [RuntimeStatus].self)
        }
    }

    func refreshPermissions() async {
        await attempt {
            self.permissions = try await self.client.call(DaemonAPI.Method.permissionsPending,
                                                          Optional<String>.none,
                                                          returning: [PermissionRequest].self)
        }
    }

    func loadTranscript() async {
        guard let selection else { entries = []; return }
        await attempt {
            let page = try await self.client.call(DaemonAPI.Method.agentsTranscript,
                                                  DaemonAPI.TranscriptRequest(agentID: selection),
                                                  returning: TranscriptPage.self)
            self.entries = page.entries
            self.firstTranscriptIndex = page.firstIndex
            self.transcriptHasMore = page.hasMoreBefore
        }
    }

    /// The window only ever asks for a page. A transcript that has been going for hours
    /// is not something to load whole.
    func loadEarlier() async {
        guard let selection, transcriptHasMore else { return }
        await attempt {
            let page = try await self.client.call(
                DaemonAPI.Method.agentsTranscript,
                DaemonAPI.TranscriptRequest(agentID: selection, before: self.firstTranscriptIndex),
                returning: TranscriptPage.self)
            self.entries.insert(contentsOf: page.entries, at: 0)
            self.firstTranscriptIndex = page.firstIndex
            self.transcriptHasMore = page.hasMoreBefore
        }
    }

    // MARK: Doing

    /// A session has to exist before its options do, so choosing a folder and a
    /// runtime starts one. It is kept and used by the start that follows.
    func loadDraftOptions() async {
        guard let runtimeID = draftRuntimeID, let cwd = draftCwd else { return }
        isLoadingDraftOptions = true
        draftOptions = []
        draftCommands = []
        draftChosen = [:]
        draftID = nil
        defer { isLoadingDraftOptions = false }
        do {
            let response = try await client.call(DaemonAPI.Method.agentsOptions,
                                                 DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: cwd,
                                                                          mcpServers: draftServers),
                                                 returning: DaemonAPI.OptionsResponse.self)
            draftID = response.draftID
            draftOptions = response.options.filter(\.isRenderable).sorted { $0.categoryRank < $1.categoryRank }
            draftCommands = response.commands
            for option in draftOptions where option.currentValue != nil {
                draftChosen[option.id] = option.currentValue
            }
        } catch {
            problem = describe(error)
        }
    }

    func startDraft(prompt: String, attachments: [Attachment] = []) async {
        guard let runtimeID = draftRuntimeID, let cwd = draftCwd else { return }
        let request = DaemonAPI.StartRequest(runtimeID: runtimeID,
                                             cwd: cwd,
                                             prompt: prompt,
                                             attachments: attachments,
                                             startOptions: StartOptions(values: draftChosen),
                                             draftID: draftID,
                                             additionalDirectories: draftFolders,
                                             mcpServers: draftServers)
        do {
            let id = try await client.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            draftID = nil
            await refreshAgents()
            selection = id
        } catch {
            problem = describe(error)
        }
    }

    /// Sent now if the agent is free, and queued by the daemon if it is not. Either
    /// way this is the same call: whether there is room for it is not the window's
    /// question to answer.
    func send(_ text: String, attachments: [Attachment] = []) async {
        guard let selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await attempt {
            try await self.client.call(DaemonAPI.Method.agentsPrompt,
                                       DaemonAPI.PromptRequest(agentID: selection, text: text,
                                                               attachments: attachments))
        }
    }

    /// Start an agent on this, in this project's folder.
    ///
    /// What the prompt at the top of a project does. There is no separate button for
    /// it because there is nothing else the prompt could mean: you are looking at a
    /// folder and saying what you want done in it.
    func startAgent(in folder: URL, prompt: String) async {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let runtimeID = defaultRuntimeID else { return }
        await attempt {
            let id = try await self.client.call(
                DaemonAPI.Method.agentsStart,
                DaemonAPI.StartRequest(runtimeID: runtimeID, cwd: folder, prompt: words),
                returning: UUID.self)
            self.selection = id
        }
    }

    /// Which runtime a new agent gets when nobody has said.
    ///
    /// Whatever the last agent used, when it is still available, because that is the
    /// one already chosen in every other sense. It can be changed from the chat.
    var defaultRuntimeID: String? {
        let available = Set(availableRuntimes.map(\.runtime.id))
        let recent = agents.sorted { $0.lastActivityAt > $1.lastActivityAt }
            .first { available.contains($0.runtimeID) }?.runtimeID
        return recent ?? available.first
    }

    /// Take something back off the queue before it goes.
    func unqueue(_ prompt: QueuedPrompt, from agentID: UUID) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.agentsUnqueue,
                                       DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id))
        }
    }

    /// What the runtime behind the current agent, or the draft, says it will take.
    /// Nothing is refused on a guess: this is what the runtime advertised.
    var promptCapabilities: ACP.PromptCapabilities {
        let runtimeID = selectedAgent?.runtimeID ?? draftRuntimeID
        return runtimeID.flatMap { accounts[$0]?.promptCapabilities } ?? ACP.PromptCapabilities()
    }

    func refreshAccounts() async {
        guard let list = try? await client.call(DaemonAPI.Method.runtimesAccounts,
                                                Optional<Int>.none,
                                                returning: [RuntimeAccount].self) else { return }
        accounts = Dictionary(uniqueKeysWithValues: list.map { ($0.runtimeID, $0) })
    }

    func stop(_ id: UUID) async {
        await attempt { try await self.client.call(DaemonAPI.Method.agentsStop, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func archive(_ id: UUID) async {
        await attempt { try await self.client.call(DaemonAPI.Method.agentsArchive, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func unarchive(_ id: UUID) async {
        await attempt { try await self.client.call(DaemonAPI.Method.agentsUnarchive, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func answer(_ request: PermissionRequest, optionID: String) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.permissionsAnswer,
                                       DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID))
        }
    }

    func setOption(agentID: UUID, optionID: String, value: JSONValue) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.agentsSetOption,
                                       DaemonAPI.SetOptionRequest(agentID: agentID, optionID: optionID, value: value))
        }
    }

    // MARK: The user's shells

    /// The pane's end of one agent's shell, made once per agent per window.
    func shellClient(for agentID: UUID) -> ShellClient {
        if let existing = shellClients[agentID] { return existing }
        let fresh = ShellClient(agentID: agentID, model: self)
        shellClients[agentID] = fresh
        return fresh
    }

    func attachShell(agentID: UUID, rows: Int, cols: Int) async throws -> DaemonAPI.ShellAttachResponse {
        try await client.call(DaemonAPI.Method.shellAttach,
                              DaemonAPI.ShellAttachRequest(agentID: agentID, rows: rows, cols: cols),
                              returning: DaemonAPI.ShellAttachResponse.self)
    }

    func restartShell(agentID: UUID, rows: Int, cols: Int) async throws -> DaemonAPI.ShellAttachResponse {
        try await client.call(DaemonAPI.Method.shellRestart,
                              DaemonAPI.ShellAttachRequest(agentID: agentID, rows: rows, cols: cols),
                              returning: DaemonAPI.ShellAttachResponse.self)
    }

    /// Detaching never stops anything. A build carries on (FR-026).
    func detachShell(agentID: UUID) async {
        try? await client.call(DaemonAPI.Method.shellDetach, DaemonAPI.AgentRequest(agentID: agentID))
    }

    func sendToShell(agentID: UUID, bytes: Data) async {
        try? await client.call(DaemonAPI.Method.shellInput,
                               DaemonAPI.ShellInputRequest(agentID: agentID, bytes: bytes))
    }

    func resizeShell(agentID: UUID, rows: Int, cols: Int) async {
        try? await client.call(DaemonAPI.Method.shellResize,
                               DaemonAPI.ShellResizeRequest(agentID: agentID, rows: rows, cols: cols))
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

    func focusEntry(_ id: UUID) {
        focusedEntry = id
    }

    func clearFocus() {
        focusedEntry = nil
    }

    // MARK: Runtimes

    func signIn(runtimeID: String, methodID: String) async -> String? {
        do {
            let account = try await client.call(DaemonAPI.Method.runtimeAuthenticate,
                                                DaemonAPI.AuthenticateRequest(runtimeID: runtimeID,
                                                                              methodID: methodID),
                                                returning: RuntimeAccount.self)
            accounts[runtimeID] = account
            await refreshRuntimes()
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
            _ = try await self.client.call(DaemonAPI.Method.runtimeLogOut,
                                           DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                                           returning: [UUID].self)
        }
        await refreshAccounts()
        await refreshAgents()
    }

    func setProvider(runtimeID: String, providerID: String) async {
        await attempt {
            _ = try await self.client.call(DaemonAPI.Method.runtimeSetProvider,
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
            return try await client.call(DaemonAPI.Method.sessionsList,
                                         DaemonAPI.SessionsListRequest(runtimeID: runtimeID, cwd: cwd),
                                         returning: [RuntimeSession].self)
        } catch {
            problem = describe(error)
            return []
        }
    }

    func adopt(runtimeID: String, session: RuntimeSession) async {
        do {
            let id = try await client.call(DaemonAPI.Method.sessionsAdopt,
                                           DaemonAPI.AdoptRequest(runtimeID: runtimeID,
                                                                  sessionID: session.sessionID,
                                                                  cwd: session.cwd),
                                           returning: UUID.self)
            await refreshAgents()
            selection = id
        } catch {
            problem = describe(error)
        }
    }

    func deleteRuntimeSession(runtimeID: String, sessionID: String) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.sessionsDelete,
                                       DaemonAPI.DeleteSessionRequest(runtimeID: runtimeID,
                                                                      sessionID: sessionID,
                                                                      confirmed: true))
        }
    }

    func fork(_ id: UUID) async {
        do {
            let branch = try await client.call(DaemonAPI.Method.agentsFork,
                                               DaemonAPI.AgentRequest(agentID: id),
                                               returning: UUID.self)
            await refreshAgents()
            selection = branch
        } catch {
            problem = describe(error)
        }
    }

    // MARK: Forms

    func answerElicitation(_ request: ElicitationRequest,
                           action: DaemonAPI.AnswerElicitationRequest.Action,
                           content: [String: JSONValue] = [:]) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.elicitationsAnswer,
                                       DaemonAPI.AnswerElicitationRequest(requestID: request.id,
                                                                          action: action,
                                                                          content: content))
        }
        await refreshElicitations()
    }

    func dismissProblem() { problem = nil }

    /// Something the window worked out for itself, said the same way as anything the
    /// daemon says.
    func show(problem: String) { self.problem = problem }

    private func attempt(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            // One retry through a fresh connection: the daemon having gone idle is not
            // something the user should have to know about.
            if !isConnected {
                await connect()
                if isConnected, (try? await work()) != nil { return }
            }
            problem = describe(error)
        }
    }

    /// What a person can read. The daemon's errors are already written for someone
    /// looking at a screen, so they are shown as they are.
    private func describe(_ error: any Error) -> String {
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
            case .noHelper(let lookedIn):
                return "The helper that runs the agents is missing. Looked in \(lookedIn.joined(separator: ", "))."
            case .couldNotStartHelper(let reason):
                return "The helper would not start: \(reason)"
            case .couldNotConnect:
                return "Could not reach the helper that runs the agents."
            }
        }
        return String(describing: error)
    }
}
