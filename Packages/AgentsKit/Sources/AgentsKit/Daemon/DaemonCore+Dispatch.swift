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
    ///
    /// `vouched`: a device's channel the control plane opened, for a device it paired (#232).
    public func handle(method: String, params: JSONValue?,
                       from surface: Surface? = nil, connection: UUID? = nil,
                       peer: Int32? = nil, role: ConnectionRole = .control,
                       vouched: Bool = false) async -> Result<JSONValue, JSONRPCError> {
        if let refusal = await tokenRefusal(params, peer: peer) { return .failure(refusal) }
        // An agent's call to the app's own tools, kept as answered (#47). Read before the
        // call, which may be the last one its token is good for.
        let caller = params?["token"]?.stringValue.flatMap { appTokens[$0] }
        let began = now()
        // Its runtime is answering: back in the pool now, not when the turn ends (#140).
        if let caller { runtimeAnswering(agentID: caller) }
        // Who asked travels with the work, so a runtime started deep inside it is started
        // with what that connection lent (043).
        let answer = await RequestConnection.$current.withValue(connection) {
            await RequestConnection.$role.withValue(role) {
                await dispatch(method: method, params: params, from: surface, connection: connection, role: role,
                               vouched: vouched)
            }
        }
        if let caller { keepAppToolCall(caller, method: method, params: params, answer: answer, began: began) }
        return answer
    }

    /// A token speaks for its agent only through the app's own MCP endpoint (#185).
    ///
    /// The endpoint calls `handle` from inside this process, so `peer` is nil. A call
    /// carrying a live token over the socket comes from no runtime the daemon handed it
    /// to, since none is told the socket any more, and is turned away as if the token meant
    /// nothing. A token nobody holds is left for the method to refuse in its own words.
    func tokenRefusal(_ params: JSONValue?, peer: Int32?) async -> JSONRPCError? {
        guard let peer, let token = params?["token"]?.stringValue, appTokens[token] != nil else { return nil }
        DaemonLog.shared.write("refused a token call from pid \(peer) over the socket")
        return JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                            message: "That conversation is not open to this process, so nothing was done.")
    }

    private func dispatch(method: String, params: JSONValue?,
                          from surface: Surface?, connection: UUID?,
                          role: ConnectionRole, vouched: Bool) async -> Result<JSONValue, JSONRPCError> {
        do {
            switch method {
            case DaemonAPI.Method.ping:
                return .success(["ok": true])

            case DaemonAPI.Method.credentialsOffer:
                let request = try require(params, as: DaemonAPI.CredentialsOffer.self)
                offerCredentials(request, connection: connection)
                return .success([:])

            case DaemonAPI.Method.relayOffer:
                let request = try require(params, as: DaemonAPI.RelayOffer.self)
                try offerRelay(request, connection: connection)
                return .success([:])

            case DaemonAPI.Method.relayGrant:
                let request = try require(params, as: DaemonAPI.RelayGrantRequest.self)
                return .success(try JSONValue.encoding(try await grantRelay(request.runtime)))

            case DaemonAPI.Method.credentialsLend:
                let request = try require(params, as: DaemonAPI.CredentialsLend.self)
                try lendCredential(request, connection: connection)
                return .success([:])

            case DaemonAPI.Method.credentialsLendSignIn:
                let request = try require(params, as: DaemonAPI.SignInLend.self)
                try lendSignIn(request, connection: connection)
                return .success([:])

            case DaemonAPI.Method.filesWrite:
                let request = try require(params, as: DaemonAPI.FilesWriteRequest.self)
                return .success(try JSONValue.encoding(try writeAttachment(request)))

            case DaemonAPI.Method.dropboxPut:
                let request = try require(params, as: DaemonAPI.DropboxPutRequest.self)
                return .success(try JSONValue.encoding(try putInDropbox(request)))

            case DaemonAPI.Method.macReveal:
                try macReveal(try require(params, as: DaemonAPI.MacPathRequest.self))
                return .success([:])

            case DaemonAPI.Method.macOpen:
                try macOpenPath(try require(params, as: DaemonAPI.MacPathRequest.self))
                return .success([:])

            case DaemonAPI.Method.macTerminal:
                try macTerminal(try decode(params, as: DaemonAPI.MacTerminalRequest.self) ?? .init())
                return .success([:])

            case DaemonAPI.Method.filesReadText:
                return .success(try JSONValue.encoding(try readText(try require(params, as: DaemonAPI.FilesTextRequest.self))))

            case DaemonAPI.Method.filesSaveText:
                try saveText(try require(params, as: DaemonAPI.FilesSaveTextRequest.self))
                return .success([:])

            case DaemonAPI.Method.filesBrowse:
                let request = try decode(params, as: DaemonAPI.FilesBrowseRequest.self) ?? .init()
                return .success(try JSONValue.encoding(try await browse(request)))

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

            case DaemonAPI.Method.clientCatchUp:
                let request = try decode(params, as: DaemonAPI.CatchUpRequest.self) ?? .init()
                return .success(try JSONValue.encoding(catchUp(request)))

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
                return .success(try JSONValue.encoding(
                    DaemonAPI.AnnounceReply(device: try announce(announcement, role: role, vouched: vouched),
                                            macKey: relayKey())))

            case DaemonAPI.Method.devicesStartPairing:
                return .success(try JSONValue.encoding(try startPairing()))

            case DaemonAPI.Method.devicesStopPairing:
                stopPairing()
                return .success([:])

            case DaemonAPI.Method.pairingCurrent:
                return .success(try JSONValue.encoding(currentPairing()))

            case DaemonAPI.Method.devicesForget:
                let request = try require(params, as: DaemonAPI.DeviceForget.self)
                try forgetDevice(request.id, from: surface)
                return .success([:])

            case DaemonAPI.Method.relayRegister:
                let registration = try require(params, as: DaemonAPI.RelayRegistration.self)
                try registerRelayKey(registration.publicKey)
                return .success([:])

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

            case DaemonAPI.Method.projectsChatState:
                return .success(try JSONValue.encoding(chatProjectState()))

            case DaemonAPI.Method.projectsSetPinned:
                let request = try require(params, as: DaemonAPI.SetPinnedRequest.self)
                return .success(try JSONValue.encoding(try setPinned(request)))

            case DaemonAPI.Method.projectsSetDiskSpace:
                let request = try require(params, as: DaemonAPI.SetDiskSpaceRequest.self)
                return .success(try JSONValue.encoding(try setDiskSpace(request)))

            case DaemonAPI.Method.projectsReadGuardedChange:
                let request = try require(params, as: DaemonAPI.GuardedChangeRequest.self)
                return .success(try JSONValue.encoding(try readGuardedChange(request)))

            case DaemonAPI.Method.projectsKeepGuardedChange:
                let request = try require(params, as: DaemonAPI.GuardedChangeRequest.self)
                return .success(try JSONValue.encoding(try keepGuardedChange(request)))

            case DaemonAPI.Method.projectsUndoGuardedChange:
                let request = try require(params, as: DaemonAPI.GuardedChangeRequest.self)
                return .success(try JSONValue.encoding(try undoGuardedChange(request)))

            case DaemonAPI.Method.diskState:
                return .success(try JSONValue.encoding(diskState()))

            case DaemonAPI.Method.projectsSetHelperLimits:
                let request = try require(params, as: DaemonAPI.SetHelperLimitsRequest.self)
                return .success(try JSONValue.encoding(try setHelperLimits(request)))

            case DaemonAPI.Method.workflowsList:
                let request = try decode(params, as: DaemonAPI.WorkflowsListRequest.self) ?? .init()
                return .success(try JSONValue.encoding(allWorkflows(in: request.folder)))

            case DaemonAPI.Method.workflowsRun:
                let request = try require(params, as: DaemonAPI.WorkflowRequest.self)
                return .success(try JSONValue.encoding(try await runWorkflow(request)))

            case DaemonAPI.Method.pluginsList:
                let request = try require(params, as: DaemonAPI.PluginsListRequest.self)
                return .success(try JSONValue.encoding(
                    DaemonAPI.PluginsList(folder: request.folder, plugins: projectPlugins(in: request.folder))))

            case DaemonAPI.Method.pluginsApprove:
                let request = try require(params, as: DaemonAPI.PluginApproveRequest.self)
                return .success(try JSONValue.encoding(try approvePlugin(request)))

            case DaemonAPI.Method.workflowsApprove:
                let request = try require(params, as: DaemonAPI.WorkflowApproveRequest.self)
                return .success(try JSONValue.encoding(try approveWorkflow(request)))

            case DaemonAPI.Method.workflowsDeny:
                let request = try require(params, as: DaemonAPI.WorkflowApproveRequest.self)
                return .success(try JSONValue.encoding(try denyWorkflow(request)))

            case DaemonAPI.Method.workflowsArchive:
                let request = try require(params, as: DaemonAPI.WorkflowArchiveRequest.self)
                return .success(try JSONValue.encoding(try archiveWorkflow(request)))

            case DaemonAPI.Method.workflowsLimit:
                return .success(try JSONValue.encoding(readWorkflowLimit()))

            case DaemonAPI.Method.workflowsSetLimit:
                let settings = try require(params, as: WorkflowLimitSettings.self)
                return .success(try JSONValue.encoding(try setWorkflowLimit(settings)))

            case DaemonAPI.Method.workflowsEnable:
                let request = try require(params, as: DaemonAPI.WorkflowEnableRequest.self)
                return .success(try JSONValue.encoding(try setWorkflowEnabled(request)))

            case DaemonAPI.Method.workflowsSettings:
                let request = try require(params, as: DaemonAPI.WorkflowSettingsRequest.self)
                return .success(try JSONValue.encoding(try setWorkflowSettings(request)))

            case DaemonAPI.Method.workflowsClearMCPMissed:
                let request = try require(params, as: DaemonAPI.WorkflowMCPClearMissedRequest.self)
                return .success(try JSONValue.encoding(try clearMCPMissed(request)))

            case DaemonAPI.Method.runtimesList:
                return .success(try JSONValue.encoding(runtimeStatuses()))

            case DaemonAPI.Method.personalShared:
                #if canImport(CryptoKit)
                return .success(try JSONValue.encoding(withManagedSkills(sharedSnapshot())))
                #else
                return .success(try JSONValue.encoding(sharedSnapshot()))
                #endif

            #if canImport(CryptoKit)
            case DaemonAPI.Method.catalogSearch:
                let request = try require(params, as: DaemonAPI.CatalogSearchRequest.self)
                if request.kind == .mcp {
                    return .success(try JSONValue.encoding(await mcpSearchResults(request.query)))
                }
                return .success(try JSONValue.encoding(await catalogSearch(request)))

            case DaemonAPI.Method.catalogPreview:
                let request = try require(params, as: DaemonAPI.CatalogPreviewRequest.self)
                return .success(try JSONValue.encoding(await catalogPreview(request)))

            case DaemonAPI.Method.catalogDestinationState:
                let request = try require(params, as: DaemonAPI.DestinationStateRequest.self)
                return .success(try JSONValue.encoding(try await catalogDestinationState(request)))

            case DaemonAPI.Method.skillsAdd:
                let request = try require(params, as: DaemonAPI.SkillAddRequest.self)
                return .success(try JSONValue.encoding(try await skillsAdd(request)))

            case DaemonAPI.Method.skillsList:
                let request = try require(params, as: DaemonAPI.SkillsListRequest.self)
                return .success(try JSONValue.encoding(try skillsList(request)))

            case DaemonAPI.Method.skillsCheckUpdates:
                let request = try require(params, as: DaemonAPI.SkillsListRequest.self)
                return .success(try JSONValue.encoding(try await skillsCheckUpdates(request)))

            case DaemonAPI.Method.skillsUpdatePreview:
                let request = try require(params, as: DaemonAPI.SkillNameRequest.self)
                return .success(try JSONValue.encoding(try await skillsUpdatePreview(request)))

            case DaemonAPI.Method.skillsRemove:
                let request = try require(params, as: DaemonAPI.SkillNameRequest.self)
                return .success(try JSONValue.encoding(try skillsRemove(request)))

            case DaemonAPI.Method.mcpPreview:
                let request = try require(params, as: DaemonAPI.MCPPreviewRequest.self)
                return .success(try JSONValue.encoding(await mcpPreview(request)))

            case DaemonAPI.Method.mcpAdd:
                let request = try require(params, as: DaemonAPI.MCPAddRequest.self)
                return .success(try JSONValue.encoding(try await mcpAdd(request)))

            case DaemonAPI.Method.mcpList:
                let request = try require(params, as: DaemonAPI.MCPListRequest.self)
                return .success(try JSONValue.encoding(try await mcpList(request)))

            case DaemonAPI.Method.mcpHosted:
                return .success(try JSONValue.encoding(await hostedServers.snapshot()))

            case DaemonAPI.Method.mcpApprove:
                let request = try require(params, as: DaemonAPI.MCPApproveRequest.self)
                return .success(try JSONValue.encoding(try await mcpApprove(request)))

            case DaemonAPI.Method.mcpForgetViews:
                let request = try require(params, as: DaemonAPI.MCPViewsForgetRequest.self)
                try forgetViewAnswers(request)
                return .success([:])

            case DaemonAPI.Method.mcpSetSecret:
                let request = try require(params, as: DaemonAPI.MCPSetSecretRequest.self)
                return .success(try JSONValue.encoding(try mcpSetSecret(request)))

            case DaemonAPI.Method.mcpRemove:
                let request = try require(params, as: DaemonAPI.MCPRemoveRequest.self)
                return .success(try JSONValue.encoding(try mcpRemove(request)))

            case DaemonAPI.Method.mcpVerify:
                let request = try require(params, as: DaemonAPI.MCPVerifyRequest.self)
                return .success(try JSONValue.encoding(await mcpVerify(request)))

            case DaemonAPI.Method.mcpAddByHand:
                let request = try require(params, as: DaemonAPI.MCPAddByHandRequest.self)
                return .success(try JSONValue.encoding(try await mcpAddByHand(request)))

            case DaemonAPI.Method.mcpSignIn:
                let request = try require(params, as: DaemonAPI.MCPSignInRequest.self)
                return .success(try JSONValue.encoding(await mcpSignIn(request)))

            case DaemonAPI.Method.mcpSignInWait:
                let request = try require(params, as: DaemonAPI.MCPSignInFlowRequest.self)
                return .success(try JSONValue.encoding(await mcpSignInWait(request)))

            case DaemonAPI.Method.mcpSignInCancel:
                let request = try require(params, as: DaemonAPI.MCPSignInFlowRequest.self)
                return .success(try JSONValue.encoding(mcpSignInCancel(request)))

            case DaemonAPI.Method.mcpSignOut:
                let request = try require(params, as: DaemonAPI.MCPSignOutRequest.self)
                return .success(try JSONValue.encoding(await mcpSignOut(request)))
            #endif

            case DaemonAPI.Method.runtimesInstall:
                let request = try require(params, as: DaemonAPI.RuntimeRequest.self)
                return .success(try JSONValue.encoding(try installRuntime(request.runtimeID, from: surface)))

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

            case DaemonAPI.Method.runtimeDisableProvider:
                let request = try require(params, as: DaemonAPI.SetProviderRequest.self)
                return .success(try JSONValue.encoding(
                    try await disableProvider(runtimeID: request.runtimeID, providerID: request.providerID)))

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
                // The open chat's record, whole: an archived one is read back first (#107).
                if let id = request.agentID, !request.lean, agents[id]?.isSlim == true { await makeWhole(id) }
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

            case DaemonAPI.Method.agentsSetLabels:
                let request = try require(params, as: DaemonAPI.SetLabelsRequest.self)
                return .success(try JSONValue.encoding(try setSessionLabels(request)))

            case DaemonAPI.Method.agentsLabelVocabulary:
                let request = try require(params, as: DaemonAPI.LabelVocabularyRequest.self)
                return .success(try JSONValue.encoding(labelVocabulary(request)))

            case DaemonAPI.Method.agentsPrompt:
                let request = try require(params, as: DaemonAPI.PromptRequest.self)
                // Only the Mac and the phone send this, so a person's prompt here is a
                // person typing, and that takes back a request to archive (#584): the
                // person has answered it by carrying on. Workflows, the restart pick-up
                // and the outcome question reach `prompt` directly and leave the mark.
                // It also drops an agent's ask to be archived when its turn ends: the
                // person has moved the work on.
                return .success(try await once(request.sendID) {
                    // Before the mark goes below: a refused send leaves the chat as it was.
                    try await self.requireFolder(request.agentID)
                    if request.from == .person {
                        await self.clearArchiveRequest(request.agentID)
                        await self.dropAfterTurnAsk(request.agentID)
                        // How quickly they reply here, for the warm pool (#183).
                        await self.notePersonPrompt(request.agentID)
                    }
                    try await self.prompt(request)
                    return [:]
                })

            case DaemonAPI.Method.agentsUnqueue:
                let request = try require(params, as: DaemonAPI.UnqueueRequest.self)
                try await unqueue(request)
                return .success([:])

            case DaemonAPI.Method.agentsStopBackground:
                let request = try require(params, as: DaemonAPI.StopBackgroundRequest.self)
                return .success(["stopped": .bool(try await stopBackground(request))])

            case DaemonAPI.Method.agentsSendNow:
                let request = try require(params, as: DaemonAPI.UnqueueRequest.self)
                try await sendNow(request)
                return .success([:])

            case DaemonAPI.Method.filesMention:
                let request = try require(params, as: DaemonAPI.FileMentionRequest.self)
                return .success(try JSONValue.encoding(try await fileMentions(request)))

            case DaemonAPI.Method.filesList:
                let request = try require(params, as: DaemonAPI.FilesListRequest.self)
                return .success(try JSONValue.encoding(try await listFiles(request)))

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

            case DaemonAPI.Method.agentsDelete:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                try await deleteNow(request.agentID)
                return .success([:])

            case DaemonAPI.Method.agentsUnarchive:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                try await unarchive(request.agentID)
                return .success([:])

            case DaemonAPI.Method.agentsContinueInProject:
                let request = try require(params, as: DaemonAPI.ContinueInProjectRequest.self)
                return .success(try JSONValue.encoding(try await continueInProject(request)))

            case DaemonAPI.Method.agentsRecreateWorktree:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                return .success(try JSONValue.encoding(try await recreateWorktree(request.agentID)))

            case DaemonAPI.Method.agentsPrewarm:
                let request = try require(params, as: DaemonAPI.PrewarmRequest.self)
                try prewarm(request)
                return .success([:])

            case DaemonAPI.Method.agentsSetUnread:
                let request = try require(params, as: DaemonAPI.SetUnreadRequest.self)
                try setUnread(request.agentID, unread: request.unread)
                return .success([:])

            case DaemonAPI.Method.agentsTranscript:
                let request = try require(params, as: DaemonAPI.TranscriptRequest.self)
                return .success(try JSONValue.encoding(try await transcript(request)))

            case DaemonAPI.Method.agentsTouchedPaths:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                return .success(try JSONValue.encoding(try await touchedPaths(request)))

            case DaemonAPI.Method.agentsTurns:
                let request = try require(params, as: DaemonAPI.TurnsRequest.self)
                return .success(try JSONValue.encoding(try await turns(request)))

            case DaemonAPI.Method.changesList:
                let request = try require(params, as: DaemonAPI.ChangesListRequest.self)
                return .success(try JSONValue.encoding(try await changesList(request)))

            case DaemonAPI.Method.changesFile:
                let request = try require(params, as: DaemonAPI.ChangesFileRequest.self)
                return .success(try JSONValue.encoding(try await changesFile(request)))

            case DaemonAPI.Method.agentsSetOption:
                let request = try require(params, as: DaemonAPI.SetOptionRequest.self)
                return .success(try JSONValue.encoding(try await setOption(request)))

            case DaemonAPI.Method.agentsSetSandbox:
                let request = try require(params, as: DaemonAPI.SetSandboxRequest.self)
                return .success(try JSONValue.encoding(try await setSandbox(request)))

            case DaemonAPI.Method.agentsAnswerSandbox:
                let request = try require(params, as: DaemonAPI.AnswerSandboxRequest.self)
                return .success(try JSONValue.encoding(try await answerSandbox(request)))

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
                return .success(try JSONValue.encoding(wakeState()))

            // Asked once by a window on connecting, then heard as it changes (#205).
            case DaemonAPI.Method.storeNotes:
                return .success(try JSONValue.encoding(storeNotes()))

            case DaemonAPI.Method.wakeSettings:
                return .success(try JSONValue.encoding(readWakeSettings()))

            case DaemonAPI.Method.wakeSet:
                let settings = try require(params, as: WakeSettings.self)
                return .success(try JSONValue.encoding(setWakeSettings(settings)))

            // How long archived agents are kept (051, #398).
            case DaemonAPI.Method.retentionState:
                return .success(try JSONValue.encoding(retentionState()))

            case DaemonAPI.Method.retentionSet:
                let request = try require(params, as: DaemonAPI.RetentionSetRequest.self)
                return .success(try JSONValue.encoding(await setRetention(request)))


            case DaemonAPI.Method.clientPermissionsState:
                return .success(try JSONValue.encoding(clientPermissionState()))

            case DaemonAPI.Method.clientPermissionsSet:
                let settings = try require(params, as: ClientPermissionSettings.self)
                return .success(try JSONValue.encoding(try setClientPermissions(settings)))

            case DaemonAPI.Method.personState:
                return .success(try JSONValue.encoding(personState()))

            case DaemonAPI.Method.personSet:
                let settings = try require(params, as: PersonSettings.self)
                return .success(try JSONValue.encoding(try setPerson(settings)))

            case DaemonAPI.Method.sandboxState:
                return .success(try JSONValue.encoding(sandboxSettings))

            case DaemonAPI.Method.sandboxSet:
                let settings = try require(params, as: SandboxSettings.self)
                return .success(try JSONValue.encoding(try setSandboxSettings(settings)))

            case DaemonAPI.Method.runtimesAllowances:
                // Someone is looking at the runtimes: ask what is left, behind the answer.
                Task { await self.measureAllowances() }
                return .success(try JSONValue.encoding(runtimeAllowances()))

            case DaemonAPI.Method.runtimesAssess:
                let request = try require(params, as: DaemonAPI.AssessRuntimeRequest.self)
                return .success(try JSONValue.encoding(try await assessRuntime(request)))

            case DaemonAPI.Method.runtimesAssessment:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                return .success(try JSONValue.encoding(try await assessment(request.agentID)))

            case DaemonAPI.Method.runtimesMarkAvailable:
                let request = try require(params, as: DaemonAPI.MarkRuntimeAvailable.self)
                return .success(try JSONValue.encoding(markRuntimeAvailable(credentialKey: request.credentialKey)))

            case DaemonAPI.Method.poolApplyAllowances:
                let request = try require(params, as: DaemonAPI.ApplyAllowances.self)
                return .success(try JSONValue.encoding(applyAllowances(request.states)))

            case DaemonAPI.Method.costSetLimits:
                let request = try require(params, as: DaemonAPI.SetLimitsRequest.self)
                return .success(try JSONValue.encoding(try await setLimits(request)))

            case DaemonAPI.Method.agentsSuggestPrompts:
                let request = try require(params, as: DaemonAPI.SuggestPromptsRequest.self)
                return .success(["note": .string(try await suggestPrompts(request))])

            case DaemonAPI.Method.agentsShowFile:
                let request = try require(params, as: DaemonAPI.ShowFileRequest.self)
                return .success(["note": .string(try await showFile(request))])

            case DaemonAPI.Method.agentsAskForm:
                let request = try require(params, as: DaemonAPI.AskFormRequest.self)
                return .success(["note": .string(try await askForm(request))])

            case DaemonAPI.Method.artifactWrite:
                let request = try require(params, as: DaemonAPI.ArtifactWriteRequest.self)
                try await artifactWrite(request)
                return .success([:])

            case DaemonAPI.Method.agentsManageWorkflows:
                let request = try require(params, as: DaemonAPI.ManageWorkflowsRequest.self)
                return .success(["note": .string(try await manageWorkflows(request))])

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

            case DaemonAPI.Method.pinsPinPage:
                let request = try require(params, as: DaemonAPI.PinToolRequest.self)
                return .success(["note": .string(try pinPage(request))])

            case DaemonAPI.Method.pinsUnpinPage:
                let request = try require(params, as: DaemonAPI.PinToolRequest.self)
                return .success(["note": .string(try unpinPage(request))])

            case DaemonAPI.Method.pinsMovePin:
                let request = try require(params, as: DaemonAPI.PinToolRequest.self)
                return .success(["note": .string(try movePin(request))])

            case DaemonAPI.Method.pinsList:
                return .success(try JSONValue.encoding(pinsList()))

            case DaemonAPI.Method.pinsPin:
                let request = try require(params, as: DaemonAPI.PinRequest.self)
                return .success(try JSONValue.encoding(try pinByPerson(request)))

            case DaemonAPI.Method.pinsUnpin:
                let request = try require(params, as: DaemonAPI.PinPathRequest.self)
                try unpinByPerson(request)
                return .success([:])

            case DaemonAPI.Method.pinsArrange:
                let request = try require(params, as: DaemonAPI.PinArrangeRequest.self)
                try arrangePins(request)
                return .success([:])

            case DaemonAPI.Method.pinsPinSessionTool:
                let request = try require(params, as: DaemonAPI.PinToolRequest.self)
                return .success(["note": .string(try pinSessionTool(request))])

            case DaemonAPI.Method.pinsPinSession:
                let request = try require(params, as: DaemonAPI.PinSessionRequest.self)
                try pinSessionByPerson(request)
                return .success([:])

            case DaemonAPI.Method.pinsUnpinSession:
                let request = try require(params, as: DaemonAPI.PinSessionRequest.self)
                try unpinSessionByPerson(request)
                return .success([:])

            case DaemonAPI.Method.pinsPinWorkflow:
                let request = try require(params, as: DaemonAPI.WorkflowRequest.self)
                try pinWorkflowByPerson(request)
                return .success([:])

            case DaemonAPI.Method.pinsUnpinWorkflow:
                let request = try require(params, as: DaemonAPI.WorkflowRequest.self)
                try unpinWorkflowByPerson(request)
                return .success([:])

            case DaemonAPI.Method.pinsArrangeWorkflows:
                let request = try require(params, as: DaemonAPI.PinArrangeWorkflowsRequest.self)
                try arrangeWorkflowPins(request)
                return .success([:])

            case DaemonAPI.Method.pinsArrangeSessions:
                let request = try require(params, as: DaemonAPI.PinArrangeSessionsRequest.self)
                try arrangeSessionPins(request)
                return .success([:])

            case DaemonAPI.Method.viewsToolCall:
                let request = try require(params, as: DaemonAPI.ViewToolCallRequest.self)
                return .success(try await viewToolCall(request))

            case DaemonAPI.Method.viewsRead:
                let request = try require(params, as: DaemonAPI.ViewReadRequest.self)
                return .success(try JSONValue.encoding(try await readView(request)))

            case DaemonAPI.Method.viewsCall:
                let request = try require(params, as: DaemonAPI.ViewCallRequest.self)
                return .success(try await callFromView(request))

            case DaemonAPI.Method.viewsLog:
                let request = try require(params, as: DaemonAPI.ViewLogRequest.self)
                logFromView(request)
                return .success([:])

            case DaemonAPI.Method.viewsContext:
                let request = try require(params, as: DaemonAPI.ViewContextRequest.self)
                try keepViewContext(request)
                return .success([:])

            case DaemonAPI.Method.viewsShow:
                let request = try require(params, as: DaemonAPI.ViewShowRequest.self)
                try answerViewShow(request)
                return .success([:])

            case DaemonAPI.Method.pinsRead:
                let request = try require(params, as: DaemonAPI.PinReadRequest.self)
                return .success(try JSONValue.encoding(try readPage(request)))

            case DaemonAPI.Method.pinsWrite:
                let request = try require(params, as: DaemonAPI.PinWriteRequest.self)
                try writePage(request)
                return .success([:])

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

            case DaemonAPI.Method.resourcesDeclare:
                let request = try require(params, as: DaemonAPI.DeclareResourceRequest.self)
                return .success(try JSONValue.encoding(try await declareResource(request)))

            case DaemonAPI.Method.resourcesRemove:
                let request = try require(params, as: DaemonAPI.RemoveResourceRequest.self)
                return .success(try JSONValue.encoding(try await removeDeclaredResource(request)))

            case DaemonAPI.Method.agentsStartHelper:
                let request = try require(params, as: DaemonAPI.StartHelperRequest.self)
                let started = try await startHelper(request)
                return .success(["note": .string(started.note),
                                 "agentID": .string(started.agentID.uuidString)])

            case DaemonAPI.Method.agentsMoveSelf:
                let request = try require(params, as: DaemonAPI.MoveSelfRequest.self)
                return .success(["note": .string(try await moveSelf(request).message)])

            case DaemonAPI.Method.agentsMove:
                let request = try require(params, as: DaemonAPI.MoveRequest.self)
                return .success(try JSONValue.encoding(try await move(request)))

            case DaemonAPI.Method.agentsStopHelper:
                let request = try require(params, as: DaemonAPI.HelperRequest.self)
                return .success(["note": .string(try await stopHelper(request))])

            case DaemonAPI.Method.agentsRequestArchiveHelper:
                let request = try require(params, as: DaemonAPI.HelperRequest.self)
                return .success(["note": .string(try await requestArchiveHelper(request))])

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

            case DaemonAPI.Method.agentsListHelpers:
                let request = try require(params, as: DaemonAPI.ListHelpersRequest.self)
                return .success(["note": .string(try listHelpers(request))])

            case DaemonAPI.Method.agentsListSessions:
                let request = try require(params, as: DaemonAPI.ListSessionsRequest.self)
                return .success(["note": .string(try await listSessions(request))])

            case DaemonAPI.Method.agentsReadSession:
                let request = try require(params, as: DaemonAPI.ReadSessionRequest.self)
                return .success(["note": .string(try await readSession(request))])

            case DaemonAPI.Method.agentsMessageAgent:
                let request = try require(params, as: DaemonAPI.MessageAgentRequest.self)
                return .success(["note": .string(try await messageAgent(request))])

            case DaemonAPI.Method.agentsReportOutcome:
                let request = try require(params, as: DaemonAPI.ReportOutcomeRequest.self)
                return .success(["note": .string(try await reportOutcome(request))])

            case DaemonAPI.Method.agentsFinishTurn:
                let request = try require(params, as: DaemonAPI.FinishTurnRequest.self)
                return .success(["note": .string(try await finishTurn(request))])

            case DaemonAPI.Method.agentsAfterTurn:
                let request = try require(params, as: DaemonAPI.AfterTurnRequest.self)
                return .success(["note": .string(try askAfterTurn(request))])

            case DaemonAPI.Method.agentsSetOwnLabels:
                let request = try require(params, as: DaemonAPI.OwnLabelsRequest.self)
                return .success(["note": .string(try setSessionLabels(request))])

            case DaemonAPI.Method.agentsWaitOn:
                let request = try require(params, as: DaemonAPI.WaitOnRequest.self)
                return .success(["note": .string(try await waitOn(request))])

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
                let request = try require(params, as: DaemonAPI.ShellRequest.self)
                detachShell(request, connection: connection)
                return .success([:])

            case DaemonAPI.Method.shellList:
                let request = try require(params, as: DaemonAPI.AgentRequest.self)
                return .success(try JSONValue.encoding(listShells(request.agentID)))

            case DaemonAPI.Method.shellClose:
                let request = try require(params, as: DaemonAPI.ShellRequest.self)
                closeShell(request)
                return .success([:])

            case DaemonAPI.Method.shellInput:
                let request = try require(params, as: DaemonAPI.ShellInputRequest.self)
                try writeToShell(request, from: surface)
                return .success([:])

            case DaemonAPI.Method.shellResize:
                let request = try require(params, as: DaemonAPI.ShellResizeRequest.self)
                resizeShell(request, from: surface)
                return .success([:])

            case DaemonAPI.Method.shellOpen:
                let request = try require(params, as: DaemonAPI.ShellAttachRequest.self)
                return .success(try JSONValue.encoding(try openShell(request)))

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
            // A full disk or a refused folder reads as words, not `NSCocoaErrorDomain
            // Code=640` (#88). The paths that know what they were keeping say so first.
            if let failure = WriteFailure(error, keeping: "that") { return .failure(Self.refusal(failure)) }
            return .failure(.internalError(String(describing: error)))
        }
    }

    private func decode<T: Decodable>(_ params: JSONValue?, as type: T.Type) throws -> T? {
        guard let params, !params.isNull else { return nil }
        do {
            return try params.decode(T.self)
        } catch let error as DecodingError {
            // A limit of 1.5 or "ten" is the caller's mistake, said as one (#200).
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: Self.words(error, for: type))
        }
    }

    /// Which field of a request would not read, and why, in a line.
    static func words<T>(_ error: DecodingError, for type: T.Type) -> String {
        let (path, why): ([any CodingKey], String) = switch error {
        case .typeMismatch(let expected, let context):
            (context.codingPath, expected == Int.self ? "is not a whole number" : "is not a \(expected)")
        case .valueNotFound(_, let context): (context.codingPath, "is missing")
        case .keyNotFound(let key, let context): (context.codingPath + [key], "is missing")
        case .dataCorrupted(let context): (context.codingPath, "does not read: " + context.debugDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        @unknown default: ([], "does not read")
        }
        let field = path.map(\.stringValue).joined(separator: ".")
        return field.isEmpty ? "\(type) \(why)." : "\(type): \(field) \(why)."
    }

    private func require<T: Decodable>(_ params: JSONValue?, as type: T.Type) throws -> T {
        guard let decoded = try decode(params, as: type) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "\(type) expected")
        }
        return decoded
    }
}
