import AgentsKitCore
import SwiftUI

/// What the clients say when a part is too old for another (#1748,
/// docs/explanation/versions.md), once for both apps; the web page says the same.
enum UpdateWords {
    /// Beside a feature that the host does not have.
    static let hostNeedsUpdate = "This machine needs an update to do this."

    /// "Agents 0.9 (Go)" for a host written in Go (#1134), so the one being tried is never
    /// taken for the other; the Swift host says only its version.
    static func version(_ host: DaemonAPI.ControlMachine) -> String {
        host.implementation == "go" ? "Agents \(host.version) (Go)" : "Agents \(host.version)"
    }

    /// A host's state, as a host row says it: "Needs an update" for `needsUpdate`, which
    /// `capitalized` would make "Needsupdate".
    static func state(_ host: DaemonAPI.ControlMachine) -> String {
        if host.state == "needsUpdate" { return "Needs an update" }
        // A delete's backup, before its workspace goes (#1815).
        if host.state == "stopping", host.workspace?.phase == "backing up" { return "Backing up to delete" }
        return host.state.capitalized
    }

    /// When this app does not have what the control plane requires of a client: it then
    /// answers every call but `control/status` with -32008. Nil when it has it.
    static func appMissing(_ status: DaemonAPI.ControlStatus?) -> String? {
        let mine = Capability.declared["client"] ?? []
        guard let status, let required = status.required?.client else { return nil }
        let missing = required.filter { !mine.contains($0) }
        guard !missing.isEmpty else { return nil }
        return "Update this app to Agents \(status.version) to use this control plane. It does not have \(missing.joined(separator: ", "))."
    }

    /// The second line of a host that does not have the control plane's required
    /// capabilities: what to update it to, and the names it is missing. Nil for one that has them.
    static func missing(_ host: DaemonAPI.ControlMachine, controlVersion: String?) -> String? {
        guard let missing = host.missing, !missing.isEmpty else { return nil }
        let to = controlVersion.map { " to Agents \($0)" } ?? ""
        return "Update this machine\(to). It does not have \(missing.joined(separator: ", "))."
    }
}

/// A pane whose feature the host does not have (#1748): said in its place, with no call sent.
struct HostNeedsUpdateView: View {
    var body: some View {
        ContentUnavailableView("Needs an Update", systemImage: "arrow.down.circle",
                               description: Text(UpdateWords.hostNeedsUpdate))
    }
}
