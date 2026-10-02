import Foundation
#if canImport(os)
import os
#endif

/// Where the wire says what it could not make sense of (#93).
///
/// This package has no log of its own: the daemon writes `daemon.log`, the control plane
/// standard error and the window the system log. Each sets `sink` once at start, and
/// until it does a line goes to the system log where there is one, else standard error.
public enum WireLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: (@Sendable (String) -> Void)?

    public static var sink: (@Sendable (String) -> Void)? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public static func write(_ line: String) {
        if let sink { sink(line); return }
        #if canImport(os)
        Logger(subsystem: "com.alexecollins.agents", category: "wire").notice("\(line, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("\(line)\n".utf8))
        #endif
    }

    /// The first part of a line, for saying which one: a whole transcript can be one line.
    public static func excerpt(_ line: String) -> String {
        line.count <= 200 ? line : String(line.prefix(200)) + "…"
    }
}
