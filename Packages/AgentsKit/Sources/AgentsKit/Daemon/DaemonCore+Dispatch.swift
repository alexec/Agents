import Foundation

extension DaemonCore {
    /// One place where a method name becomes work. Anything unrecognised is declined
    /// loudly, the same way we decline a runtime asking us for something.
    public func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        do {
            switch method {
            case DaemonAPI.Method.ping:
                return .success(["ok": true])

            case DaemonAPI.Method.runtimesList:
                return .success(try JSONValue.encoding(runtimeStatuses()))

            case DaemonAPI.Method.runtimesAccounts:
                return .success(try JSONValue.encoding(allAccounts()))

            case DaemonAPI.Method.runtimeAuthenticate:
                let request = try require(params, as: DaemonAPI.AuthenticateRequest.self)
                return .success(try JSONValue.encoding(
                    try await authenticate(runtimeID: request.runtimeID, methodID: request.methodID)))

            case DaemonAPI.Method.runtimeLogOut:
                let request = try require(params, as: DaemonAPI.RuntimeRequest.self)
                return .success(try JSONValue.encoding(try await logOut(runtimeID: request.runtimeID)))

            case DaemonAPI.Method.runtimeSetProvider:
                let request = try require(params, as: DaemonAPI.SetProviderRequest.self)
                return .success(try JSONValue.encoding(
                    try await setProvider(runtimeID: request.runtimeID, providerID: request.providerID)))

            case DaemonAPI.Method.sessionsList:
                let request = try require(params, as: DaemonAPI.SessionsListRequest.self)
                return .success(try JSONValue.encoding(
                    try await listRuntimeSessions(runtimeID: request.runtimeID, cwd: request.cwd)))

            case DaemonAPI.Method.sessionsAdopt:
                let request = try require(params, as: DaemonAPI.AdoptRequest.self)
                return .success(try JSONValue.encoding(
                    try await adopt(runtimeID: request.runtimeID, sessionID: request.sessionID,
                                    cwd: request.cwd)))

            case DaemonAPI.Method.sessionsDelete:
                let request = try require(params, as: DaemonAPI.DeleteSessionRequest.self)
                try await deleteRuntimeSession(runtimeID: request.runtimeID,
                                               sessionID: request.sessionID,
                                               confirmed: request.confirmed)
                return .success([:])

            case DaemonAPI.Method.agentsFork:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                return .success(try JSONValue.encoding(try await fork(agentID: request.agentID)))

            case DaemonAPI.Method.elicitationsPending:
                return .success(try JSONValue.encoding(pendingElicitations()))

            case DaemonAPI.Method.elicitationsAnswer:
                let request = try require(params, as: DaemonAPI.AnswerElicitationRequest.self)
                try await answerElicitation(request)
                return .success([:])

            case DaemonAPI.Method.agentsList:
                let request = try decode(params, as: DaemonAPI.ListRequest.self) ?? .init()
                return .success(try JSONValue.encoding(allAgents(includeArchived: request.includeArchived)))

            case DaemonAPI.Method.agentsOptions:
                let request = try require(params, as: DaemonAPI.OptionsRequest.self)
                return .success(try JSONValue.encoding(try await options(request)))

            case DaemonAPI.Method.agentsStart:
                let request = try require(params, as: DaemonAPI.StartRequest.self)
                return .success(try JSONValue.encoding(try await start(request)))

            case DaemonAPI.Method.agentsPrompt:
                let request = try require(params, as: DaemonAPI.PromptRequest.self)
                try await prompt(request)
                return .success([:])

            case DaemonAPI.Method.agentsUnqueue:
                let request = try require(params, as: DaemonAPI.UnqueueRequest.self)
                try await unqueue(request)
                return .success([:])

            case DaemonAPI.Method.agentsStop:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                try await stop(request.agentID)
                return .success([:])

            case DaemonAPI.Method.agentsArchive:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                try await archive(request.agentID)
                return .success([:])

            case DaemonAPI.Method.agentsUnarchive:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                try await unarchive(request.agentID)
                return .success([:])

            case DaemonAPI.Method.agentsTranscript:
                let request = try require(params, as: DaemonAPI.TranscriptRequest.self)
                return .success(try JSONValue.encoding(try await transcript(request)))

            case DaemonAPI.Method.agentsSetOption:
                let request = try require(params, as: DaemonAPI.SetOptionRequest.self)
                return .success(try JSONValue.encoding(try await setOption(request)))

            case DaemonAPI.Method.agentsSuggestPrompts:
                let request = try require(params, as: DaemonAPI.SuggestPromptsRequest.self)
                return .success(["note": .string(try await suggestPrompts(request))])

            case DaemonAPI.Method.permissionsPending:
                return .success(try JSONValue.encoding(pendingPermissionRequests()))

            case DaemonAPI.Method.permissionsAnswer:
                let request = try require(params, as: DaemonAPI.AnswerRequest.self)
                try await answerPermission(request)
                return .success([:])

            default:
                return .failure(.methodNotFound(method))
            }
        } catch let error as JSONRPCError {
            return .failure(error)
        } catch {
            return .failure(.internalError(String(describing: error)))
        }
    }

    private func decode<T: Decodable>(_ params: JSONValue?, as type: T.Type) throws -> T? {
        guard let params, !params.isNull else { return nil }
        return try params.decode(T.self)
    }

    private func require<T: Decodable>(_ params: JSONValue?, as type: T.Type) throws -> T {
        guard let decoded = try decode(params, as: type) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "\(type) expected")
        }
        return decoded
    }
}
