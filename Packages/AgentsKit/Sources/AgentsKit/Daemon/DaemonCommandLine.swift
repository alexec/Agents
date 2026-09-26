import AgentsKitCore
import Foundation

/// What `agentsd` was asked to be (037).
///
/// Three things share one binary: the daemon, the MCP helper a runtime starts for each
/// agent, and — on a server — a daemon that starts itself in the background and returns
/// so the ssh command that asked for it can finish.
public struct DaemonCommandLine: Sendable {
    public enum Mode: Equatable, Sendable {
        /// `serve`: never exit for being idle. `detach`: start a copy of this process in
        /// a session of its own, told everything but `--detach`, and return at once.
        case daemon(serve: Bool, detach: Bool)
        case mcp(token: String)
    }

    public static let serveFlag = "--serve"
    public static let detachFlag = "--detach"
    /// `--control <socket>`: a host of the control plane listening there (058). It
    /// dials out to it and stays up with nobody connected, as `--serve` does, but is
    /// otherwise the Mac's daemon it always was.
    public static let controlFlag = "--control"
    /// `--host-id <id>`: which host this is, said on the control plane's local socket.
    /// `mac` unless told otherwise, so a set-up moved across keeps its host id (R7).
    public static let hostIDFlag = "--host-id"
    /// `--control-home`: a host of the control plane at its ordinary root on this Mac,
    /// which is what the launch agent says (R5).
    public static let controlHomeFlag = "--control-home"

    public let arguments: [String]
    public let mode: Mode

    public init(_ arguments: [String]) {
        self.arguments = arguments
        if arguments.count >= 3, arguments[1] == "mcp" {
            mode = .mcp(token: arguments[2])
        } else {
            let rest = arguments.dropFirst()
            mode = .daemon(serve: rest.contains(Self.serveFlag), detach: rest.contains(Self.detachFlag))
        }
    }

    /// The control plane's host socket, when this daemon is one of its hosts.
    public var controlSocket: String? {
        if let socket = value(after: Self.controlFlag) { return socket }
        return arguments.contains(Self.controlHomeFlag) ? ControlPlane.hostSocket(root: ControlPlane.defaultRoot).path : nil
    }

    /// `--host-name <name>`: what the control plane lists this host as, when not this
    /// machine's own name.
    public var hostName: String? { value(after: "--host-name") }

    public var hostID: HostID {
        value(after: Self.hostIDFlag).map(HostID.init(rawValue:)) ?? .mac
    }

    private func value(after flag: String) -> String? {
        guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
        return arguments[at + 1]
    }

    /// What the detached copy is started with.
    public var childArguments: [String] {
        Array(arguments.dropFirst().filter { $0 != Self.detachFlag })
    }
}
