import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(Security)
import Security
#endif

/// The binary runtimes start as an agent's MCP helper: a copy of the daemon's own, kept
/// in the root, so nothing that rebuilds the app can change it under a running daemon.
///
/// The helper was the daemon's own path, inside the app. The app is run from where it
/// is built, and a build writes over that path while the daemon goes on running. The
/// socket names a helper by its signature, and a signature is checked against the file
/// on disk, so from then on every helper was a stranger: one already running no longer
/// matched its file, and one started later was whatever the build made — unsigned, when
/// the build did not sign. `finish_turn` and every other app tool were refused until the
/// daemon was restarted. The copy is private to the root, named by what is in it, and
/// only ever written by a daemon starting.
///
/// Only where roles are by signature: without them any helper is let in, and the path
/// the runtime is given is the daemon's own as before.
enum PinnedHelper {
    /// Where the running daemon's own binary is copied, or nil to use the binary where it
    /// is: when roles are not by signature, or when the file there is no longer the one
    /// running, which a copy would not fix.
    static func pin(_ executable: URL, in folder: URL) -> URL? {
        #if canImport(Security)
        guard CallerSignature.ownTeam != nil else { return nil }
        return pin(executable, in: folder, identity: CallerSignature.fileIdentity,
                   runningMatchesDisk: CallerSignature.selfMatchesDisk)
        #else
        return nil
        #endif
    }

    /// How long a copy another build left is kept: its daemon's runtimes, and their
    /// helpers, may outlive it by a little.
    static let keepOthersFor: TimeInterval = 7 * 24 * 3600

    /// The work of `pin`, with what signing says passed in so it can be tested unsigned.
    /// `identity` names a file by its contents (the code directory hash), and
    /// `runningMatchesDisk` says whether `executable` is still what this process runs.
    static func pin(_ executable: URL, in folder: URL,
                    identity: (URL) -> String?, runningMatchesDisk: () -> Bool,
                    now: Date = Date()) -> URL? {
        let files = FileManager.default
        guard runningMatchesDisk(), let name = identity(executable) else { return nil }
        let pinned = folder.appendingPathComponent("agentsd-\(name)")
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            if identity(pinned) != name {
                // Beside the destination and renamed over it, so a runtime starting now
                // never finds half a binary.
                let partial = folder.appendingPathComponent(".agentsd-\(UUID().uuidString)")
                try files.copyItem(at: executable, to: partial)
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: partial.path)
                // Copied from a file that did not change while it was read.
                guard identity(partial) == name, runningMatchesDisk() else {
                    try? files.removeItem(at: partial)
                    return nil
                }
                guard rename(partial.path, pinned.path) == 0 else {
                    try? files.removeItem(at: partial)
                    return nil
                }
            }
            try files.setAttributes([.modificationDate: now], ofItemAtPath: pinned.path)
        } catch {
            return nil
        }
        tidy(folder, keeping: pinned, now: now)
        return pinned
    }

    /// Copies no daemon has started from for a week.
    private static func tidy(_ folder: URL, keeping pinned: URL, now: Date) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name != pinned.lastPathComponent {
            let url = folder.appendingPathComponent(name)
            let modified = (try? files.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if name.hasPrefix(".") || (modified.map { now.timeIntervalSince($0) > keepOthersFor } ?? true) {
                try? files.removeItem(at: url)
            }
        }
    }
}

/// The pinned copy's path, set once by the daemon as it starts and read by every launch.
final class PinnedHelperPath: @unchecked Sendable {
    private let lock = NSLock()
    private var _path: String?

    var path: String? {
        get { lock.lock(); defer { lock.unlock() }; return _path }
        set { lock.lock(); defer { lock.unlock() }; _path = newValue }
    }
}
