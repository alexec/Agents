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
    private(set) var entries: [TranscriptEntry] = []
    private(set) var transcriptHasMore = false
    private(set) var isConnected = false
    private(set) var problem: String?

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
    var draftChosen: [String: JSONValue] = [:]
    private(set) var isLoadingDraftOptions = false
    private var draftID: UUID?

    private let client = DaemonClient()
    private var listening: Task<Void, Never>?
    private var firstTranscriptIndex = 0

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

        case DaemonAPI.Notification.agentEntry:
            guard let entry = try? params?.decode(DaemonAPI.EntryNotification.self) else { return }
            if entry.agentID == selection { entries.append(entry.entry) }

        case DaemonAPI.Notification.agentPermission:
            guard let notification = try? params?.decode(DaemonAPI.PermissionNotification.self) else { return }
            permissions.removeAll { $0.agentID == notification.agentID }
            if let request = notification.request { permissions.append(request) }

        case DaemonAPI.Notification.runtimeChanged:
            await refreshRuntimes()

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
        await refreshRuntimes()
        await refreshPermissions()
        await loadTranscript()
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
        draftChosen = [:]
        draftID = nil
        defer { isLoadingDraftOptions = false }
        do {
            let response = try await client.call(DaemonAPI.Method.agentsOptions,
                                                 DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: cwd),
                                                 returning: DaemonAPI.OptionsResponse.self)
            draftID = response.draftID
            draftOptions = response.options.filter(\.isRenderable).sorted { $0.categoryRank < $1.categoryRank }
            for option in draftOptions where option.currentValue != nil {
                draftChosen[option.id] = option.currentValue
            }
        } catch {
            problem = describe(error)
        }
    }

    func startDraft(prompt: String) async {
        guard let runtimeID = draftRuntimeID, let cwd = draftCwd else { return }
        let request = DaemonAPI.StartRequest(runtimeID: runtimeID,
                                             cwd: cwd,
                                             prompt: prompt,
                                             startOptions: StartOptions(values: draftChosen),
                                             draftID: draftID)
        do {
            let id = try await client.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            draftID = nil
            await refreshAgents()
            selection = id
        } catch {
            problem = describe(error)
        }
    }

    func send(_ text: String) async {
        guard let selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await attempt {
            try await self.client.call(DaemonAPI.Method.agentsPrompt,
                                       DaemonAPI.PromptRequest(agentID: selection, text: text))
        }
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

    func dismissProblem() { problem = nil }

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
        if let error = error as? JSONRPCError { return error.message }
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
