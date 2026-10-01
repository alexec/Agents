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
    /// `--control <code>`: a host of the control plane the code is for (058). It enrols
    /// with the code once, dials out over a WebSocket and stays up with nobody connected,
    /// as `--serve` does, but is otherwise the Mac's daemon it always was.
    public static let controlFlag = "--control"

    public let arguments: [String]
    public let mode: Mode

    public init(_ arguments: [String],
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.arguments = arguments
        if arguments.count >= 2, arguments[1] == "mcp" {
            // Prefer the environment (S7); an old argv form still works for a moment.
            let token = environment[DaemonCore.mcpTokenVariable]
                ?? (arguments.count >= 3 ? arguments[2] : nil)
                ?? ""
            mode = .mcp(token: token)
        } else {
            let rest = arguments.dropFirst()
            mode = .daemon(serve: rest.contains(Self.serveFlag), detach: rest.contains(Self.detachFlag))
        }
    }

    /// `--control <code>` or `--control-code <code>`: enrol this host with a control
    /// plane, once; after that the membership kept in the root is used, and so is it when
    /// `--control-network` is given alone.
    public var controlCode: String? { value(after: Self.controlFlag) ?? value(after: "--control-code") }
    public var controlNetwork: Bool { controlCode != nil || arguments.contains("--control-network") }

    /// `--host-name <name>`: what the control plane lists this host as, when not this
    /// machine's own name.
    public var hostName: String? { value(after: "--host-name") }

    private func value(after flag: String) -> String? {
        guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
        return arguments[at + 1]
    }

    /// What the detached copy is started with.
    public var childArguments: [String] {
        Array(arguments.dropFirst().filter { $0 != Self.detachFlag })
    }
}
