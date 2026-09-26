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
    /// Anything else of this account: whether the daemon is there, and no more.
    case stranger

    /// What a helper relays, one per app tool, and nothing a window does.
    public static let agentMethods: Set<String> = Set<String>([
        DaemonAPI.Method.agentsFinishTurn,
        DaemonAPI.Method.agentsSuggestPrompts,
        DaemonAPI.Method.agentsReportOutcome,
        DaemonAPI.Method.agentsShowFile,
        DaemonAPI.Method.agentsManageWorkflows,
        DaemonAPI.Method.agentsStartHelper,
        DaemonAPI.Method.agentsStopHelper,
        DaemonAPI.Method.agentsArchiveHelper,
        DaemonAPI.Method.agentsListHelpers,
        DaemonAPI.Method.agentsPushPullRequest,
        DaemonAPI.Method.agentsReplyOnPullRequest,
        DaemonAPI.Method.leasesLease,
        DaemonAPI.Method.leasesRelease,
        DaemonAPI.Method.leasesList,
        DaemonAPI.Method.eventsWait,
        DaemonAPI.Method.eventsCancel,
        DaemonAPI.Method.eventsPublish,
    ]).union(strangerMethods)

    /// Enough to find out a daemon is answering, which a client does before anything.
    public static let strangerMethods: Set<String> = [
        DaemonAPI.Method.ping,
        DaemonAPI.Method.daemonStatus,
    ]

    public func allows(_ method: String) -> Bool {
        switch self {
        case .control: true
        case .agent: Self.agentMethods.contains(method)
        case .stranger: Self.strangerMethods.contains(method)
        }
    }

    /// Only a window hears what the daemon says. A helper only ever waits on its own
    /// replies, and a stranger must not read every agent's transcript and terminal
    /// going by.
    public var hearsNotifications: Bool { self == .control }
}
