import Foundation

/// A machine's row under Machines (#3973), as the web page's machineRow (#3974): its dot, what
/// its menu and swipes do, and what Delete asks first. A machine a provider made can start,
/// stop and be deleted; a registered one can only be removed; This Mac has neither.
public enum MachineDot: Equatable, Sendable {
    /// Green: online.
    case online
    /// Amber and turning: starting, stopping or being made.
    case busy
    /// Grey and hollow: its workspace is stopped.
    case stopped
    /// Red: offline, or its set-up failed.
    case offline
    /// Amber: it needs an update.
    case attention

    /// The machine's own state only: its sessions do not roll up into it (#3971).
    public static func of(_ row: DaemonAPI.ControlMachine?, online: Bool, starting: Bool) -> MachineDot {
        if starting || row?.state == "starting" || row?.state == "stopping" { return .busy }
        if row?.state == "needsUpdate" { return .attention }
        if online { return .online }
        if row?.state == "stopped" { return .stopped }
        return .offline
    }
}

public struct MachineRowActions: Equatable, Sendable {
    public var start = false
    public var stop = false
    /// Delete…: the provider deletes it.
    public var delete = false
    /// Remove…: Agents forgets it; the computer stays.
    public var remove = false

    /// What a row offers, in its menu and its swipes. This Mac, and a machine with no
    /// control plane row, offers nothing.
    public static func of(_ row: DaemonAPI.ControlMachine?, isThisMac: Bool) -> MachineRowActions {
        guard !isThisMac, let row else { return MachineRowActions() }
        guard let workspace = row.workspace else { return MachineRowActions(remove: true) }
        let changing = row.state == "starting" || row.state == "stopping"
        let up = row.state == "online" || row.state == "needsUpdate"
        return MachineRowActions(start: workspace.canStart && !changing && !up,
                                 stop: workspace.canStop && !changing && up,
                                 delete: true)
    }

    /// Delete's question: it always asks, and says how many sessions stop.
    public static func deleteMessage(_ row: DaemonAPI.ControlMachine, sessions: Int) -> String {
        let at = row.workspace.map { "\($0.providerName) deletes" } ?? "Its provider deletes"
        let stop = sessions == 0 ? "" : sessions == 1 ? " 1 session on it stops." : " \(sessions) sessions on it stop."
        return "\(at) this machine and its disk.\(stop)"
    }
}
