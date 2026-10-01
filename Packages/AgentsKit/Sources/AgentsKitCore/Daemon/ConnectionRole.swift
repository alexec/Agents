import Foundation

/// What a connection to the daemon is, and so what it may ask for.
///
/// Decided by the server from who is on the other end, never from anything the caller
/// says. Every process of this account can reach the socket — including the shell of
/// every agent the daemon starts — so the socket answering everything to everyone made
/// the person's permission prompt a speed bump: one approved command could answer the
/// next prompt itself. Now an agent reaches the daemon only through the tools it was
/// given, and anything else only learns that the daemon is there.
public enum ConnectionRole: String, Sendable, Hashable {
    /// The app or the bridge, as their code signatures say: everything.
    case control
    /// The `agentsd mcp` helper a runtime starts for its agent: that agent's tools,
    /// each call carrying the agent's token.
    case agent
    /// A phone or iPad, carried by the bridge on the LAN link or the relay: what the
    /// Remote does, and nothing that reaches past the agents — no credentials, no
    /// signing in or out, no folders outside a project, no quitting the daemon. A
    /// connection becomes one only by the bridge saying so, and never stops being one.
    case device
    /// A phone on the direct link with a pairing code and no key yet: it may say who it
    /// is and nothing more. Once it has, it hangs up and comes back as a device.
    case pairing
    /// Anything else of this account: whether the daemon is there, and no more.
    case stranger

    /// What a helper relays, one per app tool, and nothing a window does.
    public static let agentMethods: Set<String> = Set<String>([
        DaemonAPI.Method.agentsFinishTurn,
        DaemonAPI.Method.agentsSuggestPrompts,
        DaemonAPI.Method.agentsReportOutcome,
        DaemonAPI.Method.agentsShowFile,
        DaemonAPI.Method.agentsAskForm,
        DaemonAPI.Method.agentsManageWorkflows,
        DaemonAPI.Method.agentsStartHelper,
        DaemonAPI.Method.agentsStopHelper,
        DaemonAPI.Method.agentsArchiveHelper,
        DaemonAPI.Method.agentsListHelpers,
        DaemonAPI.Method.agentsListSessions,
        DaemonAPI.Method.agentsReadSession,
        DaemonAPI.Method.leasesLease,
        DaemonAPI.Method.leasesRelease,
        DaemonAPI.Method.leasesList,
        DaemonAPI.Method.eventsWait,
        DaemonAPI.Method.eventsCancel,
        DaemonAPI.Method.eventsPublish,
        DaemonAPI.Method.agentsMoveSelf,
    ]).union(strangerMethods)

