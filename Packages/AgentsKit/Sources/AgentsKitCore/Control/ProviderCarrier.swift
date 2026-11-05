import Foundation

/// The machine that carries a machine provider (#3398, #3496): it runs the provider's server
/// and keeps its tokens, so the control plane keeps none. Add Provider and Edit… choose it,
/// and the card says which, as the web page's `machineProviders.ts` does.
public enum ProviderCarrier {
    /// The machines that may carry a provider: the person's own, online and able to; `own` (the client's own machine) first, then by name.
    public static func choices(_ hosts: [DaemonAPI.ControlMachine], person: String?,
                               own: MachineRef?) -> [DaemonAPI.ControlMachine] {
        hosts
            .filter { host in
                host.answers && host.has(Capability.providersCarry1)
                    && (person == nil || host.owner == nil || host.owner == person)
            }
            .sorted { a, b in
                if (a.id == own) != (b.id == own) { return a.id == own }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// What Add Provider and Edit… start at: the one it has, when it can still carry it, else
    /// the first choice.
    public static func start(_ provider: DaemonAPI.ProviderSummary?, choices: [DaemonAPI.ControlMachine]) -> MachineRef? {
        if let current = provider?.machine, choices.contains(where: { $0.id == current }) { return current }
        return choices.first?.id
    }

    /// Whether Edit… moves the provider to `chosen`: then its secrets must be given again.
    public static func moves(_ provider: DaemonAPI.ProviderSummary, to chosen: MachineRef?) -> Bool {
        guard let chosen else { return false }
        return chosen != provider.machine
    }

    /// "Carried by alex-mac", on its card; nil for one made before #3398.
    public static func carriedBy(_ provider: DaemonAPI.ProviderSummary) -> String? {
        guard provider.machine != nil else { return nil }
        return "Carried by \(provider.machineName ?? "a machine")"
    }

    /// On its card while its machine is offline.
    public static func offline(_ provider: DaemonAPI.ProviderSummary) -> String? {
        guard provider.machineOffline == true else { return nil }
        return "\(provider.machineName ?? "Its machine") is offline: its machines can’t be started or stopped until it is back."
    }

    /// On its card when no machine carries it (made before #3398).
    public static let notCarried = "No machine carries it: choose one with Edit…, and give its secrets again."

    /// Under the form: where its tokens and keys go.
    public static func secretsFoot(_ machine: String?) -> String {
        "Tokens and keys go to \(machine ?? "the machine that carries it"), which keeps them. The control plane keeps none."
    }

    /// Under Carried by in Edit…, when another machine is chosen.
    public static let movedNote = "Its secrets stay on the machine that carried it: give them again."

    /// In place of the menu when none of the person's machines can carry it.
    public static let noneOnline = "None of your machines is online to carry it: its server runs there, with its secrets. Start one, then add it."
}
