import AgentsKit
import Foundation

/// Where this window keeps what is its own (058, R11).
///
/// Credentials, the sign-in relay's certificates and `hosts.log` used to live in the
/// same root as the daemon. With a control plane that root is the host's, and the
/// window may not even be on that machine, so they move once into `window/` beside it.
/// Without a control plane nothing moves, and every path is the one it always was.
enum WindowFiles {
    static var support: URL {
        let root = StoreLocations.default.root
        guard ControlConfig.endpoint != nil else { return root }
        return root.appendingPathComponent("window", isDirectory: true)
    }

    /// `<support>/hosts/hosts.log`. The same file `HostSet` has always written, once
    /// the window has a place of its own.
    static var hostsLog: URL {
        support.appendingPathComponent("hosts", isDirectory: true).appendingPathComponent("hosts.log")
    }

    /// Move the window's files out of the host root, once. A file already in `window/`
    /// is left there, and a missing one is not invented. Safe to call again.
    static func prepare() {
        let root = StoreLocations.default.root.standardizedFileURL
        let support = self.support.standardizedFileURL
        guard support.path != root.path else { return }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        move(root.appendingPathComponent("credentials.json"),
             to: support.appendingPathComponent("credentials.json"))
        let relay = root.appendingPathComponent("relay", isDirectory: true)
        let relayTo = support.appendingPathComponent("relay", isDirectory: true)
        if FileManager.default.fileExists(atPath: relay.path),
           !FileManager.default.fileExists(atPath: relayTo.path) {
            try? FileManager.default.moveItem(at: relay, to: relayTo)
        }
        let hosts = support.appendingPathComponent("hosts", isDirectory: true)
        try? FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        move(root.appendingPathComponent("hosts").appendingPathComponent("hosts.log"),
             to: hosts.appendingPathComponent("hosts.log"))
        move(root.appendingPathComponent("hosts").appendingPathComponent("relay.log"),
             to: hosts.appendingPathComponent("relay.log"))
    }

    private static func move(_ from: URL, to: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) else { return }
        try? files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.moveItem(at: from, to: to)
    }
}
