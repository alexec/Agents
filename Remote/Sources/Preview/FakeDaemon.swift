import AgentsKitCore
import Foundation

/// A daemon that is not there, so the layout can be judged before the machinery under
/// it exists.
///
/// It is a `DaemonLink` and not a fake model: it answers the real methods over a real
/// `JSONRPCConnection`, so `DaemonClient` and `RemoteModel` above it run exactly as
/// they will when a mailbox is carrying the bytes instead of a pair of streams in
/// memory. That is the point. When the bridge lands, one line changes — which link
/// `RemoteModel` is handed — and nothing above it is touched.
///
/// Delivered late on purpose. A list that appears instantly is a list nobody can tell
/// apart from a hard-coded one, and the whole reason this exists is to find out what
/// the screens feel like over a connection with seconds in it.
final class FakeDaemon: DaemonLink, @unchecked Sendable {
    private let state = FakeState()

    func transport() async throws -> any LineTransport {
        let (near, far) = PairedTransport.pair()
        let state = state
        let connection = JSONRPCConnection(transport: far) { method, params in
            await state.answer(method, params)
        }
        await connection.start()
        await state.hold(connection)
        return near
    }

    /// Raise a question on the agent that is waiting, as if a runtime had just asked.
    /// The one thing worth being able to provoke by hand: the screen this feature
    /// exists for.
    func askSomething() async {
        await state.askSomething()
    }
}

