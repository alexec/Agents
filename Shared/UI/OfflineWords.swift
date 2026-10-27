import AgentsKitCore
import Foundation

/// What the strip over a chat says when its host is down (#83, #239), once for both
/// apps. This Mac's host down is not the same news as a server's: nothing of this
/// Mac's moves until it is back, so it does not say the agents keep working.
enum OfflineWords {
    static func line(host: MachineRef, name: String, since: String?) -> String {
        let since = since.map { " since \($0)" } ?? ""
        return host == .mac
            ? "This Mac hasn’t answered\(since). Nothing here can change until it’s back. Trying again…"
            : "\(name) is offline\(since). Agents there keep working."
    }

    /// A host linked to a provider's workspace (#691, layouts.md L1): what its strip says
    /// while the workspace is stopped, starting or failed to start, or nil when the
    /// ordinary offline line says it (its workspace is running, so agentsd is what went).
    static func workspaceLine(name: String, state: String, workspace: DaemonAPI.MachineWorkspace) -> String? {
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
        // Its wake-up call, after why it stopped (#1004 FR-007).
        let wake = wakeLine(workspace).map { " \($0)." } ?? ""
        if let by = workspace.stoppedBy { return "\(name) was \(by.prefix(1).lowercased() + by.dropFirst()).\(wake)" }
        return "\(name) is stopped. Agents there are paused until it starts.\(wake)"
    }

    /// "Starts at 02:55 for Nightly review" (#1004 FR-007): when the control plane will start
    /// it for its next scheduled workflow, or nil when it won't.
    static func wakeLine(_ workspace: DaemonAPI.MachineWorkspace, now: Date = Date()) -> String? {
        guard let at = workspace.wakeAt, let workflow = workspace.nextWorkflow else { return nil }
        return "Starts \(clock(at, now: now)) for \(workflow)"
    }

    /// "Stays up for Nightly review at 03:00": an idle host its next scheduled workflow keeps
    /// up, as it is due within its idle time (#1004 FR-005).
    static func staysUpLine(_ workspace: DaemonAPI.MachineWorkspace, now: Date = Date()) -> String? {
        guard let minutes = workspace.stopWhenIdleMinutes, let at = workspace.nextWorkflowAt,
              let workflow = workspace.nextWorkflow, at.timeIntervalSince(now) <= TimeInterval(minutes * 60) else { return nil }
        return "Stays up for \(workflow) \(clock(at, now: now))"
    }

    /// "at 02:55" today or within the day; "Tue at 02:55" further off. 24-hour, as the web's.
    static func clock(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        guard date.timeIntervalSince(now) >= 20 * 3600, let weekday = parts.weekday else { return "at \(time)" }
        return "\(calendar.shortWeekdaySymbols[weekday - 1]) at \(time)"
    }

    /// Under a chat's history that did not load because its server is down (#963): the strip
    /// above already says why, so this says only what the page shows. The web's words.
    static let lastHeard = "That machine is offline. What's shown is from when it was last heard."

    /// Whether a call failed because its host is down, not because of what it asked: the
    /// host refused as offline, or its channel closed under it (#963).
    static func hostDown(_ error: any Error) -> Bool {
        if let error = error as? JSONRPCError { return error.code == DaemonAPI.Failure.hostOffline }
        if case .closed? = error as? JSONRPCTransportError { return true }
        return false
    }

    /// What the sidebar's foot says for a server that isn't online (#961): a workspace's
    /// words, as its strip says them, or that it is offline.
    static func footLine(name: String, row: DaemonAPI.ControlMachine?) -> String {
        if let row, let workspace = row.workspace,
           let words = workspaceLine(name: name, state: row.state, workspace: workspace) {
            return words
        }
        return "\(name) is offline"
    }

    /// Whether the strip offers Start: a stopped or failed workspace, with nothing under way.
    static func offersStart(state: String, workspace: DaemonAPI.MachineWorkspace) -> Bool {
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
