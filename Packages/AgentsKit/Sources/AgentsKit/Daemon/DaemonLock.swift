import Foundation

/// One daemon at a time.
///
/// A file lock rather than a port or a registered service, because the lock dies with
/// the process: a daemon that crashes leaves nothing to clean up and nothing to
/// explain to the user.
public final class DaemonLock: @unchecked Sendable {
    private let descriptor: Int32

    /// Takes the lock, or returns nil because somebody else holds it.
    public init?(at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
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
