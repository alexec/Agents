import Foundation

/// One computer a workflow page can pin to (#317).
///
/// The machine id is what the file stores. The name is the one already on screen:
/// "This Mac", or the server's name. Renaming the computer does not change the id.
public struct WorkflowHostChoice: Hashable, Sendable, Identifiable {
    public var machineID: String
    public var name: String
    public var id: String { machineID }

    public init(machineID: String, name: String) {
        self.machineID = machineID
        self.name = name
    }
}

/// The hosts a workflow's `hosts:` list is chosen from.
public enum WorkflowHosts {
    /// Enrolled hosts that run agents, in the window's order: This Mac, then the rest
    /// by name. A relay is left out, because it runs no agents. A host with no machine
    /// id cannot be written, so it is left out too.
    ///
    /// "This Mac" is the host whose machine id is `thisMachine` when this device is
    /// that computer. Otherwise it is the host with id `.mac` — the phone and the page
    /// are not that computer, and they still use the window's name for it.
    public static func choices(from hosts: [DaemonAPI.ControlHost], thisMachine: String?) -> [WorkflowHostChoice] {
        let usable = hosts.filter { $0.relay != true && !trimmed($0.machineID).isEmpty }
        let mac = thisMachine.flatMap { machine in
            let wanted = machine.trimmingCharacters(in: .whitespacesAndNewlines)
            return usable.first { trimmed($0.machineID) == wanted }
        }
        let ordered = usable.sorted { a, b in
            let aMac = isThisMac(a, matched: mac)
            let bMac = isThisMac(b, matched: mac)
            if aMac != bMac { return aMac }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        var seen: Set<String> = []
        var result: [WorkflowHostChoice] = []
        for host in ordered {
            let machineID = trimmed(host.machineID)
            guard !machineID.isEmpty, seen.insert(machineID).inserted else { continue }
            let name = isThisMac(host, matched: mac) ? "This Mac" : (host.name.isEmpty ? machineID : host.name)
            result.append(WorkflowHostChoice(machineID: machineID, name: name))
        }
        return result
    }

    /// Ids to write for `hosts:`. Empty strings go, and a repeated id is kept once,
    /// in the order it was given. Empty means every host: the line comes out of the file.
    public static func cleaned(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty || !seen.insert(id).inserted { continue }
            result.append(id)
        }
        return result
    }

    private static func trimmed(_ id: String?) -> String {
        id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isThisMac(_ host: DaemonAPI.ControlHost, matched: DaemonAPI.ControlHost?) -> Bool {
        if let matched { return host.id == matched.id }
        return host.id == .mac
    }
}
