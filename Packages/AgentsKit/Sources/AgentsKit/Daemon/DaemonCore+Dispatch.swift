import Foundation

extension DaemonCore {
    /// One place where a method name becomes work. Anything unrecognised is declined
    /// loudly, the same way we decline a runtime asking us for something.
    ///
    /// `surface` and `connection` are who is asking, taken from the connection by the
    /// server and never from the parameters: a presence report has to belong to
    /// somebody, and the one thing a caller must not be able to say is who it is.
    ///
    /// `peer` is the process on the other end of the socket, `-1` when the kernel would
    /// not say, and nil only for a caller inside this process.
    public func handle(method: String, params: JSONValue?,
                       from surface: Surface? = nil, connection: UUID? = nil,
                       peer: Int32? = nil) async -> Result<JSONValue, JSONRPCError> {
        if let refusal = await tokenRefusal(params, peer: peer) { return .failure(refusal) }
        // Who asked travels with the work, so a runtime started deep inside it is started
        // with what that connection lent (043).
        return await RequestConnection.$current.withValue(connection) {
            await dispatch(method: method, params: params, from: surface, connection: connection)
        }
    }

    /// A token speaks for its agent only from inside that agent's runtime.
    ///
    /// The token is on the helper's command line, where every process of this account
    /// can read it. So a call carrying one has to come from a process the agent's own
    /// runtime started — the helper, through `npx` or a shell at most — or it is turned
    /// away as if the token meant nothing. A token nobody holds is left for the method
    /// to refuse in its own words.
    func tokenRefusal(_ params: JSONValue?, peer: Int32?) async -> JSONRPCError? {
        guard let peer, let token = params?["token"]?.stringValue,
              let agentID = appTokens[token] else { return nil }
        if let runtime = await live[agentID]?.processIdentifier, PeerCredentials.descends(peer, from: runtime) {
            return nil
        }
        DaemonLog.shared.write("refused a token call from pid \(peer): not started by that agent's runtime")
        return JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                            message: "That conversation is not open to this process, so nothing was done.")
    }

    private func dispatch(method: String, params: JSONValue?,
                          from surface: Surface?, connection: UUID?) async -> Result<JSONValue, JSONRPCError> {
        do {
            switch method {
            case DaemonAPI.Method.ping:
                return .success(["ok": true])

            case DaemonAPI.Method.credentialsOffer:
                let request = try require(params, as: DaemonAPI.CredentialsOffer.self)
                offerCredentials(request, connection: connection)
                return .success([:])

            case DaemonAPI.Method.credentialsLend:
                let request = try require(params, as: DaemonAPI.CredentialsLend.self)
                try lendCredential(request, connection: connection)
                return .success([:])

            case DaemonAPI.Method.filesWrite:
                let request = try require(params, as: DaemonAPI.FilesWriteRequest.self)
                return .success(try JSONValue.encoding(try writeAttachment(request)))

            case DaemonAPI.Method.filesBrowse:
                let request = try decode(params, as: DaemonAPI.FilesBrowseRequest.self) ?? .init()
                return .success(try JSONValue.encoding(try browse(request)))

            case DaemonAPI.Method.daemonStatus:
                return .success(try JSONValue.encoding(status()))

            case DaemonAPI.Method.daemonQuit:
                let request = try require(params, as: DaemonAPI.QuitRequest.self)
                try await quit(request)
                return .success([:])

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

            case DaemonAPI.Method.projectsClone:
                let request = try require(params, as: DaemonAPI.CloneRequest.self)
                return .success(try JSONValue.encoding(try await cloneProject(request.url)))

            case DaemonAPI.Method.projectsClones:
                return .success(try JSONValue.encoding(allClones()))

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

            case DaemonAPI.Method.workflowsApprove:
                let request = try require(params, as: DaemonAPI.WorkflowApproveRequest.self)
                return .success(try JSONValue.encoding(try approveWorkflow(request)))

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
                return .success(try await once(request.sendID) {
                    try await self.answerElicitation(request)
                    return [:]
                })

            case DaemonAPI.Method.agentsList:
                let request = try decode(params, as: DaemonAPI.ListRequest.self) ?? .init()
                return .success(try JSONValue.encoding(listAgents(request)))

            case DaemonAPI.Method.agentsResuming:
                // For a window that connected part-way through the batch. Order is
                // not meaningful: it is a set of chats, not a running order.
                return .success(try JSONValue.encoding(
                    DaemonAPI.ResumingResponse(agentIDs: stillResuming())))

            case DaemonAPI.Method.agentsOptions:
                let request = try require(params, as: DaemonAPI.OptionsRequest.self)
                return .success(try JSONValue.encoding(try await options(request, connection: connection)))

            case DaemonAPI.Method.modesRemembered:
                return .success(try JSONValue.encoding(rememberedModes()))

            case DaemonAPI.Method.modesImport:
                let request = try require(params, as: DaemonAPI.ModesImportRequest.self)
                return .success(try JSONValue.encoding(importModes(request)))

            case DaemonAPI.Method.agentsDiscardDraft:
                let request = try require(params, as: DaemonAPI.DiscardDraftRequest.self)
                await discardDraft(request)
                return .success([:])

            case DaemonAPI.Method.optionsRemembered:
                let request = try require(params, as: DaemonAPI.RememberedOptionsRequest.self)
                return .success(try JSONValue.encoding(rememberedOptions(request)))

            case DaemonAPI.Method.agentsStart:
                let request = try require(params, as: DaemonAPI.StartRequest.self)
                return .success(try JSONValue.encoding(try await start(request)))

            case DaemonAPI.Method.agentsPrompt:
                let request = try require(params, as: DaemonAPI.PromptRequest.self)
                // Only the Mac and the phone send this, so a person's prompt here is a
                // person typing, and that picks a parked chat back up (040, FR-009).
                // Workflows, the restart pick-up and the outcome question reach
                // `prompt` directly and leave the chat parked.
                return .success(try await once(request.sendID) {
                    if request.from == .person { await self.unparkQuietly(request.agentID) }
                    try await self.prompt(request)
                    return [:]
                })

            case DaemonAPI.Method.agentsUnqueue:
                let request = try require(params, as: DaemonAPI.UnqueueRequest.self)
                try await unqueue(request)
                return .success([:])

            case DaemonAPI.Method.filesMention:
                let request = try require(params, as: DaemonAPI.FileMentionRequest.self)
                return .success(try JSONValue.encoding(try await fileMentions(request)))

            case DaemonAPI.Method.filesList:
                let request = try require(params, as: DaemonAPI.FilesListRequest.self)
                return .success(try JSONValue.encoding(try listFiles(request)))

            case DaemonAPI.Method.filesRead:
                let request = try require(params, as: DaemonAPI.FilesReadRequest.self)
                return .success(try JSONValue.encoding(try readFile(request)))

            case DaemonAPI.Method.filesWatch:
                let request = try require(params, as: DaemonAPI.FilesWatchRequest.self)
                try watchFiles(request, connection: connection)
                return .success([:])

            case DaemonAPI.Method.filesUnwatch:
                let request = try require(params, as: DaemonAPI.FilesWatchRequest.self)
                unwatchFiles(request, connection: connection)
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

            case DaemonAPI.Method.agentsPark:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                try park(request.agentID)
                return .success([:])

            case DaemonAPI.Method.agentsUnpark:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                try unpark(request.agentID)
                return .success([:])

            case DaemonAPI.Method.agentsTranscript:
                let request = try require(params, as: DaemonAPI.TranscriptRequest.self)
                return .success(try JSONValue.encoding(try await transcript(request)))

            case DaemonAPI.Method.changesList:
                let request = try require(params, as: DaemonAPI.ChangesListRequest.self)
                return .success(try JSONValue.encoding(try await changesList(request)))

            case DaemonAPI.Method.changesFile:
                let request = try require(params, as: DaemonAPI.ChangesFileRequest.self)
                return .success(try JSONValue.encoding(try await changesFile(request)))

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

            case DaemonAPI.Method.agentsPushPullRequest:
                let request = try require(params, as: DaemonAPI.PushPullRequestRequest.self)
                return .success(["note": .string(try await pushPullRequest(request))])

            case DaemonAPI.Method.agentsReplyOnPullRequest:
                let request = try require(params, as: DaemonAPI.ReplyOnPullRequestRequest.self)
                return .success(["note": .string(try await replyOnPullRequest(request))])

            case DaemonAPI.Method.leasesLease:
                let request = try require(params, as: DaemonAPI.LeaseRequest.self)
                return .success(["note": .string(try await lease(request))])

            case DaemonAPI.Method.leasesRelease:
                let request = try require(params, as: DaemonAPI.LeaseNameRequest.self)
                return .success(["note": .string(try await releaseLease(request))])

            case DaemonAPI.Method.leasesList:
                let request = try require(params, as: DaemonAPI.LeaseTokenRequest.self)
                return .success(["note": .string(try await listLeases(request))])

            case DaemonAPI.Method.eventsWait:
                let request = try require(params, as: DaemonAPI.EventWaitRequest.self)
                return .success(["note": .string(try await waitForEvent(request))])

            case DaemonAPI.Method.eventsCancel:
                let request = try require(params, as: DaemonAPI.EventTokenRequest.self)
                return .success(["note": .string(try cancelWait(request))])

            case DaemonAPI.Method.eventsPublish:
                let request = try require(params, as: DaemonAPI.EventPublishRequest.self)
                return .success(["note": .string(try publishEvent(request))])

            case DaemonAPI.Method.eventsCancelWait:
                let request = try require(params, as: DaemonAPI.CancelWaitRequest.self)
                return .success(try JSONValue.encoding(try cancelWaitByPerson(request)))

            case DaemonAPI.Method.eventsList:
                let request = try require(params, as: DaemonAPI.EventsListRequest.self)
                return .success(try JSONValue.encoding(eventsPage(request)))

            case DaemonAPI.Method.eventsRaise:
                let request = try require(params, as: DaemonAPI.EventRaiseRequest.self)
                return .success(try JSONValue.encoding(try raiseByHand(request)))

            case DaemonAPI.Method.eventsServer:
                let request = try require(params, as: DaemonAPI.ServerReachabilityChange.self)
                return .success(try JSONValue.encoding(try raiseServerChange(request, from: surface)))

            case DaemonAPI.Method.leasesSnapshot:
                return .success(try JSONValue.encoding(await leaseSnapshot()))

            case DaemonAPI.Method.leasesEnd:
                let request = try require(params, as: DaemonAPI.PersonEndRequest.self)
                return .success(try JSONValue.encoding(try await endLease(request)))

            case DaemonAPI.Method.leasesRemoveWaiter:
                let request = try require(params, as: DaemonAPI.PersonRemoveRequest.self)
                return .success(try JSONValue.encoding(try await removeWaiter(request)))

            case DaemonAPI.Method.agentsStartHelper:
                let request = try require(params, as: DaemonAPI.StartHelperRequest.self)
                let started = try await startHelper(request)
                return .success(["note": .string(started.note),
                                 "agentID": .string(started.agentID.uuidString)])

            case DaemonAPI.Method.agentsStopHelper:
                let request = try require(params, as: DaemonAPI.HelperRequest.self)
                return .success(["note": .string(try await stopHelper(request))])

            case DaemonAPI.Method.agentsArchiveHelper:
                let request = try require(params, as: DaemonAPI.HelperRequest.self)
                return .success(["note": .string(try await archiveHelper(request))])

            case DaemonAPI.Method.worktreesList:
                let request = try require(params, as: DaemonAPI.WorktreesListRequest.self)
                return .success(try JSONValue.encoding(await listWorktrees(for: request.folder)))

            case DaemonAPI.Method.worktreesCheck:
                let request = try require(params, as: DaemonAPI.WorktreeRemovalRequest.self)
                return .success(try JSONValue.encoding(try await checkWorktreeRemoval(request)))

            case DaemonAPI.Method.worktreesRemove:
                let request = try require(params, as: DaemonAPI.WorktreeRemovalRequest.self)
                return .success(try JSONValue.encoding(try await removeWorktree(request)))

            // Pull requests (038). The Mac's only: the phone has no section to ask for.
            case DaemonAPI.Method.pullRequestsList:
                let request = try require(params, as: DaemonAPI.PullRequestsRequest.self)
                return .success(try JSONValue.encoding(await pullRequestList(for: request.folder)))

            case DaemonAPI.Method.pullRequestsRefresh:
                let request = try require(params, as: DaemonAPI.PullRequestsRequest.self)
                return .success(try JSONValue.encoding(await refreshPullRequests(in: request.folder)))

            case DaemonAPI.Method.pullRequestsResume:
                let request = try require(params, as: DaemonAPI.PullRequestRequest.self)
                return .success(try JSONValue.encoding(try await resumePullRequest(request.number, in: request.folder)))

            case DaemonAPI.Method.pullRequestsAddBabysitter:
                let request = try require(params, as: DaemonAPI.PullRequestsRequest.self)
                return .success(try JSONValue.encoding(try addBabysitter(in: request.folder)))

            case DaemonAPI.Method.pullRequestsCheckout:
                let request = try require(params, as: DaemonAPI.PullRequestRequest.self)
                return .success(try JSONValue.encoding(try await checkOutPullRequest(request.number, in: request.folder)))

            case DaemonAPI.Method.agentsListHelpers:
                let request = try require(params, as: DaemonAPI.ListHelpersRequest.self)
                return .success(["note": .string(try listHelpers(request))])

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
                return .success(try await once(request.sendID) {
                    try await self.answerPermission(request)
                    return [:]
                })

            case DaemonAPI.Method.shellAttach:
                let request = try require(params, as: DaemonAPI.ShellAttachRequest.self)
                return .success(try JSONValue.encoding(try attachShell(request, from: surface, connection: connection)))

            case DaemonAPI.Method.shellDetach:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                detachShell(request.agentID, connection: connection)
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
                return .success(try JSONValue.encoding(try restartShell(request, from: surface, connection: connection)))

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
