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
