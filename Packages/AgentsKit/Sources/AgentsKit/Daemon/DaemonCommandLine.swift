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

    /// What the detached copy is started with.
    public var childArguments: [String] {
        Array(arguments.dropFirst().filter { $0 != Self.detachFlag })
    }
}
