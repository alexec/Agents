import AgentsKitCore
import Foundation

/// Where Agents Host keeps things, and what its launch agents are called (058, T054).
///
/// The ordinary set-up: this Mac's host at the app's ordinary root, and the single copy of
/// the control plane in `~/Library/Application Support/Agents Control` (T057), registered
/// with `SMAppService` from the bundle.
///
/// A scratch set-up, for walks: `AGENTS_ROOT=<dir>` puts the host in `<dir>/host` and the
/// control plane in `<dir>/control`, labels both jobs with the root's hash, keeps its
/// secrets in files under the root instead of the keychain, and listens off 8791. Nothing
/// of a walk reaches `~/Library/LaunchAgents`, the keychain or the ordinary folders.
struct HostPaths: Sendable, Equatable {
    let scratch: Bool
    /// agentsd's root.
    let hostRoot: URL
    /// `agents-control serve --home`: its certificate, key file (scratch only) and store.
    let controlHome: URL
    let port: Int
    /// Short, and the same for every process of one set-up: the launcher reads the app's
    /// settings under it.
    let suffix: String

    static let current = HostPaths(environment: ProcessInfo.processInfo.environment)

    init(environment: [String: String]) {
        if let root = environment[StoreLocations.rootVariable], !root.isEmpty {
            let base = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            scratch = true
            hostRoot = base.appendingPathComponent("host", isDirectory: true)
            controlHome = base.appendingPathComponent("control", isDirectory: true)
            port = environment["AGENTS_HOST_PORT"].flatMap(Int.init) ?? 18791
            let hash = base.path.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            suffix = String(String(hash, radix: 16).suffix(8))
        } else {
            scratch = false
            hostRoot = StoreLocations.standard.root
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            controlHome = support.appendingPathComponent("Agents Control", isDirectory: true)
            port = 8791
            suffix = "standard"
        }
    }

    static let controlPlist = "com.alexecollins.agentshost.control.plist"
    static let daemonPlist = "com.alexecollins.agentshost.daemon.plist"

    var controlLabel: String { scratch ? "com.alexecollins.agentshost.control.scratch-\(suffix)" : "com.alexecollins.agentshost.control" }
    var daemonLabel: String { scratch ? "com.alexecollins.agentshost.daemon.scratch-\(suffix)" : "com.alexecollins.agentshost.daemon" }

    var controlLog: URL { controlHome.appendingPathComponent("control.log") }
    var hostLocations: StoreLocations { StoreLocations(root: hostRoot) }

    /// The single copy's store when it is kept on this Mac.
    var folderStore: URL { controlHome.appendingPathComponent("store", isDirectory: true) }

    var helpers: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }
    var agentsControl: URL { helpers.appendingPathComponent("agents-control") }
    var agentsd: URL { helpers.appendingPathComponent("agentsd") }
}
