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
    /// The work, as any client sees it: the agents, the projects, the questions
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
    /// What each runtime last said about itself: signed in or not, what it takes in a
    /// prompt, which provider is answering.
    private(set) var accounts: [String: RuntimeAccount] = [:]
    /// What the terminals the daemon is running for an agent have printed so far.
    private(set) var terminalOutput: [String: String] = [:]
    private(set) var isConnected = false
    private(set) var problem: String?

    // What the window reads, which is the shared model under another name. Forwarded
    // rather than mirrored: a copy is a thing that can fall behind.
    var agents: [Agent] { work.agents }
    var projects: [DaemonAPI.ProjectSummary] { work.projects }
    var permissions: [PermissionRequest] { work.permissions }
    var elicitations: [ElicitationRequest] { work.elicitations }
    var entries: [TranscriptEntry] { work.entries }
    var transcriptHasMore: Bool { work.hasMoreBefore }
    var filesToShow: [UUID: ShownFile] { work.filesToShow }

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
            // Which conversation is being read is what decides whether an arriving
            // transcript entry is ours to keep, so the shared model is told first.
            work.watching = selection
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

    /// The panes listening for shell output, one per agent in this window. Shell
    /// notifications are broadcast to every window, so each one keeps only the agents
    /// it is actually showing and ignores the rest.
    @ObservationIgnored private var shellClients: [UUID: ShellClient] = [:]

    /// What each agent had already spent when this window first laid eyes on it.
    ///
    /// An agent's `costToDate` is its whole life, and agents outlive the window, so
    /// adding them up would be an all-time figure wearing the word "session". Taking
    /// away what was spent before we were watching leaves what this sitting cost.
    @ObservationIgnored private var spentBeforeWeWatched: [UUID: [String: Decimal]] = [:]

    /// What this sitting has cost, per currency. Empty until something has been spent,
    /// which is how the sidebar knows to show nothing rather than a zero.
    var sessionCost: [String: Decimal] {
        Cost.spent(by: agents, since: spentBeforeWeWatched)
    }

    /// Take a note of what every agent we have not seen before had already spent.
    ///
    /// Swept after anything files an agent, rather than hooked into the filing itself:
    /// it is idempotent, there are tens of agents rather than thousands, and the
    /// alternative is a callback threaded through the shared model for the benefit of
    /// one line in one window.
    private func noteWhatWasAlreadySpent() {
        for agent in work.agents where spentBeforeWeWatched[agent.id] == nil {
            spentBeforeWeWatched[agent.id] = agent.costToDate
        }
    }

    var selectedAgent: Agent? { work.agent(selection) }

    var permissionForSelection: PermissionRequest? { work.permission(for: selection) }

    var availableRuntimes: [RuntimeStatus] {
        runtimes.filter { $0.availability.isAvailable }
    }

    // MARK: Projects

    /// The ones the sidebar lists.
    var liveProjects: [DaemonAPI.ProjectSummary] { work.liveProjects }

    var archivedProjects: [DaemonAPI.ProjectSummary] { work.archivedProjects }

    var selectedProjectSummary: DaemonAPI.ProjectSummary? { work.project(selectedProject) }

    /// A project's agents in one group, newest first.
    func agents(in folder: URL?, group: AgentGroup) -> [Agent] {
        work.agents(in: folder, group: group)
    }

    func refreshProjects() async {
        do {
            work.replaceProjects(try await client.call(DaemonAPI.Method.projectsList,
                                                       DaemonAPI.ProjectsListRequest(),
                                                       returning: [DaemonAPI.ProjectSummary].self))
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
        work.upsert(summary)
        // The one thing filing a project means to a window and to nothing else: the
        // project being read may have just been archived, or may have just arrived.
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
        // What every notification about the work means is written once, in the kit,
        // so the window and the phone cannot drift apart. What is left here is the
        // Mac's own: the shells and terminals a phone has no business with.
        if work.apply(method, params) {
            noteWhatWasAlreadySpent()
            if method == DaemonAPI.Notification.projectChanged { settleProjectSelection() }
            return
        }

        switch method {
        case DaemonAPI.Notification.shellOutput:
            guard let notification = try? params?.decode(DaemonAPI.ShellOutputNotification.self) else { return }
            shellClients[notification.agentID]?.received(notification.bytes)

        case DaemonAPI.Notification.shellStateChanged:
            guard let notification = try? params?.decode(DaemonAPI.ShellStateNotification.self) else { return }
            shellClients[notification.agentID]?.received(notification.state)

        case DaemonAPI.Notification.draftOptions:
            guard let notification = try? params?.decode(DaemonAPI.DraftOptionsNotification.self) else { return }
            settleDraft(notification)

        case DaemonAPI.Notification.runtimeChanged:
            await refreshRuntimes()

        case DaemonAPI.Notification.runtimeAccountChanged:
            guard let account = try? params?.decode(RuntimeAccount.self) else { return }
            accounts[account.runtimeID] = account

        case DaemonAPI.Notification.agentTerminalOutput:
            guard let notification = try? params?.decode(DaemonAPI.TerminalOutputNotification.self) else { return }
            terminalOutput[notification.terminalID, default: ""] += notification.chunk

        default:
            break
        }
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
        work.replaceElicitations(list)
    }

    /// The form waiting for this agent, if there is one. Held by the daemon, so it is
    /// here whether or not this window was open when it was asked.
    var elicitationForSelection: ElicitationRequest? { work.elicitation(for: selection) }

    func refreshAgents() async {
        await attempt {
            let listed = try await self.client.call(DaemonAPI.Method.agentsList,
                                                    DaemonAPI.ListRequest(),
                                                    returning: [Agent].self)
            self.work.replaceAgents(listed)
            // Whatever the list already shows was spent before this window opened, so
            // the session total starts from here rather than from the beginning of time.
            self.noteWhatWasAlreadySpent()
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
            self.work.replacePermissions(
                try await self.client.call(DaemonAPI.Method.permissionsPending,
                                           Optional<String>.none,
                                           returning: [PermissionRequest].self))
        }
    }

    func loadTranscript() async {
        guard let selection else { work.clearTranscript(); return }
        await attempt {
            self.work.replaceTranscript(
                with: try await self.client.call(DaemonAPI.Method.agentsTranscript,
                                                 DaemonAPI.TranscriptRequest(agentID: selection),
                                                 returning: TranscriptPage.self))
        }
    }

    /// The window only ever asks for a page. A transcript that has been going for hours
    /// is not something to load whole.
    func loadEarlier() async {
        guard let selection, work.hasMoreBefore else { return }
        await attempt {
            self.work.prepend(
                try await self.client.call(
                    DaemonAPI.Method.agentsTranscript,
                    DaemonAPI.TranscriptRequest(agentID: selection, before: self.work.firstEntryIndex),
                    returning: TranscriptPage.self))
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
            show(options: response.options, commands: response.commands)
        } catch {
            problem = describe(error)
        }
    }

    /// Draw the form. The first answer may be what the runtime said last time, with the
    /// real one arriving a few seconds later, so this runs more than once for one draft
    /// and keeps every choice the runtime still offers.
    private func show(options: [ConfigOption], commands: [SlashCommand]) {
        draftOptions = options.filter(\.isRenderable).sorted { $0.categoryRank < $1.categoryRank }
        draftCommands = commands
        for option in draftOptions {
            // A choice the user made stands, as long as it is still one of the choices.
            if let chosen = draftChosen[option.id],
               option.isBoolean || option.options?.contains(where: { $0.value == chosen }) == true {
                continue
            }
            draftChosen[option.id] = option.currentValue
        }
        // Options that have gone are not choices anybody can unmake.
        let offered = Set(draftOptions.map(\.id))
        draftChosen = draftChosen.filter { offered.contains($0.key) }
    }

    /// The runtime behind a remembered form has finished starting and either says
    /// something different or will not start at all.
    private func settleDraft(_ notification: DaemonAPI.DraftOptionsNotification) {
        guard notification.draftID == draftID else { return }
        if let failure = notification.failure {
            problem = failure
            // There is no session to start from. The next attempt makes its own, and
            // fails the same way with the prompt still in the bar.
            draftID = nil
            return
        }
        show(options: notification.options, commands: notification.commands)
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
            _ = try await client.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            draftID = nil
            await refreshAgents()
            await refreshProjects()
            // Deliberately not selected. Saying what you want done is not the same as
            // asking to watch it: the agent appears in the project's list and you stay
            // where you were, free to say the next thing. Starting three pieces of work
            // in a row should not mean coming back twice.
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

    /// What this agent last asked the user to look at, taken rather than read: a file
    /// that has been put in front of somebody is not still waiting to be.
    func takeFileToShow(for agentID: UUID) -> ShownFile? {
        work.takeFileToShow(for: agentID)
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
            case .socketPathTooLong(let path):
                // Only ever seen by somebody who passed `--root`, and the fix is in
                // their hands: a shorter path.
                return "That folder is too deep to run a daemon in: \(path) is past the 104 bytes a socket may be named with."
            }
        }
        return String(describing: error)
    }
}
