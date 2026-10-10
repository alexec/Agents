import Foundation

/// The words for a hosted MCP server's row on the Resources page (#488), the same on the
/// Mac, the Remote and the web page (`Web/src/model/hostedMCP.ts`).
public enum HostedMCPWords {
    /// Whose file names it: the project's folder name, or the person's own.
    public static func place(_ status: DaemonAPI.HostedMCPStatus) -> String {
        guard let project = status.project else { return "Your own (~/.agents/mcp.json)" }
        let name = (project as NSString).lastPathComponent
        return name.isEmpty ? project : name
    }

    /// What it is doing, in a line.
    public static func line(_ status: DaemonAPI.HostedMCPStatus) -> String {
        let using = status.users == 1 ? "1 using it" : "\(status.users) using it"
        switch status.state {
        case .running:
            return (status.since.map { "Running since \(LeaseWords.clock($0))" } ?? "Running") + " \u{00B7} \(using)"
        case .starting:
            return "Starting\u{2026}"
        case .restarting:
            let when = status.retryAt.map { " at \(LeaseWords.clock($0))" } ?? ""
            return "Stopped; starting again\(when)" + (status.restarts > 0 ? " \u{00B7} restarted \(times(status.restarts))" : "")
        case .idle:
            return status.users > 0 ? "Idle \u{00B7} starts on the next call" : "Idle \u{00B7} nothing uses it"
        }
    }

    /// Why it last stopped, when it has: shown under the line.
    public static func lastError(_ status: DaemonAPI.HostedMCPStatus) -> String? {
        guard let error = status.lastError, !error.isEmpty else { return nil }
        return status.state == .restarting ? error : "Last stopped: \(error)"
    }

    private static func times(_ count: Int) -> String { count == 1 ? "once" : "\(count) times" }
}
