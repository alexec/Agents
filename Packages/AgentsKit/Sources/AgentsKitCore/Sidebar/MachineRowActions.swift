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

/// A machine of the person's that has not joined (#4610, #4978): a row under Machines, as the
/// web page's. Amber and *Making…* while the control plane waits for one New Machine made;
/// red with the reason and Delete once the control plane gave up. Grey and *Not joined* for
/// one Agents did not make, such as a codespace made on github.com, or a stopped one: a click
/// joins it (`MachineJoin`). The web page's machineRow has the same rows.
public struct MachineMaking: Equatable, Sendable, Identifiable {
    public var provider: ProviderID
    public var providerName: String
    public var workspace: String
    public var name: String
    /// Why the control plane gave up waiting; nil while it still waits.
    public var notJoined: String?
    /// One New Machine did not make, or no longer waits for (#4978): a click joins it.
    public var joinable: Bool
    /// As the provider listed it: running, stopped, starting…
    public var state: String
    /// Where the control plane's (or the carrying machine's) ssh reaches it; nil when the
    /// provider says nothing, and then it can't join with a click.
    public var ssh: String?
    public var tunnel: Bool

    public var id: String { "\(provider.rawValue)/\(workspace)" }

    public init(provider: ProviderID, providerName: String, workspace: String, name: String, notJoined: String? = nil,
                joinable: Bool = false, state: String = "running", ssh: String? = nil, tunnel: Bool = false) {
        self.provider = provider
        self.providerName = providerName
        self.workspace = workspace
        self.name = name
        self.notJoined = notJoined
        self.joinable = joinable
        self.state = state
        self.ssh = ssh
        self.tunnel = tunnel
    }

    /// The rows: each provider's workspaces that no machine is linked to and no machine of the
    /// same name has joined. The ones still making first, then the ones the control plane gave
    /// up on, then the ones that never joined (#4978), each by name. A failed make is not a
    /// machine: the New Machine sheet says why.
    public static func rows(_ providers: [DaemonAPI.ProviderSummary], hostNames: Set<String>) -> [MachineMaking] {
        var rows: [MachineMaking] = []
        for provider in providers {
            for workspace in provider.workspaces where workspace.host == nil && !hostNames.contains(workspace.name) {
                guard workspace.state != "failed" else { continue }
                let making = workspace.joining == true || workspace.notJoined != nil
                rows.append(MachineMaking(provider: provider.id, providerName: provider.name, workspace: workspace.id,
                                          name: workspace.name, notJoined: workspace.notJoined, joinable: !making,
                                          state: workspace.state, ssh: workspace.ssh, tunnel: workspace.tunnel ?? false))
            }
        }
        func rank(_ row: MachineMaking) -> Int { row.joinable ? 2 : row.notJoined == nil ? 0 : 1 }
        return rows.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Whether a click can join it: one that never joined, with somewhere to ssh to.
    public var canJoin: Bool { joinable && !(ssh ?? "").isEmpty }

    /// The grey line under the row: *Making…*, why it did not join, or how a join goes.
    public func line(_ join: MachineJoin? = nil) -> String {
        guard joinable else { return notJoined ?? "Making…" }
        switch join {
        case .joining(let step): return MachineJoin.words(step, stopped: state == "stopped")
        case .failed(let why): return "Didn’t join: \(why)"
        case .needsTrust(let fingerprint): return "Its ssh host key is new to the control plane: \(fingerprint)"
        case nil: break
        }
        guard canJoin else { return "Not joined. \(providerName) gives no ssh destination for it, so it can’t join from here." }
        switch state {
        case "stopped": return "Stopped, not joined"
        case "starting": return "Starting, not joined"
        case "stopping": return "Stopping, not joined"
        default: return "Not joined"
        }
    }

    /// The line before any join, as `line()`.
    public var line: String { line(nil) }

    /// What a click does, for the row's help and its accessibility hint.
    public var joinHint: String? {
        guard canJoin else { return nil }
        return state == "stopped" || state == "stopping" ? "Starts \(name) and joins it" : "Joins \(name)"
    }

    /// The cloud's tint: amber and pulsing while it is made or joins, red once it failed, grey
    /// for one that never joined.
    public func icon(_ join: MachineJoin? = nil) -> MachineIcon {
        if failed(join) { return .failure }
        if !joinable || join?.isJoining == true { return .busy }
        return .stopped
    }

    /// Whether the row is red: the control plane gave up on it, or its join failed.
    public func failed(_ join: MachineJoin? = nil) -> Bool {
        if !joinable { return notJoined != nil }
        if case .failed = join { return true }
        return false
    }

    /// Delete's question on a row the control plane gave up on.
    public var deleteMessage: String {
        "\(providerName) deletes \(name). Nothing was installed on it, so there is nothing to back up."
    }
}

/// How a click on a machine that never joined goes (#4978), held by the client that clicked:
/// joining at a step the control plane says (`control/installProgress`), a host key new to the
/// control plane for the person to look at first, or failed, with why. It ends when the machine
/// joins and its row leaves.
public enum MachineJoin: Equatable, Sendable {
    case joining(step: String?)
    case needsTrust(String)
    case failed(String)

    /// The host key to ask about, while the join waits for the person's yes.
    public var fingerprint: String? { if case .needsTrust(let key) = self { key } else { nil } }

    public var isJoining: Bool { if case .joining = self { true } else { false } }

    /// The words for a step of an install, as Add a Machine's sheet says them.
    public static func words(_ step: String?, stopped: Bool = false) -> String {
        switch step {
        case "start": "Starting it…"
        case "connect": stopped ? "Starting it and connecting…" : "Connecting…"
        case "checkSystem": "Checking the system…"
        case "setUp": "Installing Agents…"
        case "started": "Joining…"
        default: "Joining…"
        }
    }
}
