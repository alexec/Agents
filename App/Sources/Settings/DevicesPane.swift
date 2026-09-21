import AgentsKitCore
import SwiftUI

/// The devices that may be told when an agent needs somebody, and the ones waiting to be.
///
/// Approving is the one act of trust in the feature: from here on a sealed headline —
/// the project, the agent, what is wanted — goes to that device wherever it is.
/// Revoking is deletion: the record goes and whatever was waiting for the device is
/// discarded unread (021 FR-021). A device that has not let its own system show
/// notifications says so here (FR-023), because otherwise it would appear to work and
/// be chosen for silence.
struct DevicesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.devices.isEmpty {
                    Text("No device has asked to pair. Open Agents on your iPhone or iPad "
                         + "while it is on this network and it will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    DeviceLine(device: device)
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("An approved device is told when an agent needs you and your Mac is not "
                     + "in use. What it is told is sealed to that device alone. Revoking "
                     + "forgets the device; it can ask to pair again.")
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshDevices() }
    }
}

private struct DeviceLine: View {
    @Environment(AppModel.self) private var model
    let device: Device
    @State private var confirmingRevoke = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: device.kind == .iPad ? "ipad" : "iphone")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(standing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if device.isApproved {
                Button("Revoke", role: .destructive) { confirmingRevoke = true }
            } else {
                Button("Approve") { Task { await model.approve(device) } }
                    .buttonStyle(.borderedProminent)
                Button("Refuse") { Task { await model.revoke(device) } }
            }
        }
        .confirmationDialog("Revoke \(device.name)?", isPresented: $confirmingRevoke) {
            Button("Revoke", role: .destructive) { Task { await model.revoke(device) } }
        } message: {
            Text("It will not be told anything more, and anything waiting for it is thrown away.")
        }
    }

    /// One line that says the thing worth knowing about the device: waiting, unable to
    /// notify, or when it was last heard from.
    private var standing: String {
        guard device.isApproved else { return "Waiting for you to approve it" }
        switch device.mayNotify {
        case false:
            return "Approved, but notifications are off on the device — it will not be chosen"
        case nil:
            return "Approved; it has not said whether it can show notifications"
        case true?:
            if let seen = device.lastSeenAt {
                return "Approved · last heard from \(seen.formatted(.relative(presentation: .named)))"
            }
            return "Approved"
        }
    }
}