/// The canned Mac: a handful of projects, the agents in them, and one question
/// waiting.
private actor FakeState {
    private var connection: JSONRPCConnection?
    private(set) var agents: [Agent] = Canned.agents
    private(set) var permissions: [PermissionRequest] = [Canned.question]
    private(set) var forms: [ElicitationRequest] = [Canned.form]

    func hold(_ connection: JSONRPCConnection) {
        self.connection = connection
    }

    func answer(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        // The delay is the feature. A mailbox round trip is a second or two and the
        // screens have to read well with that in them.
        if method != DaemonAPI.Method.ping {
            try? await Task.sleep(for: .milliseconds(350))
        }
        do {
            switch method {
            case DaemonAPI.Method.ping:
                return .success(.object([:]))

            case DaemonAPI.Method.agentsList:
                return .success(try JSONValue.encoding(agents))

            case DaemonAPI.Method.projectsList:
                return .success(try JSONValue.encoding(Canned.projects(for: agents)))

            case DaemonAPI.Method.permissionsPending:
                return .success(try JSONValue.encoding(permissions))

            case DaemonAPI.Method.elicitationsPending:
                return .success(try JSONValue.encoding(forms))

            case DaemonAPI.Method.runtimesList:
                return .success(try JSONValue.encoding(Canned.runtimes))

            case DaemonAPI.Method.runtimesAccounts:
                return .success(try JSONValue.encoding([RuntimeAccount]()))

            case DaemonAPI.Method.agentsOptions:
                return .success(try JSONValue.encoding(
                    DaemonAPI.OptionsResponse(draftID: UUID(), options: Canned.startOptions)))

            case DaemonAPI.Method.agentsDiscardDraft:
                return .success(.object([:]))

            case DaemonAPI.Method.agentsStart:
                let request = try params?.decode(DaemonAPI.StartRequest.self)
                if let id = request?.requestID, let made = agents.first(where: { $0.startRequestID == id }) {
                    return .success(try JSONValue.encoding(made.id))
                }
                guard let request else { return .failure(JSONRPCError(code: -32602, message: "No start")) }
                var agent = Agent(runtimeID: request.runtimeID, cwd: request.cwd,
                                  title: Agent.fallbackTitle(from: request.prompt), state: .running,
                                  startOptions: request.startOptions,
                                  startRequestID: request.requestID)
                agent.lastActivityAt = Date()
                agents.append(agent)
                await tell(DaemonAPI.Notification.agentChanged, try? JSONValue.encoding(agent))
                return .success(try JSONValue.encoding(agent.id))

            case DaemonAPI.Method.agentsResuming:
                return .success(try JSONValue.encoding(DaemonAPI.ResumingResponse(agentIDs: [])))

            case DaemonAPI.Method.agentsTranscript:
                let request = try params?.decode(DaemonAPI.TranscriptRequest.self)
                let whole = Canned.transcript(for: request?.agentID)
                return .success(try JSONValue.encoding(page(of: whole, request: request)))

            case DaemonAPI.Method.elicitationsAnswer:
                let request = try params?.decode(DaemonAPI.AnswerElicitationRequest.self)
                forms.removeAll { $0.id == request?.requestID }
                return .success(.object([:]))

            case DaemonAPI.Method.permissionsAnswer:
                let request = try params?.decode(DaemonAPI.AnswerRequest.self)
                return .success(try JSONValue.encoding(await answered(request)))

            case DaemonAPI.Method.agentsStop:
                let request = try params?.decode(DaemonAPI.AgentRequest.self)
                await change(request?.agentID) { $0.state = .stopped; $0.endedReason = .cancelled }
                return .success(.object([:]))

            case DaemonAPI.Method.agentsArchive:
                let request = try params?.decode(DaemonAPI.AgentRequest.self)
                await change(request?.agentID) { $0.state = .archived }
                return .success(.object([:]))

            case DaemonAPI.Method.agentsUnarchive:
                let request = try params?.decode(DaemonAPI.AgentRequest.self)
                await change(request?.agentID) { $0.state = .finished }
                return .success(.object([:]))

            case DaemonAPI.Method.agentsPark:
                let request = try params?.decode(DaemonAPI.AgentRequest.self)
                await change(request?.agentID) {
                    $0.parking = $0.state.hasTurnInFlight ? .whenTurnEnds(since: Date()) : .parked(at: Date())
                }
                return .success(.object([:]))

            case DaemonAPI.Method.agentsUnpark:
                let request = try params?.decode(DaemonAPI.AgentRequest.self)
                await change(request?.agentID) { $0.parking = nil }
                return .success(.object([:]))

            default:
                return .failure(JSONRPCError(code: -32601, message: "Not in the fake: \(method)"))
            }
        } catch {
            return .failure(JSONRPCError(code: -32603, message: "\(error)"))
        }
    }

    /// The page the reader asked for, out of the whole canned conversation.
    private func page(of whole: [TranscriptEntry],
                      request: DaemonAPI.TranscriptRequest?) -> TranscriptPage {
        let limit = request?.limit ?? 200
        let end = request?.before ?? whole.count
        let start = max(0, end - limit)
        guard start < end else { return TranscriptPage(firstIndex: 0, total: whole.count, entries: []) }
        return TranscriptPage(firstIndex: start, total: whole.count,
                              entries: Array(whole[start..<end]))
    }

    /// First answer wins, as it does on the Mac.
    private func answered(_ request: DaemonAPI.AnswerRequest?) async -> JSONValue {
        guard let request,
              let index = permissions.firstIndex(where: { $0.id == request.permissionID })
        else { return .object([:]) }
        let question = permissions.remove(at: index)
        await change(question.agentID) { $0.state = .running }
        await tell(DaemonAPI.Notification.agentPermission,
                   try? JSONValue.encoding(DaemonAPI.PermissionNotification(agentID: question.agentID,
                                                                           request: nil)))
        return .object([:])
    }

    private func change(_ id: UUID?, _ edit: (inout Agent) -> Void) async {
        guard let id, let index = agents.firstIndex(where: { $0.id == id }) else { return }
        edit(&agents[index])
        agents[index].lastActivityAt = Date()
        await tell(DaemonAPI.Notification.agentChanged, try? JSONValue.encoding(agents[index]))
    }

    func askSomething() async {
        guard let agent = agents.first(where: { $0.state == .running }) else { return }
        let question = PermissionRequest(
            agentID: agent.id,
            toolCall: ToolCall(title: "Run `git push origin main`", kind: "execute"),
            options: [PermissionOption(optionID: "allow", name: "Allow", kind: .allowOnce),
                      PermissionOption(optionID: "always", name: "Always allow", kind: .allowAlways),
                      PermissionOption(optionID: "no", name: "Don't allow", kind: .rejectOnce)])
        permissions.append(question)
        await change(agent.id) { $0.state = .waitingOnUser }
        await tell(DaemonAPI.Notification.agentPermission,
                   try? JSONValue.encoding(DaemonAPI.PermissionNotification(agentID: agent.id,
                                                                           request: question)))
    }

    /// Push something at whoever is connected. The far end of a `JSONRPCConnection` is
    /// an actor, so this is a hop rather than a call.
    private func tell(_ method: String, _ params: JSONValue?) async {
        try? connection?.notify(method, params)
    }
}
