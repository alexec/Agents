import Foundation

/// What the web remote calls and hears (071, research R6, data-model.md "WebSignatures").
///
/// Nothing else in Swift ties a method to its params and result, so this table does, for the
/// methods the web remote uses and no others. It is plain Swift, so a renamed or deleted type
/// breaks the build here; Packages/WebTypes reads it as source and generates the web remote's
/// TypeScript from the types it names. `WebSignaturesTests` holds every host request to the
/// device grant, so the web remote can be typed only against what a device may do (FR-016).
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
                Row(Method.agentsTurns, params: TurnsRequest.self, result: TurnsPage.self, kind: .hostRequest),
                Row(Method.agentsOptions, params: OptionsRequest.self, result: OptionsResponse.self, kind: .hostRequest),
                Row(Method.runtimesList, params: Empty.self, result: [RuntimeStatus].self, kind: .hostRequest),
                Row(Method.runtimesAccounts, params: Empty.self, result: [RuntimeAccount].self, kind: .hostRequest),
                Row(Method.optionsRemembered, params: RememberedOptionsRequest.self, result: [ConfigOption].self,
                    kind: .hostRequest),
                Row(Method.modesRemembered, params: Empty.self, result: RememberedModes.self, kind: .hostRequest),
                Row(Method.permissionsPending, params: Empty.self, result: [PermissionRequest].self, kind: .hostRequest),
                Row(Method.elicitationsPending, params: Empty.self, result: [ElicitationRequest].self, kind: .hostRequest),
                Row(Method.attentionPending, params: Empty.self, result: AttentionPending.self, kind: .hostRequest),
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
                // Acting
                Row(Method.agentsStart, params: StartRequest.self, result: UUID.self, kind: .hostRequest),
                Row(Method.agentsPrompt, params: PromptRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsSendNow, params: UnqueueRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsUnqueue, params: UnqueueRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsStop, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsStopBackground, params: StopBackgroundRequest.self, result: JSONValue.self, kind: .hostRequest),
                Row(Method.agentsPark, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsUnpark, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsArchive, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsUnarchive, params: AgentRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsSetLabels, params: SetLabelsRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.agentsSetOption, params: SetOptionRequest.self, result: [ConfigOption].self, kind: .hostRequest),
                Row(Method.permissionsAnswer, params: AnswerRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.elicitationsAnswer, params: AnswerElicitationRequest.self, result: Empty.self, kind: .hostRequest),
                Row(Method.agentsAnswerSandbox, params: AnswerSandboxRequest.self, result: Agent.self, kind: .hostRequest),
                Row(Method.workflowsRun, params: WorkflowRequest.self, result: WorkflowSummary.self, kind: .hostRequest),
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
                Row(Notification.agentPermission, params: PermissionNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentElicitation, params: ElicitationNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.projectChanged, params: ProjectSummary.self, result: Empty.self, kind: .hostNotification),
                Row(Notification.attentionChanged, params: AttentionNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.filesChanged, params: FilesChangedNotification.self, result: Empty.self,
                    kind: .hostNotification),
                Row(Notification.agentShowFile, params: ShowFileNotification.self, result: Empty.self,
                    kind: .hostNotification),
                // An ad-hoc dictionary from ControlRouter.describe.
                Row(Notification.controlHostChanged, params: JSONValue.self, result: Empty.self, kind: .controlNotification),
            ]
        }
    }
}
