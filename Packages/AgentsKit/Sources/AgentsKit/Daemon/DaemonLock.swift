import Foundation

/// One daemon at a time.
///
/// A file lock rather than a port or a registered service, because the lock dies with
/// the process: a daemon that crashes leaves nothing to clean up and nothing to
/// explain to the user.
public final class DaemonLock: @unchecked Sendable {
    /// Readable inside the module so a test can close it the way a kill would, which
    /// is the case that matters: `release` unlocks first, and an unlock is honoured
    /// however many processes hold the descriptor.
    private(set) var descriptor: Int32

    /// Takes the lock, or returns nil because somebody else holds it.
    public init?(at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // O_CLOEXEC because the lock must die with the daemon and nothing else. A
        // child that inherits it — a shell, which outlives the daemon by design —
        // keeps holding the lock afterwards, and the next daemon reads that as
        // "another one is already running" and exits without a word.
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        ftruncate(descriptor, 0)
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
    }

    public func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
