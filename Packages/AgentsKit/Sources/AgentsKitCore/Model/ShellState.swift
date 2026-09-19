import Foundation

/// Whether a shell is there, and if not, why not.
///
/// Every state but `live` keeps the scrollback readable (FR-029). A shell that has gone
/// says what happened and offers to start another; it never draws a dead screen as
/// though it were live.
public enum ShellState: Codable, Hashable, Sendable {
    case live
    /// The shell exited of its own accord, usually because the user typed `exit`.
    case exited(status: Int32)
    /// It never started. A missing login shell, or a folder that is not there (FR-024).
    case failed(reason: String)
    /// It was let go: reaped for sitting idle, or lost with the daemon or the machine
    /// (FR-028, FR-029).
    case released(reason: String)

    public var isLive: Bool { if case .live = self { return true }; return false }

    /// What the pane says. Written for the person reading it at that moment.
    public var explanation: String? {
        switch self {
        case .live:
            return nil
        case .exited(let status):
            return status == 0 ? "The shell exited." : "The shell exited with status \(status)."
        case .failed(let reason):
            return reason
        case .released(let reason):
            return reason
        }
    }

    /// Whether offering a new shell makes sense. It always does once this one is gone.
    public var canRestart: Bool { !isLive }
}
