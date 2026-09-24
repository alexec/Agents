import AgentsKitCore
import SwiftUI

/// The devices that may be told when an agent needs somebody.
///
/// A list, not a control: a device pairs by opening Agents on this network, and there
/// is nothing to approve or revoke here (Alex, 2026-09-21). What the pane is for is
/// FR-023 — a device that has not let its own system show notifications says so here,
/// because otherwise it would appear to work and be chosen for silence.
struct DevicesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.devices.isEmpty {
                    Text("No device has paired. Open Agents on your iPhone or iPad while it is "
                         + "on this network and it will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    DeviceLine(device: device)
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("A device is told when an agent needs you and your Mac is not in use. "
                     + "What it is told is sealed to that device alone.")
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshDevices() }
    }
}

private struct DeviceLine: View {
    let device: Device

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: device.kind == .iPad ? "ipad" : "iphone")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(standing)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// One line that says the thing worth knowing about the device: unable to notify,
    /// or when it was last heard from.
    private var standing: String {
        switch device.mayNotify {
        case false:
            return "Notifications are off on the device — it will not be chosen"
        case nil:
            return "Has not said whether it can show notifications"
        case true?:
            if let seen = device.lastSeenAt {
                return "Last heard from \(seen.formatted(.relative(presentation: .named)))"
            }
            return "Paired"
        }
    }
}