    /// What the Remote calls, and only that. Anything not here is refused to a device,
    /// so a method added later stays the Mac's until somebody decides the phone needs
    /// it. Left out on purpose: `credentials/*`, `runtimes/authenticate`, `logout`,
    /// `install`, `setProvider` and `disableProvider`, `files/browse` and `files/write`, `daemon/quit`,
    /// `hosts/*`, `devices/list` and `forget`, `relay/register`, `mailbox/carry`,
    /// `workflows/approve`, `plugins/list` and `approve`, `projects/add` and `clone`,
    /// `sessions/*`, and every agent tool.
    public static let deviceMethods: Set<String> = Set<String>([
        DaemonAPI.Method.projectsList,
        DaemonAPI.Method.agentsList,
        DaemonAPI.Method.agentsTranscript,
        DaemonAPI.Method.agentsTurns,
        DaemonAPI.Method.agentsStart,
        DaemonAPI.Method.agentsSetLabels,
        DaemonAPI.Method.agentsLabelVocabulary,
        DaemonAPI.Method.agentsPrompt,
        DaemonAPI.Method.agentsUnqueue,
        DaemonAPI.Method.agentsSendNow,
        DaemonAPI.Method.agentsStop,
        DaemonAPI.Method.agentsStopBackground,
        DaemonAPI.Method.agentsMove,
        DaemonAPI.Method.agentsArchive,
        DaemonAPI.Method.agentsUnarchive,
        DaemonAPI.Method.agentsPark,
        DaemonAPI.Method.agentsUnpark,
        DaemonAPI.Method.agentsResuming,
        DaemonAPI.Method.agentsOptions,
        DaemonAPI.Method.agentsSetOption,
        DaemonAPI.Method.agentsSetCeiling,
        DaemonAPI.Method.agentsDiscardDraft,
        DaemonAPI.Method.optionsRemembered,
        DaemonAPI.Method.modesRemembered,
        DaemonAPI.Method.runtimesList,
        DaemonAPI.Method.runtimesAccounts,
        DaemonAPI.Method.permissionsPending,
        DaemonAPI.Method.permissionsAnswer,
        DaemonAPI.Method.elicitationsPending,
        DaemonAPI.Method.elicitationsAnswer,
        DaemonAPI.Method.attentionPending,
        DaemonAPI.Method.presenceReport,
        DaemonAPI.Method.surfaceIdentify,
        DaemonAPI.Method.devicesAnnounce,
        DaemonAPI.Method.eventsList,
        DaemonAPI.Method.leasesSnapshot,
        DaemonAPI.Method.costState,
        // Reads only: the phone shows the notes, the retired line and the retired page,
        // and never changes the settings or retires anything (051, FR-028).
        DaemonAPI.Method.retentionState,
        DaemonAPI.Method.agentsRetired,
        // The phone reads each runtime's state and may say one is back (065).
        DaemonAPI.Method.runtimesAllowances,
        DaemonAPI.Method.runtimesMarkAvailable,
        // The phone reads the runtime defaults and sets one agent's sandbox (064); the
        // defaults themselves are the Mac's.
        DaemonAPI.Method.sandboxState,
        DaemonAPI.Method.agentsSetSandbox,
        DaemonAPI.Method.agentsAnswerSandbox,
        DaemonAPI.Method.worktreesList,
        DaemonAPI.Method.worktreesCheck,
        DaemonAPI.Method.worktreesRemove,
        DaemonAPI.Method.workflowsList,
        DaemonAPI.Method.workflowsRun,
        DaemonAPI.Method.workflowsArchive,
        DaemonAPI.Method.workflowsSettings,
        DaemonAPI.Method.filesMention,
        DaemonAPI.Method.filesList,
        DaemonAPI.Method.filesRead,
        DaemonAPI.Method.filesWatch,
        DaemonAPI.Method.filesUnwatch,
        DaemonAPI.Method.changesList,
        DaemonAPI.Method.changesFile,
        DaemonAPI.Method.artifactWrite,
        DaemonAPI.Method.shellAttach,
        DaemonAPI.Method.shellDetach,
        DaemonAPI.Method.shellInput,
        DaemonAPI.Method.shellResize,
        DaemonAPI.Method.shellSignal,
        DaemonAPI.Method.shellRestart,
    ]).union(strangerMethods)

    /// Announcing, and finding out a daemon is answering.
    public static let pairingMethods: Set<String> = Set<String>([DaemonAPI.Method.devicesAnnounce])
        .union(strangerMethods)

    /// Enough to find out a daemon is answering, which a client does before anything.
    public static let strangerMethods: Set<String> = [
        DaemonAPI.Method.ping,
        DaemonAPI.Method.daemonStatus,
    ]

    public func allows(_ method: String) -> Bool {
        switch self {
        case .control: true
        case .agent: Self.agentMethods.contains(method)
        case .device: Self.deviceMethods.contains(method)
        case .pairing: Self.pairingMethods.contains(method)
        case .stranger: Self.strangerMethods.contains(method)
        }
    }

    /// A window and a device hear what the daemon says: the phone's lists are kept
    /// true by it. A helper only ever waits on its own replies, and a stranger must not
    /// read every agent's transcript and terminal going by.
    public var hearsNotifications: Bool { self == .control || self == .device }
}
