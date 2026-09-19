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
            Task { await loadTranscript() }
        }
    }

    private let client: DaemonClient
    private var listening: Task<Void, Never>?
    /// The loop looking for the Mac, so two of them never run at once.
    private var reconnecting: Task<Void, Never>?
    private var isLoadingEarlier = false

    init(link: any DaemonLink) {
        client = DaemonClient(link: link)
    }

    // MARK: What the screens read

    var projects: [DaemonAPI.ProjectSummary] { work.liveProjects }
    var selectedSummary: DaemonAPI.ProjectSummary? { work.project(selectedProject) }
    var selectedAgent: Agent? { work.agent(selection) }
    var entries: [TranscriptEntry] { work.entries }
    var hasMoreBefore: Bool { work.hasMoreBefore }

    func agents(group: AgentGroup) -> [Agent] { work.agents(in: selectedProject, group: group) }

    /// The question the open conversation is blocked on, if it still is.
    var questionForSelection: PermissionRequest? { work.permission(for: selection) }

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
        await loadTranscript()
        settleSelection()
    }

    private func refreshAgents() async {
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList,
                                                  DaemonAPI.ListRequest(),
                                                  returning: [Agent].self) else { return }
        work.replaceAgents(listed)
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
                                                DaemonAPI.TranscriptRequest(agentID: selection),
                                                returning: TranscriptPage.self) else { return }
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
            DaemonAPI.TranscriptRequest(agentID: selection, before: work.firstEntryIndex),
            returning: TranscriptPage.self) else { return }
        work.prepend(page)
    }

    // MARK: Doing something about it

    /// Answer the question the agent is blocked on.
    ///
    /// Refused here and now when the Mac is not answering, rather than accepted and
    /// quietly dropped (FR-033). An answer that cannot be delivered is not an answer.
    func answer(_ request: PermissionRequest, optionID: String) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await client.call(DaemonAPI.Method.permissionsAnswer,
                                  DaemonAPI.AnswerRequest(permissionID: request.id,
                                                          optionID: optionID))
        } catch {
            problem = "That question could not be answered."
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
