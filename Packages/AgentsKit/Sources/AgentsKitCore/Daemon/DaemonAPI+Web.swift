import Foundation

/// What the web remote calls and hears (071, research R6, data-model.md "WebSignatures").
///
/// Nothing else in Swift ties a method to its params and result, so this table does, for the
/// methods the web remote uses and no others. It is plain Swift, so a renamed or deleted type
/// breaks the build here. The methods tagged `web` in Packages/Wire's OpenRPC documents, which
/// the web remote's TypeScript is made from, are these rows (`WireSchemaTests`).
/// `WebSignaturesTests` keeps every host request to what a person's connection may ask, and
/// none of an agent's tools.
public extension DaemonAPI {
    /// A result that is an empty object.
    struct Empty: Codable, Sendable, Hashable {
        public init() {}
    }

    enum WebSignatures {
        public enum Kind: Sendable {
            /// Sent to a host, with `h`.
            case hostRequest
            /// Answered by the control plane itself, with no `h`.
            case controlRequest
            case hostNotification
            case controlNotification
        }

        public struct Row {
            public let method: String
            public let params: Any.Type
            public let result: Any.Type
            public let kind: Kind

            public init(_ method: String, params: Any.Type, result: Any.Type, kind: Kind) {
                self.method = method
                self.params = params
                self.result = result
                self.kind = kind
            }
        }

