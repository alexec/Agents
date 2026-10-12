import AgentsKitCore
import Foundation

/// What the strip over a chat says when its host is down (#83, #239), once for both
/// apps. This Mac's host down is not the same news as a server's: nothing of this
/// Mac's moves until it is back, so it does not say the agents keep working.
enum OfflineWords {
    static func line(host: HostID, name: String, since: String?) -> String {
        let since = since.map { " since \($0)" } ?? ""
        return host == .mac
            ? "This Mac’s host hasn’t answered\(since). Nothing here can change until it’s back. Trying again…"
            : "\(name) is offline\(since). Agents there keep working."
    }

    /// A host linked to a provider's workspace (#691, layouts.md L1): what its strip says
    /// while the workspace is stopped, starting or failed to start, or nil when the
    /// ordinary offline line says it (its workspace is running, so agentsd is what went).
    static func workspaceLine(name: String, state: String, workspace: DaemonAPI.HostWorkspace) -> String? {
        if state == "starting" {
            return switch workspace.phase {
            case "connecting": "Waiting for \(name) to connect…"
            case "sshStart": "\(name) started but agentsd didn’t connect; starting it over ssh…"
            default: "Starting \(name)…"
            }
        }
        if state == "stopping" { return "Stopping \(name)…" }
        if let problem = workspace.problem { return problem }
        guard state == "stopped" else { return nil }
        if let by = workspace.stoppedBy { return "\(name) was \(by.prefix(1).lowercased() + by.dropFirst())." }
        return "\(name) is stopped. Agents there are paused until it starts."
    }

    /// Whether the strip offers Start: a stopped or failed workspace, with nothing under way.
    static func offersStart(state: String, workspace: DaemonAPI.HostWorkspace) -> Bool {
        workspace.canStart && state != "online" && state != "starting" && state != "stopping"
    }

    /// What the line under a kept prompt says (#691 US3, layouts.md L6): what it waits for,
    /// or, once the start failed, why it wasn't sent.
    static func keptLine(name: String, kept: DaemonAPI.KeptRequest) -> String {
        kept.failed.map { "Not sent: \($0)" } ?? "Waiting for \(name) to start"
    }

    /// The strip's timer while a start is under way: `0:24`.
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
