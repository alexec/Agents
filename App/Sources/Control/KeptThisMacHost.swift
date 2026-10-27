import AgentsKitCore
import Foundation

/// This Mac's host as the control plane last listed it, kept for the next launch (#1481).
/// With a control plane elsewhere, this Mac's host has an id of its own, and the window
/// learns it only from the control plane's list. Kept, a window that starts while the
/// control plane is away still makes a client for it, and reaches it over its local socket
/// (#1118). Kept per control plane, by its key, so another pairing never uses it.
enum KeptThisMacHost {
    static let defaultsKey = "control.thisMacHost"

    private struct Kept: Codable {
        var controlKey: Data
        var host: DaemonAPI.ControlMachine
    }

    /// The host kept for the control plane with `controlKey`, if it is on this machine.
    static func read(controlKey: Data, machine: String = MachineID.current, from defaults: UserDefaults) -> DaemonAPI.ControlMachine? {
        guard let data = defaults.data(forKey: defaultsKey),
              let kept = try? JSONDecoder().decode(Kept.self, from: data),
              kept.controlKey == controlKey, kept.host.machineID == machine, kept.host.id != .mac else { return nil }
        return kept.host
    }

    /// The host on this machine in `listed`, kept; none there forgets the one kept.
    static func keep(from listed: [DaemonAPI.ControlMachine], controlKey: Data, machine: String = MachineID.current,
                     in defaults: UserDefaults) {
        guard let mine = listed.first(where: { $0.machineID == machine && $0.runsAgents && $0.id != .mac }) else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(Kept(controlKey: controlKey, host: mine)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Forget This Mac (#344): the pairing goes, and the host kept for it.
    static func forget(in defaults: UserDefaults) { defaults.removeObject(forKey: defaultsKey) }
}