        /// One row per method or notification. An ad-hoc dictionary result is `JSONValue`;
        /// an empty object is `Empty`.
        public static var rows: [Row] {
            [
                Row(Method.agentConfigEditorFiles, params: AgentConfigEditorRequest.self,
                    result: [AgentConfigEditorFile].self, kind: .hostRequest),
                Row(Method.agentConfigEditorSave, params: AgentConfigEditorSaveRequest.self,
                    result: Empty.self, kind: .hostRequest),
                // Reading
                Row(Method.foldersList, params: FoldersListRequest.self, result: [FolderSummary].self, kind: .hostRequest),
                Row(Method.agentsList, params: ListRequest.self, result: [Agent].self, kind: .hostRequest),
                Row(Method.agentsTranscript, params: TranscriptRequest.self, result: TranscriptPage.self, kind: .hostRequest),
                Row(Method.agentsTouchedPaths, params: AgentRequest.self, result: [String].self, kind: .hostRequest),
                Row(Method.agentsTurns, params: TurnsRequest.self, result: TurnsPage.self, kind: .hostRequest),
                Row(Method.agentsOptions, params: OptionsRequest.self, result: OptionsResponse.self, kind: .hostRequest),
                Row(Method.agentsDiscardDraft, params: DiscardDraftRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.runtimesList, params: Empty.self, result: [RuntimeStatus].self, kind: .hostRequest),
                Row(Method.runtimesAllowances, params: Optional<String>.self, result: RuntimeAllowances.self, kind: .hostRequest),
                Row(Method.runtimesAccounts, params: Empty.self, result: [RuntimeAccount].self, kind: .hostRequest),
                // The accounts added to a runtime (#840), for the account picker and the Runtimes page.
                Row(Method.runtimesAccountProfiles, params: Empty.self, result: [AccountProfile].self, kind: .hostRequest),
                // Each runtime's sandbox default, for the new session's "Use runtime default (…)" (#257).
                Row(Method.sandboxState, params: Empty.self, result: SandboxSettings.self, kind: .hostRequest),
                // Auto (#2658): the order and cells, what it would pick now.
                Row(Method.autoState, params: Empty.self, result: AutoSettings.self, kind: .hostRequest),
                Row(Method.autoSet, params: AutoSettings.self, result: AutoSettings.self, kind: .hostRequest),
                Row(Method.autoMappings, params: Empty.self, result: AutoMappings.self, kind: .hostRequest),
                Row(Method.autoPreview, params: AutoPreviewRequest.self, result: AutoPreview.self, kind: .hostRequest),
                // The Mac-wide permission choices shown under Cursor, Grok and OpenCode.
                Row(Method.clientPermissionsState, params: Empty.self, result: ClientPermissionSettings.self,
                    kind: .hostRequest),
                Row(Method.clientPermissionsSet, params: ClientPermissionSettings.self, result: ClientPermissionSettings.self,
                    kind: .hostRequest),
                // The organisation's policy as the host follows it, for the red strip and the
                // composer, and the person's pass-through names, marked (#998).
                Row(Method.daemonPolicyState, params: Empty.self, result: PolicyState.self, kind: .hostRequest),
                Row(Method.settingsPassThrough, params: Empty.self, result: PassThroughState.self, kind: .hostRequest),
                Row(Method.optionsRemembered, params: RememberedOptionsRequest.self, result: [ConfigOption].self,
                    kind: .hostRequest),
                Row(Method.modesRemembered, params: Empty.self, result: RememberedModes.self, kind: .hostRequest),
                Row(Method.preferencesGet, params: Empty.self, result: DisplayPreferences.self, kind: .hostRequest),
                Row(Method.preferencesSet, params: DisplayPreferences.self, result: DisplayPreferences.self,
                    kind: .hostRequest),
                Row(Method.permissionsPending, params: Empty.self, result: [PermissionRequest].self, kind: .hostRequest),
                Row(Method.elicitationsPending, params: Empty.self, result: [ElicitationRequest].self, kind: .hostRequest),
                Row(Method.attentionPending, params: Empty.self, result: AttentionPending.self, kind: .hostRequest),
                // Which chats the host is bringing back after a restart, for Coming back (#251).
                Row(Method.agentsResuming, params: Empty.self, result: ResumingResponse.self, kind: .hostRequest),
                Row(Method.worktreesList, params: WorktreesListRequest.self, result: WorktreesListResponse.self,
                    kind: .hostRequest),
                // Activity ▸ Worktrees (#790): every folder's, with sizes; Remove build output and Remove….
                Row(Method.worktreesAll, params: Empty.self, result: [FolderWorktrees].self, kind: .hostRequest),
                Row(Method.worktreesRemoveBuildOutput, params: WorktreeRemovalRequest.self, result: BuildOutputRemoved.self,
                    kind: .hostRequest),
                Row(Method.worktreesCheck, params: WorktreeRemovalRequest.self, result: RemovalCheck.self, kind: .hostRequest),
                Row(Method.worktreesRemove, params: WorktreeRemovalRequest.self, result: WorktreeRemoved.self,
                    kind: .hostRequest),
                Row(Method.workflowsList, params: WorkflowsListRequest.self, result: [WorkflowSummary].self, kind: .hostRequest),
                Row(Method.workflowsWrite, params: WorkflowWriteRequest.self, result: WorkflowSummary.self, kind: .hostRequest),
                Row(Method.personasList, params: PersonasListRequest.self, result: [Persona].self, kind: .hostRequest),
                Row(Method.personasFiles, params: PersonasFilesRequest.self, result: [PersonaFile].self, kind: .hostRequest),
                Row(Method.personasSave, params: PersonaFileSaveRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.filesList, params: FilesListRequest.self, result: DirectoryListing.self, kind: .hostRequest),
                Row(Method.filesRead, params: FilesReadRequest.self, result: FileReading.self, kind: .hostRequest),
                Row(Method.changesList, params: ChangesListRequest.self, result: ChangesList.self, kind: .hostRequest),
                Row(Method.changesFile, params: ChangesFileRequest.self, result: ChangedFileDetail.self, kind: .hostRequest),
                Row(Method.agentsLabelVocabulary, params: LabelVocabularyRequest.self, result: [String].self,
                    kind: .hostRequest),
                Row(Method.costState, params: Empty.self, result: CostState.self, kind: .hostRequest),
                // The usage charts on Cost (#823).
                Row(Method.usageHistory, params: Empty.self, result: UsageHistory.self, kind: .hostRequest),
                // The Time page (#852).
                Row(Method.timeHistory, params: Empty.self, result: TimeHistory.self, kind: .hostRequest),
                // The Time page's milestones (#984).
                Row(Method.milestonesState, params: Empty.self, result: Milestones.self, kind: .hostRequest),
                Row(Method.eventsList, params: EventsListRequest.self, result: EventsPage.self, kind: .hostRequest),
                Row(Method.resourcesSnapshot, params: Empty.self, result: LeaseSnapshot.self, kind: .hostRequest),
                // The MCP servers the host runs for every agent (#488), for the Resources page.
                Row(Method.mcpHosted, params: Empty.self, result: HostedMCPSnapshot.self, kind: .hostRequest),
                // Every MCP server's health (#753), for the MCP Servers pages, and Check Now.
                Row(Method.mcpHealth, params: Empty.self, result: MCPHealthSnapshot.self, kind: .hostRequest),
                Row(Method.mcpHealthCheck, params: MCPHealthCheckRequest.self, result: MCPHealthSnapshot.self,
                    kind: .hostRequest),
                // Remove… on a Connectors page (#2154).
                Row(Method.mcpRemove, params: MCPRemoveRequest.self, result: MCPRemoveAnswer.self, kind: .hostRequest),
                // The person's connections (#1335) and a folder's Connectors set-up (#1336).
                Row(Method.connectionsList, params: Empty.self, result: ConnectionsList.self, kind: .hostRequest),
                Row(Method.connectionsSignIn, params: ConnectionProviderRequest.self, result: ConnectionSignIn.self,
                    kind: .hostRequest),
                Row(Method.connectionsSignInWait, params: ConnectionSignInFlowRequest.self, result: ConnectionSignIn.self,
                    kind: .hostRequest),
                Row(Method.connectionsSignInCancel, params: ConnectionSignInFlowRequest.self, result: ConnectionSignIn.self,
                    kind: .hostRequest),
                Row(Method.connectionsSignInComplete, params: ConnectionSignInCompleteRequest.self,
                    result: ConnectionSignIn.self, kind: .hostRequest),
                Row(Method.connectionsSignInToken, params: ConnectionTokenRequest.self,
                    result: ConnectionTokenAnswer.self, kind: .hostRequest),
                Row(Method.connectionsSignInEmail, params: ConnectionEmailRequest.self,
                    result: ConnectionTokenAnswer.self, kind: .hostRequest),
                Row(Method.connectionsDisconnect, params: ConnectionProviderRequest.self,
                    result: ConnectionDisconnectAnswer.self, kind: .hostRequest),
                Row(Method.connectorsCodespaces, params: ConnectorCodespacesRequest.self, result: ConnectorCodespaces.self,
                    kind: .hostRequest),
                Row(Method.connectorsSetup, params: ConnectorSetupRequest.self, result: ConnectorSetup.self, kind: .hostRequest),
                Row(Method.connectorsSetupSkip, params: ConnectorSkipRequest.self, result: ConnectorSetup.self,
                    kind: .hostRequest),
                // The low disk space strip (#195, #196), as the window draws it.
                Row(Method.diskState, params: Empty.self, result: DiskState.self, kind: .hostRequest),
                // Backups of the machine, in Settings (#1810).
                Row(Method.backupsState, params: Empty.self, result: BackupState.self, kind: .hostRequest),
                Row(Method.backupsConfigure, params: BackupSettings.self, result: BackupState.self, kind: .hostRequest),
                Row(Method.backupsMake, params: BackupMakeRequest.self, result: BackupState.self, kind: .hostRequest),
                Row(Method.backupsRestore, params: BackupRestoreRequest.self, result: BackupRestoreResult.self,
                    kind: .hostRequest),
                // Export and import of an agent or a folder (#1001).
                Row(Method.agentsExport, params: AgentsExportRequest.self, result: AgentsExport.self, kind: .hostRequest),
                Row(Method.agentsExportRead, params: SendReadRequest.self, result: SendRead.self, kind: .hostRequest),
                Row(Method.agentsImportUpload, params: ReceiveUploadRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsImport, params: AgentsImportRequest.self, result: BackupRestoreResult.self,
                    kind: .hostRequest),
                // The files the host could not read in this run (#205, #223), as the window's sidebar foot.
                Row(Method.storeNotes, params: Empty.self, result: StoreNotes.self, kind: .hostRequest),
                // Pinned pages (#159): the sidebar's rows and the pages themselves.
                Row(Method.pinsList, params: Empty.self, result: [FolderPins].self, kind: .hostRequest),
                Row(Method.pinsRead, params: PinReadRequest.self, result: FileReading.self, kind: .hostRequest),
                // A view drawn in the chat (#187): its resource, and what it asks of its server.
                Row(Method.viewsRead, params: ViewReadRequest.self, result: ViewResource.self, kind: .hostRequest),
                Row(Method.viewsCall, params: ViewCallRequest.self, result: JSONValue.self, kind: .hostRequest),
                Row(Method.viewsLog, params: ViewLogRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.viewsContext, params: ViewContextRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.viewsShow, params: ViewShowRequest.self, result: Empty.self, kind: .hostRequest),
                // Acting
                Row(Method.agentsStart, params: StartRequest.self, result: UUID.self, kind: .hostRequest),
                // A server's key ask (#344): the pasted key, offered and lent on this browser's
                // own connection, then the start again, as the window's TokenAskCard does.
                Row(Method.credentialsOffer, params: CredentialsOffer.self, result: Empty.self, kind: .hostRequest),
                Row(Method.credentialsLend, params: CredentialsLend.self, result: Empty.self, kind: .hostRequest),
                Row(Method.runtimesMarkAvailable, params: MarkRuntimeAvailable.self, result: RuntimeAllowances.self,
                    kind: .hostRequest),
                Row(Method.runtimesAddAccount, params: AddAccountRequest.self, result: AccountProfile.self, kind: .hostRequest),
                Row(Method.runtimesRemoveAccount, params: AccountRequest.self, result: [UUID].self, kind: .hostRequest),
                // Reaches the Model By (#999), on the runtime's row.
                Row(Method.runtimesSetDefaultAccount, params: DefaultAccountRequest.self, result: Empty.self,
                    kind: .hostRequest),
                Row(Method.agentsPrompt, params: PromptRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsSendNow, params: UnqueueRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsUnqueue, params: UnqueueRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsEditQueued, params: EditQueuedRequest.self, result: EditQueuedResult.self,
                    kind: .hostRequest),
                Row(Method.agentsFind, params: FindRequest.self, result: FindResult.self, kind: .hostRequest),
                Row(Method.agentsSaid, params: SaidSearchRequest.self, result: SaidSearchResult.self, kind: .hostRequest),
                Row(Method.filesDiagnostics, params: FileDiagnosticsRequest.self, result: FileDiagnostics.self,
                    kind: .hostRequest),
                Row(Method.filesComplete, params: FileCompletionRequest.self, result: FileCompletions.self,
                    kind: .hostRequest),
                Row(Method.simulatorsList, params: Empty.self, result: SimulatorList.self, kind: .hostRequest),
                Row(Method.simulatorsBoot, params: SimulatorRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.simulatorsShutdown, params: SimulatorRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.simulatorsScreen, params: SimulatorScreenRequest.self, result: SimulatorScreen.self,
                    kind: .hostRequest),
                Row(Method.simulatorsTap, params: SimulatorTapRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.simulatorsHome, params: SimulatorRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsStop, params: AgentStopRequest.self, result: Empty.self, kind: .hostRequest),
                // Events ▸ Waiting now's ✕, as the window and the Remote have it (#541).
                Row(Method.eventsCancelWait, params: CancelWaitRequest.self, result: [WaitingAgent].self,
                    kind: .hostRequest),
                Row(Method.agentsStopBackground, params: StopBackgroundRequest.self, result: JSONValue.self, kind: .hostRequest),
                Row(Method.agentsArchive, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsDelete, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                // The ways on from a missing folder (#119), as the window's header has them.
                Row(Method.agentsContinueInFolder, params: ContinueInFolderRequest.self, result: UUID.self,
                    kind: .hostRequest),
                // Continue in New (#999): a session whose account the organisation removed or refuses.
                Row(Method.agentsContinueInNew, params: ContinueInNewRequest.self, result: UUID.self, kind: .hostRequest),
                Row(Method.agentsRecreateWorktree, params: AgentRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsContinueWhenBack, params: AgentRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsCancelContinue, params: AgentRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetUnread, params: SetUnreadRequest.self, result: Empty.self, kind: .hostRequest),
                // Mute Notifications (#2003), as the window's and the Remote's menus have it.
                Row(Method.agentsSetMuted, params: SetMutedRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsRename, params: RenameRequest.self, result: Agent.self, kind: .hostRequest),
                // Branch (#342): the new session's id, as the window's row and Session menu have it.
                Row(Method.agentsFork, params: AgentRequest.self, result: UUID.self, kind: .hostRequest),
                // Branch from here (#1658), from a prompt's menu and the Prompts list.
                Row(Method.agentsBranchFrom, params: BranchFromRequest.self, result: UUID.self, kind: .hostRequest),
                Row(Method.agentsPrewarm, params: PrewarmRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsUnarchive, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsSetLabels, params: SetLabelsRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetCeiling, params: SetCeilingRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetSandbox, params: SetSandboxRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetLevels, params: SetLevelsRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetClientPermission, params: SetClientPermissionRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetOption, params: SetOptionRequest.self, result: [ConfigOption].self, kind: .hostRequest),
                Row(Method.permissionsAnswer, params: AnswerRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.elicitationsAnswer, params: AnswerElicitationRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsAnswerSandbox, params: AnswerSandboxRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.workflowsRun, params: WorkflowRequest.self, result: WorkflowSummary.self, kind: .hostRequest),
                // A file put into a folder's drop box (#231), as the window's drag and the Remote's pick.
                Row(Method.dropboxPut, params: DropboxPutRequest.self, result: DropboxPutResponse.self,
                    kind: .hostRequest),
                // Pin, Unpin, a drop, and typing on a pinned page (#159), from every client alike.
                Row(Method.pinsPin, params: PinRequest.self, result: [PinView].self, kind: .hostRequest),
                Row(Method.pinsUnpin, params: PinPathRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsArrange, params: PinArrangeRequest.self, result: Empty.self, kind: .hostRequest),
                // Hide and Show on a server's list view (#2032).
                Row(Method.pinsHideView, params: PinHideViewRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsWrite, params: PinWriteRequest.self, result: Empty.self, kind: .hostRequest),
                // Pin, Unpin and a drop among pinned sessions (#180), from every client alike.
                Row(Method.pinsPinSession, params: PinSessionRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsUnpinSession, params: PinSessionRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsArrangeSessions, params: PinArrangeSessionsRequest.self, result: Empty.self,
                    kind: .hostRequest),
                // And on a workflow (#432).
                Row(Method.pinsPinWorkflow, params: WorkflowRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsUnpinWorkflow, params: WorkflowRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsArrangeWorkflows, params: PinArrangeWorkflowsRequest.self, result: Empty.self,
                    kind: .hostRequest),
                // Turn Off / Turn On (#100), as the window's and the Remote's rows have it.
                Row(Method.workflowsEnable, params: WorkflowEnableRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                Row(Method.workflowsSetMuted, params: WorkflowMuteRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                // Approve, and Archive or Unarchive, on the workflow page (#142), as the window's has them.
                Row(Method.workflowsApprove, params: WorkflowApproveRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                // Deny on this host (#391), beside Approve.
                Row(Method.workflowsDeny, params: WorkflowApproveRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                Row(Method.workflowsArchive, params: WorkflowArchiveRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                Row(Method.workflowsDelete, params: WorkflowRequest.self, result: Empty.self, kind: .hostRequest),
                // Its settings, labels and cooldown on the page (#162), each control its one key.
                Row(Method.workflowsSettings, params: WorkflowSettingsRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                // Clear on a server's event trigger's missed-events line (#383).
                Row(Method.workflowsClearMCPMissed, params: WorkflowMCPClearMissedRequest.self,
                    result: WorkflowSummary.self, kind: .hostRequest),
                // New folder (#115): Add Folder…, browsing the host's folders, and Clone Git URL…,
                // as the window's folders column has them.
                Row(Method.filesBrowse, params: FilesBrowseRequest.self, result: DirectoryListing.self, kind: .hostRequest),
                Row(Method.foldersAdd, params: AddFolderRequest.self, result: FolderSummary.self, kind: .hostRequest),
                Row(Method.foldersClone, params: CloneRequest.self, result: FolderSummary.self, kind: .hostRequest),
                Row(Method.foldersClones, params: Empty.self, result: [CloneSummary].self, kind: .hostRequest),
                // Archive… on a folder's menu (#668), as the window's folder menu has it.
                Row(Method.foldersArchive, params: FolderRequest.self, result: FolderSummary.self, kind: .hostRequest),
                // Unarchive in the Archived folders fold (#343), as the window's sidebar has it.
                Row(Method.foldersUnarchive, params: FolderRequest.self, result: FolderSummary.self, kind: .hostRequest),
                // Delete… on an archived folder (#677).
                Row(Method.foldersDelete, params: FolderRequest.self, result: Empty.self, kind: .hostRequest),
                // Pin and Unpin on a folder's row, as the window's sidebar has them.
                Row(Method.foldersSetPinned, params: SetPinnedRequest.self, result: FolderSummary.self, kind: .hostRequest),
                // A folder joins a project (#2317).
                Row(Method.foldersSetProject, params: SetFolderProjectRequest.self, result: FolderSummary.self,
                    kind: .hostRequest),
                // A change to the folder's own files made outside the app (#531): read, Keep, Undo.
                Row(Method.foldersReadGuardedChange, params: GuardedChangeRequest.self, result: GuardedChangeReading.self,
                    kind: .hostRequest),
                Row(Method.foldersKeepGuardedChange, params: GuardedChangeRequest.self, result: FolderSummary.self,
                    kind: .hostRequest),
                Row(Method.foldersUndoGuardedChange, params: GuardedChangeRequest.self, result: FolderSummary.self,
                    kind: .hostRequest),
                // Everything in Needs You waiting for an OK (#773): read it, then Approve, Deny or Request changes.
                Row(Method.approvalsRead, params: ApprovalReadRequest.self, result: GuardedChangeReading.self,
                    kind: .hostRequest),
                Row(Method.approvalsAnswer, params: ApprovalAnswer.self, result: FolderSummary.self, kind: .hostRequest),
                Row(Method.filesWatch, params: FilesWatchRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.filesUnwatch, params: FilesWatchRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.artifactWrite, params: ArtifactWriteRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.filesMention, params: FileMentionRequest.self, result: [FileMentionDTO].self, kind: .hostRequest),
                Row(Method.presenceReport, params: PresenceReport.self, result: Empty.self, kind: .hostRequest),
                Row(Method.surfaceIdentify, params: SurfaceIdentification.self, result: Empty.self, kind: .hostRequest),
                // The control plane's own
                Row(Method.controlStatus, params: Empty.self, result: ControlStatus.self, kind: .controlRequest),
                Row(Method.hostsList, params: Empty.self, result: [ControlMachine].self, kind: .controlRequest),
                Row(Method.clientsForgetSelf, params: Empty.self, result: Empty.self, kind: .controlRequest),
                // A host using a Mac's git access (#1122): Allow, Don't Allow and Revoke.
                Row(Method.hostsLendGit, params: LendGit.self, result: Empty.self, kind: .controlRequest),
                // A linked host's workspace (#691): Start on the offline strip.
                Row(Method.hostsStart, params: MachineRequest.self, result: ControlMachine.self, kind: .controlRequest),
                Row(Method.hostsStop, params: MachineStop.self, result: ControlMachine.self, kind: .controlRequest),
                // Settings ▸ Machine providers (#1808): the API providers, and a workspace's host
                // linked and unlinked.
                Row(Method.providersList, params: Empty.self, result: JSONValue.self, kind: .controlRequest),
                Row(Method.providersAdd, params: ProviderAdd.self, result: ProviderSummary.self, kind: .controlRequest),
                Row(Method.providersUpdate, params: ProviderAdd.self, result: ProviderSummary.self, kind: .controlRequest),
                Row(Method.providersRemove, params: ProviderRequest.self, result: Empty.self, kind: .controlRequest),
                Row(Method.providersRefresh, params: ProviderRequest.self, result: Empty.self, kind: .controlRequest),
                Row(Method.hostsLink, params: MachineLink.self, result: ControlMachine.self, kind: .controlRequest),
                Row(Method.hostsUnlink, params: MachineRequest.self, result: ControlMachine.self, kind: .controlRequest),
                Row(Method.hostsSetMachineOptions, params: MachineOptions.self, result: ControlMachine.self,
                    kind: .controlRequest),
                // Start a Machine from a Repository (#1809): the provider's form, then the machine.
                Row(Method.providersOptions, params: ProviderRequest.self, result: ProviderOptions.self, kind: .controlRequest),
                Row(Method.providersCreate, params: ProviderCreate.self, result: ProviderCreated.self, kind: .controlRequest),
                // Prompts and starts kept for a stopped workspace (#691 US3).
                Row(Method.hostsListKept, params: Empty.self, result: KeptList.self, kind: .controlRequest),
                Row(Method.hostsDropKept, params: KeptRequestID.self, result: Empty.self, kind: .controlRequest),
                Row(Method.hostsRetryKept, params: KeptRequestID.self, result: Empty.self, kind: .controlRequest),
                // What an offline host last listed (#962).
                Row(Method.hostsLastHeard, params: MachineRequest.self, result: MachineLastHeard.self, kind: .controlRequest),
                // Who did what (#996): Events ▸ Audit.
                Row(Method.auditList, params: AuditQuery.self, result: AuditList.self, kind: .controlRequest),
                Row(Method.auditExport, params: AuditQuery.self, result: AuditExport.self, kind: .controlRequest),
                Row(Method.controlSetAuditDays, params: AuditDays.self, result: AuditDays.self, kind: .controlRequest),
                // Where the audit is sent (#1001): Console ▸ Audit ▸ Sinks.
                Row(Method.auditSinks, params: Empty.self, result: AuditSinksState.self, kind: .controlRequest),
                Row(Method.auditSetSinks, params: AuditSinks.self, result: AuditSinksState.self, kind: .controlRequest),
                // Rotate Control Key… in Settings ▸ People (#997).
                Row(Method.controlRotate, params: Empty.self, result: Empty.self, kind: .controlRequest),
                // Reports (#1811): usage, cost and time by person, folder and machine.
                Row(Method.reportsUsage, params: ReportQuery.self, result: UsageReport.self, kind: .controlRequest),
                Row(Method.reportsExport, params: ReportQuery.self, result: ReportExport.self, kind: .controlRequest),
                // Reports ▸ Value (#2351).
                Row(Method.reportsValue, params: ReportQuery.self, result: ReportValue.self, kind: .controlRequest),
                Row(Method.reportsScopes, params: Empty.self, result: ReportScopes.self, kind: .controlRequest),
                Row(Method.reportsPolicy, params: Empty.self, result: ReportPolicy.self, kind: .controlRequest),
                Row(Method.reportsSetPolicy, params: ReportPolicy.self, result: ReportPolicy.self, kind: .controlRequest),
                // Saved views of Reports (#2019).
                Row(Method.reportsViews, params: Empty.self, result: ReportViews.self, kind: .controlRequest),
                Row(Method.reportsSaveView, params: ReportView.self, result: ReportViews.self, kind: .controlRequest),
                Row(Method.reportsDeleteView, params: ReportViewID.self, result: ReportViews.self, kind: .controlRequest),
                // The Console (#1804): the admins' app on the web page.
                Row(Method.consoleFleet, params: Empty.self, result: FleetBoard.self, kind: .controlRequest),
                Row(Method.consoleTeamWorkflows, params: Empty.self, result: TeamWorkflows.self, kind: .controlRequest),
                Row(Method.consoleLive, params: Empty.self, result: LiveBoard.self, kind: .controlRequest),
                Row(Method.consoleStopAgent, params: ConsoleStopAgent.self, result: Empty.self, kind: .controlRequest),
                // Console ▸ Sign-In and the SCIM groups' admin role (#1002, slice 4): the web page's only, so
                // no Swift types; the shapes are Packages/Wire's.
                Row("groups/setRole", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("people/removeRequests", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                // Catalogue governance (#2019, M5): a person's ask in Settings ▸ Policy, on all three
                // (#2335); the rest are the Console's and the web page's only, so no Swift types.
                Row(Method.governanceRequest, params: CatalogAsk.self, result: CatalogRequest.self, kind: .controlRequest),
                Row(Method.governanceRequests, params: Empty.self, result: CatalogRequestList.self, kind: .controlRequest),
                Row("governance/approvals", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("governance/decide", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("governance/revoke", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("governance/usage", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                // The read API's tokens and the OTLP exporter (#2019): the Console's only.
                Row("readApi/list", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("readApi/make", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("readApi/revoke", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("scim/set", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("scim/tokens/list", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("scim/tokens/make", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("scim/tokens/revoke", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/domains/check", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/domains/claim", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/domains/list", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/domains/preview", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/domains/remove", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/domains/set", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/orgProviders/check", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/orgProviders/list", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/orgProviders/remove", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                Row("signIn/orgProviders/set", params: JSONValue.self, result: JSONValue.self, kind: .controlRequest),
                // The organisation's policy (#998): Console ▸ Policy, and Settings ▸ Policy on every client.
                Row(Method.policyMine, params: Empty.self, result: PolicyView.self, kind: .controlRequest),
                Row(Method.policyGet, params: Empty.self, result: PolicyKept.self, kind: .controlRequest),
                Row(Method.policySet, params: PolicySet.self, result: PolicyKept.self, kind: .controlRequest),
                Row(Method.policyStopAll, params: PolicyStopAllRequest.self, result: PolicyKept.self, kind: .controlRequest),
                Row(Method.policyRaise, params: PolicyRaiseRequest.self, result: PolicyKept.self, kind: .controlRequest),
                // The organisation's ways to the model (#999): Console ▸ Model Access, and Settings ▸ Policy.
                Row(Method.orgRoutesMine, params: Empty.self, result: OrgRoutesMine.self, kind: .controlRequest),
                Row(Method.orgRoutesList, params: Empty.self, result: OrgRouteList.self, kind: .controlRequest),
                Row(Method.orgRoutesSet, params: OrgRouteSet.self, result: OrgRouteKept.self, kind: .controlRequest),
                Row(Method.orgRoutesReplaceKey, params: OrgRouteReplaceKey.self, result: OrgRouteKept.self, kind: .controlRequest),
                Row(Method.orgRoutesCheck, params: OrgRouteRequest.self, result: OrgRouteCheck.self, kind: .controlRequest),
                Row(Method.orgRoutesRemove, params: OrgRouteRequest.self, result: Empty.self, kind: .controlRequest),
                // The user scope (#1760): what follows the person to their machines, under You.
                Row(Method.userSettings, params: Empty.self, result: UserSettings.self, kind: .controlRequest),
                Row(Method.userSetSettings, params: UserSettingsPart.self, result: Empty.self, kind: .controlRequest),
                Row(Method.userSetSecret, params: UserSecret.self, result: Empty.self, kind: .controlRequest),
                Row(Method.userRemoveSecret, params: UserSecretRequest.self, result: Empty.self, kind: .controlRequest),
                Row(Method.userSecretNames, params: Empty.self, result: UserSecretNames.self, kind: .controlRequest),
                // People and the machines that belong to them (#994): Settings ▸ People.
                Row(Method.peopleList, params: Empty.self, result: PeopleList.self, kind: .controlRequest),
                Row(Method.peopleInvite, params: PersonInvite.self, result: PersonInvited.self, kind: .controlRequest),
                Row(Method.peopleSetRole, params: PersonRoleRequest.self, result: Empty.self, kind: .controlRequest),
                Row(Method.peopleRemove, params: PersonRequest.self, result: Empty.self, kind: .controlRequest),
                Row(Method.peopleRemovePreview, params: PersonRequest.self, result: PersonRemovePreview.self,
                    kind: .controlRequest),
                // Groups own machine providers (#1761): Settings ▸ Groups.
                Row(Method.groupsList, params: Empty.self, result: GroupList.self, kind: .controlRequest),
                Row(Method.groupsSet, params: GroupSet.self, result: Group.self, kind: .controlRequest),
                Row(Method.groupsRemove, params: GroupRequest.self, result: Empty.self, kind: .controlRequest),
                Row(Method.providersSetGroup, params: ProviderGroup.self, result: Empty.self, kind: .controlRequest),
                // Projects, the record that folders join (#2317): a folder's Project.
                Row(Method.projectsList, params: Empty.self, result: ProjectList.self, kind: .controlRequest),
                Row(Method.projectsSet, params: ProjectSet.self, result: Project.self, kind: .controlRequest),
                Row(Method.projectsSetSlot, params: ProjectSlotSet.self, result: Project.self, kind: .controlRequest),
                Row(Method.projectsRemove, params: ProjectRequest.self, result: Empty.self, kind: .controlRequest),
                // Bots run the team's workflows (#1761): in Settings ▸ People.
                Row(Method.botsMake, params: BotMake.self, result: BotMade.self, kind: .controlRequest),
                Row(Method.botsSetCaps, params: BotCaps.self, result: Empty.self, kind: .controlRequest),
                Row(Method.botsStopRun, params: BotStopRun.self, result: Empty.self, kind: .controlRequest),
                // A host code, the page's for a bot's machine (#1761).
                Row(Method.hostsStartEnroll, params: MachineEnroll.self, result: ControlCodeShown.self, kind: .controlRequest),
                // A machine that asks to join, approved on a card (#994).
                Row(Method.hostsJoinRequests, params: Empty.self, result: [JoinRequest].self, kind: .controlRequest),
                Row(Method.hostsApproveJoin, params: JoinRequestDecide.self, result: JoinApproved.self,
                    kind: .controlRequest),
                Row(Method.hostsDenyJoin, params: JoinRequestDecide.self, result: Empty.self, kind: .controlRequest),
                // A channel identity linked to a person on a card, and Control plane ▸ Channels (#1762).
                Row(Method.linksList, params: Empty.self, result: [ChannelLink].self, kind: .controlRequest),
                Row(Method.linksRequests, params: Empty.self, result: [ChannelLinkRequest].self, kind: .controlRequest),
                Row(Method.linksApprove, params: ChannelLinkDecide.self, result: Empty.self, kind: .controlRequest),
                Row(Method.linksDeny, params: ChannelLinkDecide.self, result: Empty.self, kind: .controlRequest),
                Row(Method.linksRemove, params: ChannelLinkRemove.self, result: Empty.self, kind: .controlRequest),
                // Sign-in providers, and a GitHub sign-in approved on a card (#995).
                Row(Method.signInProviders, params: Empty.self, result: SignInProviders.self, kind: .controlRequest),
                Row(Method.signInRemoveFromMe, params: SignInRemove.self, result: Empty.self, kind: .controlRequest),
                Row(Method.signInConfigure, params: SignInConfigure.self, result: SignInProviders.self, kind: .controlRequest),
                Row(Method.signInRequests, params: Empty.self, result: [SignInRequest].self, kind: .controlRequest),
                Row(Method.signInApprove, params: SignInDecide.self, result: Empty.self, kind: .controlRequest),
                Row(Method.signInDeny, params: SignInDecide.self, result: Empty.self, kind: .controlRequest),
                // Heard
                Row(Notification.agentChanged, params: Agent.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.clientPermissionsChanged, params: ClientPermissionSettings.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.autoChanged, params: AutoSettings.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.daemonPolicyStateChanged, params: PolicyState.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.runtimesAccountProfilesChanged, params: [AccountProfile].self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentEntry, params: EntryNotification.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.agentRemoved, params: AgentRemovedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentResuming, params: ResumingNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentPermission, params: PermissionNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentElicitation, params: ElicitationNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.folderChanged, params: FolderSummary.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.folderRemoved, params: FolderRemovedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.cloneChanged, params: CloneNotification.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.draftOptions, params: DraftOptionsNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.modesChanged, params: RememberedModes.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.preferencesChanged, params: DisplayPreferences.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.workflowChanged, params: WorkflowSummary.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.workflowRemoved, params: WorkflowRemovedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.attentionChanged, params: AttentionNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.filesChanged, params: FilesChangedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentShowFile, params: ShowFileNotification.self, result: Empty.self,
                    kind: .hostNotification),
                // A write nobody was waiting on that the host could not keep (#88).
                Row(Notification.writeFailed, params: WriteFailure.self, result: Empty.self, kind: .hostNotification),
                // Who holds what, for the page's read-only Resources list (#116).
                Row(Notification.resourcesChanged, params: LeaseSnapshot.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.mcpHostedChanged, params: HostedMCPSnapshot.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.mcpHealthChanged, params: MCPHealthSnapshot.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.diskChanged, params: DiskState.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.backupsChanged, params: BackupState.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.worktreesSized, params: WorktreesSized.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.milestonesChanged, params: Milestones.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.storeNotesChanged, params: StoreNotes.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.pinsChanged, params: PinsChangedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.pagesChanged, params: PagesChangedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                // An ad-hoc dictionary from ControlRouter.described: a `ControlMachine`'s state, and
                // its `workspace` (#691) when it is linked.
                Row(Notification.controlHostChanged, params: JSONValue.self, result: Empty.self, kind: .controlNotification),
                Row(Notification.controlKeptChanged, params: KeptList.self, result: Empty.self, kind: .controlNotification),
                Row(Notification.controlProvidersChanged, params: JSONValue.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlKeptDelivered, params: KeptDelivered.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlJoinRequested, params: JoinRequest.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlJoinDecided, params: JoinDecided.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlLinkRequested, params: ChannelLinkRequest.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlLinkDecided, params: ChannelLinkDecided.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlLinksChanged, params: Empty.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlSignInRequested, params: SignInRequest.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlSignInDecided, params: SignInDecided.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlGroupsChanged, params: GroupsChanged.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlProjectsChanged, params: ProjectsChanged.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlCapReached, params: CapReached.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlPeopleChanged, params: PeopleChanged.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlUserSettingsChanged, params: UserSettingsChanged.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlSecretsLeft, params: SecretsLeft.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlPolicyChanged, params: PolicyView.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlStopAll, params: PolicyView.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlOrgRoutesChanged, params: Empty.self, result: Empty.self,
                    kind: .controlNotification),
                Row(Notification.controlGovernanceRequested, params: CatalogRequest.self, result: Empty.self,
                    kind: .controlNotification),
            ]
        }
    }
}
