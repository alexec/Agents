import AgentsKit
import AgentsKitCore
import Foundation

/// Where this window's control plane is, when it has one (058).
///
/// With one, the window starts nothing: it reaches this Mac's host through the control
/// plane's socket, and the host is kept running by something else. Without one it is
/// the window it always was, which spawns `agentsd` and talks to its socket, until the
/// set-up is moved across (R7, "Transition").
///
/// For now it is said with `--control-root <path>` or `AGENTS_CONTROL_ROOT`, as a walk
/// does; the first-run choice (US2) will save it.
enum ControlConfig {
    static let root: URL? = ControlPlane.chosenRoot()

    /// One connection for every host's client, made once.
    static let link: ControlLink? = root.map { root in
        let socket = ControlPlane.clientSocket(root: root).path
        return ControlLink { FDTransport(socket: try connectUnixSocket(path: socket)) }
    }

    /// The client for this Mac's own host: through the control plane when there is one.
    static func macClient() -> DaemonClient {
        guard let link else { return DaemonClient() }
        return DaemonClient(link: link.link(for: .mac))
    }
}
