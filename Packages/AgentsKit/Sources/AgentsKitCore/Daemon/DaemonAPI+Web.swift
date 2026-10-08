import Foundation

/// What the web remote calls and hears (071, research R6, data-model.md "WebSignatures").
///
/// Nothing else in Swift ties a method to its params and result, so this table does, for the
/// methods the web remote uses and no others. It is plain Swift, so a renamed or deleted type
/// breaks the build here; Packages/WebTypes reads it as source and generates the web remote's
/// TypeScript from the types it names. `WebSignaturesTests` keeps every host request to what
/// a person's connection may ask, and none of an agent's tools.
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
                // Reading
                Row(Method.projectsList, params: ProjectsListRequest.self, result: [ProjectSummary].self, kind: .hostRequest),
                Row(Method.agentsList, params: ListRequest.self, result: [Agent].self, kind: .hostRequest),
                Row(Method.agentsTranscript, params: TranscriptRequest.self, result: TranscriptPage.self, kind: .hostRequest),
                Row(Method.agentsTouchedPaths, params: AgentRequest.self, result: [String].self, kind: .hostRequest),
                Row(Method.agentsTurns, params: TurnsRequest.self, result: TurnsPage.self, kind: .hostRequest),
                Row(Method.agentsOptions, params: OptionsRequest.self, result: OptionsResponse.self, kind: .hostRequest),
                Row(Method.agentsDiscardDraft, params: DiscardDraftRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.runtimesList, params: Empty.self, result: [RuntimeStatus].self, kind: .hostRequest),
                Row(Method.runtimesAllowances, params: Optional<String>.self, result: RuntimeAllowances.self, kind: .hostRequest),
                Row(Method.runtimesAccounts, params: Empty.self, result: [RuntimeAccount].self, kind: .hostRequest),
                // Each runtime's sandbox default, for the new session's "Use runtime default (…)" (#257).
                Row(Method.sandboxState, params: Empty.self, result: SandboxSettings.self, kind: .hostRequest),
                Row(Method.optionsRemembered, params: RememberedOptionsRequest.self, result: [ConfigOption].self,
                    kind: .hostRequest),
                Row(Method.modesRemembered, params: Empty.self, result: RememberedModes.self, kind: .hostRequest),
                Row(Method.permissionsPending, params: Empty.self, result: [PermissionRequest].self, kind: .hostRequest),
                Row(Method.elicitationsPending, params: Empty.self, result: [ElicitationRequest].self, kind: .hostRequest),
                Row(Method.attentionPending, params: Empty.self, result: AttentionPending.self, kind: .hostRequest),
                // Which chats the host is bringing back after a restart, for Coming back (#251).
                Row(Method.agentsResuming, params: Empty.self, result: ResumingResponse.self, kind: .hostRequest),
                // Who a retired agent was, for the page a link to it opens (051, #253).
                Row(Method.agentsRetired, params: RetiredRequest.self, result: [Tombstone].self, kind: .hostRequest),
                Row(Method.worktreesList, params: WorktreesListRequest.self, result: WorktreesListResponse.self,
                    kind: .hostRequest),
                Row(Method.workflowsList, params: WorkflowsListRequest.self, result: [WorkflowSummary].self, kind: .hostRequest),
                Row(Method.filesList, params: FilesListRequest.self, result: DirectoryListing.self, kind: .hostRequest),
                Row(Method.filesRead, params: FilesReadRequest.self, result: FileReading.self, kind: .hostRequest),
                Row(Method.changesList, params: ChangesListRequest.self, result: ChangesList.self, kind: .hostRequest),
                Row(Method.changesFile, params: ChangesFileRequest.self, result: ChangedFileDetail.self, kind: .hostRequest),
                Row(Method.agentsLabelVocabulary, params: LabelVocabularyRequest.self, result: [String].self,
                    kind: .hostRequest),
                Row(Method.costState, params: Empty.self, result: CostState.self, kind: .hostRequest),
                Row(Method.eventsList, params: EventsListRequest.self, result: EventsPage.self, kind: .hostRequest),
                Row(Method.leasesSnapshot, params: Empty.self, result: LeaseSnapshot.self, kind: .hostRequest),
                // The low disk space strip (#195, #196), as the window draws it.
                Row(Method.diskState, params: Empty.self, result: DiskState.self, kind: .hostRequest),
                // The files the host could not read in this run (#205, #223), as the window's sidebar foot.
                Row(Method.storeNotes, params: Empty.self, result: StoreNotes.self, kind: .hostRequest),
                // Pinned pages (#159): the sidebar's rows and the pages themselves.
                Row(Method.pinsList, params: Empty.self, result: [ProjectPins].self, kind: .hostRequest),
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
                Row(Method.agentsPrompt, params: PromptRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsSendNow, params: UnqueueRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsUnqueue, params: UnqueueRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsStop, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsStopBackground, params: StopBackgroundRequest.self, result: JSONValue.self, kind: .hostRequest),
                Row(Method.agentsPark, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsUnpark, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsArchive, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                // The ways on from a missing folder (#119), as the window's header has them.
                Row(Method.agentsContinueInProject, params: ContinueInProjectRequest.self, result: UUID.self,
                    kind: .hostRequest),
                Row(Method.agentsRecreateWorktree, params: AgentRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetUnread, params: SetUnreadRequest.self, result: Empty.self, kind: .hostRequest),
                // Branch (#342): the new session's id, as the window's row and Session menu have it.
                Row(Method.agentsFork, params: AgentRequest.self, result: UUID.self, kind: .hostRequest),
                Row(Method.agentsPrewarm, params: PrewarmRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsUnarchive, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsSetLabels, params: SetLabelsRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetCeiling, params: SetCeilingRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetSandbox, params: SetSandboxRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetOption, params: SetOptionRequest.self, result: [ConfigOption].self, kind: .hostRequest),
                Row(Method.permissionsAnswer, params: AnswerRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.elicitationsAnswer, params: AnswerElicitationRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsAnswerSandbox, params: AnswerSandboxRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.workflowsRun, params: WorkflowRequest.self, result: WorkflowSummary.self, kind: .hostRequest),
                // Pin, Unpin, a drop, and typing on a pinned page (#159), from every client alike.
                Row(Method.pinsPin, params: PinRequest.self, result: [PinView].self, kind: .hostRequest),
                Row(Method.pinsUnpin, params: PinPathRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsArrange, params: PinArrangeRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsWrite, params: PinWriteRequest.self, result: Empty.self, kind: .hostRequest),
                // Pin, Unpin and a drop among pinned sessions (#180), from every client alike.
                Row(Method.pinsPinSession, params: PinSessionRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsUnpinSession, params: PinSessionRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.pinsArrangeSessions, params: PinArrangeSessionsRequest.self, result: Empty.self,
                    kind: .hostRequest),
                // Turn Off / Turn On (#100), as the window's and the Remote's rows have it.
                Row(Method.workflowsEnable, params: WorkflowEnableRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                // Approve, and Archive or Bring Back, on the workflow page (#142), as the window's has them.
                Row(Method.workflowsApprove, params: WorkflowApproveRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                // Deny on this host (#391), beside Approve.
                Row(Method.workflowsDeny, params: WorkflowApproveRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                Row(Method.workflowsArchive, params: WorkflowArchiveRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                // Its settings, labels and cooldown on the page (#162), each control its one key.
                Row(Method.workflowsSettings, params: WorkflowSettingsRequest.self, result: WorkflowSummary.self,
                    kind: .hostRequest),
                // New project (#115): Add Folder…, browsing the host's folders, and Clone Git URL…,
                // as the window's projects column has them.
                Row(Method.filesBrowse, params: FilesBrowseRequest.self, result: DirectoryListing.self, kind: .hostRequest),
                Row(Method.projectsAdd, params: ProjectRequest.self, result: ProjectSummary.self, kind: .hostRequest),
                Row(Method.projectsClone, params: CloneRequest.self, result: ProjectSummary.self, kind: .hostRequest),
                Row(Method.projectsClones, params: Empty.self, result: [CloneSummary].self, kind: .hostRequest),
                // Bring Back in the Archived projects fold (#343), as the window's sidebar has it.
                Row(Method.projectsUnarchive, params: ProjectRequest.self, result: ProjectSummary.self, kind: .hostRequest),
                Row(Method.filesWatch, params: FilesWatchRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.filesUnwatch, params: FilesWatchRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.artifactWrite, params: ArtifactWriteRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.filesMention, params: FileMentionRequest.self, result: [FileMentionDTO].self, kind: .hostRequest),
                Row(Method.presenceReport, params: PresenceReport.self, result: Empty.self, kind: .hostRequest),
                Row(Method.surfaceIdentify, params: SurfaceIdentification.self, result: Empty.self, kind: .hostRequest),
                // The control plane's own
                Row(Method.controlStatus, params: Empty.self, result: ControlStatus.self, kind: .controlRequest),
                Row(Method.hostsList, params: Empty.self, result: [ControlHost].self, kind: .controlRequest),
                Row(Method.clientsForgetSelf, params: Empty.self, result: Empty.self, kind: .controlRequest),
                // Heard
                Row(Notification.agentChanged, params: Agent.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.agentEntry, params: EntryNotification.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.agentRemoved, params: AgentRemovedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentResuming, params: ResumingNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentPermission, params: PermissionNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentElicitation, params: ElicitationNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.projectChanged, params: ProjectSummary.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.cloneChanged, params: CloneNotification.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.draftOptions, params: DraftOptionsNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.modesChanged, params: RememberedModes.self, result: Empty.self, kind: .hostNotification),
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
                Row(Notification.leasesChanged, params: LeaseSnapshot.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.diskChanged, params: DiskState.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.storeNotesChanged, params: StoreNotes.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.pinsChanged, params: PinsChangedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.pagesChanged, params: PagesChangedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                // An ad-hoc dictionary from ControlRouter.describe.
                Row(Notification.controlHostChanged, params: JSONValue.self, result: Empty.self, kind: .controlNotification),
            ]
        }
    }
}
