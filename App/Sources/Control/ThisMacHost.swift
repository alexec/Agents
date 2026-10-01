import AgentsKitCore
import Foundation

/// Which host is on this Mac (058, R11).
///
/// `.mac` used to mean the machine this window is on. A control plane's hosts are
/// just hosts, and the one whose folders this window may open in Finder is the one
/// that reported this Mac's machine id. Before the control plane's list arrives, it is
/// still `.mac`.
enum ThisMacHost {
    /// `hosts` nil: no list yet, so this Mac is `.mac`. A list that names this machine:
    /// that host. Otherwise this Mac is not a host.
    static func resolve(_ hosts: [DaemonAPI.ControlHost]?, machine: String = MachineID.current) -> HostID? {
        guard let hosts else { return .mac }
        return hosts.first(where: { $0.machineID == machine && $0.relay != true })?.id
    }
}
