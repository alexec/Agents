import Foundation

extension DaemonCore {
    /// One place where a method name becomes work. Anything unrecognised is declined
    /// loudly, the same way we decline a runtime asking us for something.
    ///
    /// `surface` and `connection` are who is asking, taken from the connection by the
    /// server and never from the parameters: a presence report has to belong to
    /// somebody, and the one thing a caller must not be able to say is who it is.
    public func handle(method: String, params: JSONValue?,
                       from surface: Surface? = nil, connection: UUID? = nil) async -> Result<JSONValue, JSONRPCError> {
        do {
            switch method {
            case DaemonAPI.Method.ping:
                return .success(["ok": true])

            case DaemonAPI.Method.presenceReport:
                let report = try require(params, as: DaemonAPI.PresenceReport.self)
                try reportPresence(report, from: surface, connection: connection)
                return .success([:])

            case DaemonAPI.Method.attentionPending:
                return .success(try JSONValue.encoding(attentionPending()))

            case DaemonAPI.Method.surfaceIdentify:
                let who = try require(params, as: DaemonAPI.SurfaceIdentification.self)
                try identify(who, from: surface, connection: connection)
                return .success([:])

            case DaemonAPI.Method.mailboxCarry:
                try becomeCarrier(connection: connection)
                return .success([:])

            case DaemonAPI.Method.devicesList:
                return .success(try JSONValue.encoding(allDevices()))

            case DaemonAPI.Method.devicesAnnounce:
                let announcement = try require(params, as: DaemonAPI.DeviceAnnouncement.self)
                return .success(try JSONValue.encoding(try announce(announcement)))

            case DaemonAPI.Method.projectsList:
                let request = try require(params, as: DaemonAPI.ProjectsListRequest.self)
                return .success(try JSONValue.encoding(
                    allProjects(includeArchived: request.includeArchived)))

            case DaemonAPI.Method.projectsAdd:
                let request = try require(params, as: DaemonAPI.ProjectRequest.self)
                return .success(try JSONValue.encoding(try await addProject(request.folder)))

            case DaemonAPI.Method.projectsArchive:
                let request = try require(params, as: DaemonAPI.ProjectRequest.self)
                return .success(try JSONValue.encoding(try await archiveProject(request.folder)))

            case DaemonAPI.Method.projectsUnarchive:
                let request = try require(params, as: DaemonAPI.ProjectRequest.self)
                return .success(try JSONValue.encoding(try await unarchiveProject(request.folder)))

            case DaemonAPI.Method.workflowsList:
                let request = try decode(params, as: DaemonAPI.WorkflowsListRequest.self) ?? .init()
                return .success(try JSONValue.encoding(allWorkflows(in: request.folder)))

            case DaemonAPI.Method.workflowsRun:
                let request = try require(params, as: DaemonAPI.WorkflowRequest.self)
                return .success(try JSONValue.encoding(try await runWorkflow(request)))

            case DaemonAPI.Method.workflowsArchive:
                let request = try require(params, as: DaemonAPI.WorkflowArchiveRequest.self)
                return .success(try JSONValue.encoding(try archiveWorkflow(request)))

            case DaemonAPI.Method.workflowsSettings:
                let request = try require(params, as: DaemonAPI.WorkflowSettingsRequest.self)
                return .success(try JSONValue.encoding(try setWorkflowSettings(request)))

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

            case DaemonAPI.Method.agentsResuming:
                // For a window that connected part-way through the batch. Order is
                // not meaningful: it is a set of chats, not a running order.
                return .success(try JSONValue.encoding(
                    DaemonAPI.ResumingResponse(agentIDs: stillResuming())))

            case DaemonAPI.Method.agentsOptions:
                let request = try require(params, as: DaemonAPI.OptionsRequest.self)
                return .success(try JSONValue.encoding(try await options(request)))

            case DaemonAPI.Method.optionsRemembered:
                let request = try require(params, as: DaemonAPI.RememberedOptionsRequest.self)
                return .success(try JSONValue.encoding(rememberedOptions(request)))

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

            case DaemonAPI.Method.agentsSetCeiling:
                let request = try require(params, as: DaemonAPI.SetCeilingRequest.self)
                return .success(try JSONValue.encoding(try await setCeiling(request)))

            // The reader's money. All three are window calls and none is served to
            // an agent: a runaway that can raise its own limit is not stopped.
            case DaemonAPI.Method.costState:
                return .success(try JSONValue.encoding(await costState()))

            // Asked once by a window on connecting. A window opened while a hold was
            // already in place heard no broadcast, and would otherwise say nothing
            // about it until the verdict next moved (024 T037).
            case DaemonAPI.Method.wakeState:
                return .success(try JSONValue.encoding(await wakeState()))

            case DaemonAPI.Method.costSetLimits:
                let request = try require(params, as: DaemonAPI.SetLimitsRequest.self)
                return .success(try JSONValue.encoding(await setLimits(request)))

            case DaemonAPI.Method.agentsSuggestPrompts:
                let request = try require(params, as: DaemonAPI.SuggestPromptsRequest.self)
                return .success(["note": .string(try await suggestPrompts(request))])

            case DaemonAPI.Method.agentsShowFile:
                let request = try require(params, as: DaemonAPI.ShowFileRequest.self)
                return .success(["note": .string(try await showFile(request))])

            case DaemonAPI.Method.artifactWrite:
                let request = try require(params, as: DaemonAPI.ArtifactWriteRequest.self)
                try await artifactWrite(request)
                return .success([:])

            case DaemonAPI.Method.agentsManageWorkflows:
                let request = try require(params, as: DaemonAPI.ManageWorkflowsRequest.self)
                return .success(["note": .string(try await manageWorkflows(request))])

            case DaemonAPI.Method.agentsReportOutcome:
                let request = try require(params, as: DaemonAPI.ReportOutcomeRequest.self)
                return .success(["note": .string(try await reportOutcome(request))])

            case DaemonAPI.Method.agentsFinishTurn:
                let request = try require(params, as: DaemonAPI.FinishTurnRequest.self)
                return .success(["note": .string(try await finishTurn(request))])

            case DaemonAPI.Method.permissionsPending:
                return .success(try JSONValue.encoding(pendingPermissionRequests()))

            case DaemonAPI.Method.permissionsAnswer:
                let request = try require(params, as: DaemonAPI.AnswerRequest.self)
                try await answerPermission(request)
                return .success([:])

            case DaemonAPI.Method.shellAttach:
                let request = try require(params, as: DaemonAPI.ShellAttachRequest.self)
                return .success(try JSONValue.encoding(try attachShell(request)))

            case DaemonAPI.Method.shellDetach:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                detachShell(request.agentID)
                return .success([:])

            case DaemonAPI.Method.shellInput:
                let request = try require(params, as: DaemonAPI.ShellInputRequest.self)
                try writeToShell(request)
                return .success([:])

            case DaemonAPI.Method.shellResize:
                let request = try require(params, as: DaemonAPI.ShellResizeRequest.self)
                resizeShell(request)
                return .success([:])

            case DaemonAPI.Method.shellSignal:
                let request = try require(params, as: DaemonAPI.ShellSignalRequest.self)
                try signalShell(request)
                return .success([:])

            case DaemonAPI.Method.shellRestart:
                let request = try require(params, as: DaemonAPI.ShellAttachRequest.self)
                return .success(try JSONValue.encoding(try restartShell(request)))

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
