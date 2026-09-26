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
/// Said with `--control-root <path>` or `AGENTS_CONTROL_ROOT`, as a walk does, or saved
/// by the first-run choice. Saved under a key with the window's root in it: a scratch
/// copy shares the real app's defaults, and must not hand the real app its control plane.
enum ControlConfig {
    private static var savedKey: String { "controlRoot:" + StoreLocations.default.root.standardizedFileURL.path }

    /// The control root, if this window has one.
    static var root: URL? {
        ControlPlane.chosenRoot() ?? UserDefaults.standard.string(forKey: savedKey).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static func save(_ root: URL) {
        UserDefaults.standard.set(root.path, forKey: savedKey)
    }

    /// Whether the window should ask how to work (FR-017): no control plane, and nothing
    /// of the old way to keep using. A root with agents or projects on it goes on the old
    /// way until it is moved across (US6).
    static var needsFirstRun: Bool {
        guard root == nil else { return false }
        let locations = StoreLocations.default
        let files = FileManager.default
        if files.fileExists(atPath: locations.projects.path) || files.fileExists(atPath: locations.socket.path) {
            return false
        }
        let agents = (try? files.contentsOfDirectory(atPath: locations.agents.path)) ?? []
        return agents.isEmpty
    }

    /// One connection for every host's client.
    static func link(root: URL) -> ControlLink {
        let socket = ControlPlane.clientSocket(root: root).path
        return ControlLink { FDTransport(socket: try connectUnixSocket(path: socket)) }
    }

    /// The client for this Mac's own host: through the control plane when there is one.
    static func macClient() -> DaemonClient {
        guard let root else { return DaemonClient() }
        return DaemonClient(link: link(root: root).link(for: .mac))
    }
}
