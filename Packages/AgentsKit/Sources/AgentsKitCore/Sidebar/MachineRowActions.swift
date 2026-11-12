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
    /// Amber: it needs an update, or it is near capacity.
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

    /// Delete's question: it always asks, says how many sessions stop, and names the worktrees
    /// on it with work not pushed (#3979), as the machine said them; nil while it is asked.
    public static func deleteMessage(_ row: DaemonAPI.ControlMachine, sessions: Int,
                                     preview: DaemonAPI.StartedMachinePreview? = nil, asking: Bool = false) -> String {
        let at = row.workspace.map { "\($0.providerName) deletes" } ?? "Its provider deletes"
        let stop = sessions == 0 ? "" : sessions == 1 ? " 1 session on it stops." : " \(sessions) sessions on it stop."
        var words = "\(at) this machine and its disk.\(stop)"
        if asking {
            words += " Asking \(row.name) what work on it is not pushed…"
        } else if let unknown = preview?.unknown {
            words += " " + unknown
        } else if let work = preview?.unpushed, !work.isEmpty {
            let count = work.count == 1 ? "1 worktree has" : "\(work.count) worktrees have"
            words += " \(count) work not pushed, which is lost:\n"
                + work.map { "\($0.folder.lastPathComponent) · \(PeopleWords.unpushedWords($0))" }.joined(separator: "\n")
        }
        return words
    }
}

/// A machine row's icon (#4113): its shape says the kind, its colour the state, so the row
/// needs no dot. The grey line under the row says why in words.
public enum MachineIcon: Equatable, Sendable {
    /// The accent: all is well.
    case accent
    /// Amber and pulsing: starting, stopping or being made.
    case busy
    /// Red: offline, its set-up failed, a disk is low, or it is at capacity.
    case failure
    /// Amber: it needs an update, or it is near capacity.
    case attention
    /// Grey: stopped.
    case stopped

    /// The most urgent wins: busy, then red, then amber, then grey, then the accent. At
    /// capacity is red and near capacity amber (#4748), as the machine's page tints them.
    public static func of(_ dot: MachineDot, diskLow: Bool, capacity: DaemonAPI.CapacityLevel? = nil) -> MachineIcon {
        if dot == .busy { return .busy }
        if dot == .offline || diskLow || capacity == .full { return .failure }
        if capacity == .near { return .attention }
        switch dot {
        case .attention: return .attention
        case .stopped: return .stopped
        default: return .accent
        }
    }

    /// A laptop for This Mac, a cloud for a machine a provider made, a rack for a registered one.
    public static func symbol(isThisMac: Bool, row: DaemonAPI.ControlMachine?) -> String {
        isThisMac ? "laptopcomputer" : row?.workspace != nil ? "cloud" : "server.rack"
    }
}

/// A machine New Machine made that has not joined yet (#4610): a row under Machines, as the
/// web page's. Amber and *Making…* while the control plane waits for it; red with the reason
/// and Delete once the control plane gave up. The web page's machineRow has the same rows.
public struct MachineMaking: Equatable, Sendable, Identifiable {
    public var provider: ProviderID
    public var providerName: String
    public var workspace: String
    public var name: String
    /// Why the control plane gave up waiting; nil while it still waits.
    public var notJoined: String?

    public var id: String { "\(provider.rawValue)/\(workspace)" }

    public init(provider: ProviderID, providerName: String, workspace: String, name: String, notJoined: String? = nil) {
        self.provider = provider
        self.providerName = providerName
        self.workspace = workspace
        self.name = name
        self.notJoined = notJoined
    }

    /// The rows: each provider's workspaces New Machine made that no machine is linked to and
    /// no machine of the same name has joined, the ones still making first, then by name.
    public static func rows(_ providers: [DaemonAPI.ProviderSummary], hostNames: Set<String>) -> [MachineMaking] {
        var rows: [MachineMaking] = []
        for provider in providers {
            for workspace in provider.workspaces where workspace.host == nil && !hostNames.contains(workspace.name) {
                guard workspace.joining == true || workspace.notJoined != nil else { continue }
                rows.append(MachineMaking(provider: provider.id, providerName: provider.name, workspace: workspace.id,
                                          name: workspace.name, notJoined: workspace.notJoined))
            }
        }
        return rows.sorted { a, b in
            if (a.notJoined == nil) != (b.notJoined == nil) { return a.notJoined == nil }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The grey line under the row: *Making…*, or why it did not join.
    public var line: String { notJoined ?? "Making…" }

    /// Delete's question on a row the control plane gave up on.
    public var deleteMessage: String {
        "\(providerName) deletes \(name). Nothing was installed on it, so there is nothing to back up."
    }
}
