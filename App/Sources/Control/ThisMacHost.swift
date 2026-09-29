import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import Foundation

/// Which host is on this Mac (058, R11).
///
/// `.mac` used to mean the machine this window is on. A control plane's hosts are
/// just hosts, and the one whose folders this window may open in Finder is the one
/// that reported this Mac's machine id. With no control plane, it is still `.mac`.
enum ThisMacHost {
    /// `hosts` nil: there is no control plane, so this Mac is `.mac`.
    /// An empty list, and the control plane itself is on this Mac: still `.mac`, until
    /// the list arrives. A list that names this machine: that host. Otherwise this Mac
    /// is not a host, and nothing here is read off this disk.
    static func resolve(_ hosts: [DaemonAPI.ControlHost]?, controlPlaneIsHere: Bool,
                        machine: String = MachineID.current) -> HostID? {
        guard let hosts else { return .mac }
        if let id = hosts.first(where: { $0.machineID == machine })?.id { return id }
        if hosts.isEmpty, controlPlaneIsHere { return .mac }
        return nil
    }
}
