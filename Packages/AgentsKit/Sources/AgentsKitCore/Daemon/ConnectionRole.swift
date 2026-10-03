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
    /// A phone, an iPad or a browser, carried by the bridge on the LAN link or the relay,
    /// or opened for one by the control plane: everything a window may (#111). What sets
    /// it apart is whose it is: it is bound to one device, reports presence as that
    /// device, and may not name another. A connection becomes one only by the bridge or
    /// the uplink saying so, and never stops being one.
    case device
    /// A phone on the direct link with a pairing code and no key yet: it may say who it
    /// is and nothing more. Once it has, it hangs up and comes back as a device.
    case pairing
    /// Anything else of this account: whether the daemon is there, and no more.
    case stranger

    /// What a helper relays, one per app tool, and nothing a window does. Not
    /// `projects/setHelperLimits`: an agent reads its project's helper limits in its
    /// tools' results and never sets them (#64).
    public static let agentMethods: Set<String> = Set<String>([
        DaemonAPI.Method.agentsFinishTurn,
        DaemonAPI.Method.agentsSuggestPrompts,
        DaemonAPI.Method.agentsReportOutcome,
        DaemonAPI.Method.agentsShowFile,
        DaemonAPI.Method.agentsAskForm,
        DaemonAPI.Method.agentsManageWorkflows,
        DaemonAPI.Method.agentsStartHelper,
        DaemonAPI.Method.agentsStopHelper,
        DaemonAPI.Method.agentsParkHelper,
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
        DaemonAPI.Method.dashboardSetTile,
        DaemonAPI.Method.dashboardRemoveTile,
        DaemonAPI.Method.dashboardMoveTile,
        DaemonAPI.Method.dashboardRead,
        DaemonAPI.Method.agentsMoveSelf,
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
        case .control, .device: true
        case .agent: Self.agentMethods.contains(method)
        case .pairing: Self.pairingMethods.contains(method)
        case .stranger: Self.strangerMethods.contains(method)
        }
    }

    /// A window and a device hear what the daemon says: the phone's lists are kept
    /// true by it. A helper only ever waits on its own replies, and a stranger must not
    /// read every agent's transcript and terminal going by.
    public var hearsNotifications: Bool { isPerson }

    /// A window's or a paired client's: a person at a screen, who may do everything,
    /// as against an agent's helper or a stranger.
    public var isPerson: Bool { self == .control || self == .device }
}
