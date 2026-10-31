import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines ▸ This Mac ▸ Updates (#2178): whether Agents Host updates itself to
/// the release the control plane names, and where that is.
///
/// What the host holds, not what was last clicked. Nil from a host that cannot update
/// itself (one older than the method), and nothing is drawn.
struct SelfUpdateSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let update = model.selfUpdate {
            Section {
                Toggle("Update Agents Host automatically", isOn: Binding(
                    get: { model.selfUpdate?.autoUpdate ?? false },
                    set: { on in Task { await model.setAutoUpdate(on) } }))
                .disabled(update.state == .cannot)
                LabeledContent("Version", value: update.running)
                Text(Self.line(update))
                    .appText(.fine)
                    .foregroundStyle((update.state == .failed ? StateTint.failure : .none).style(or: .secondary))
            } header: {
                Text("Updates")
            } footer: {
                Text("Agents Host updates to the release your control plane runs. It never asks for an administrator password, and it restarts only when no agent is in a turn.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .paperListRow()
        }
    }

    static func line(_ update: DaemonAPI.SelfUpdate) -> String {
        let release = update.release ?? ""
        switch update.state {
        case .upToDate: return "Up to date."
        case .off: return release.isEmpty ? "Off." : "Off. Your control plane runs \(release)."
        case .downloading: return "Downloading \(release)…"
        case .waiting: return "\(release) is ready. It installs when no agent is in a turn."
        case .restarting: return "Installed \(release). Restarting…"
        case .failed, .cannot: return update.message ?? "Agents Host cannot update itself."
        }
    }
}
