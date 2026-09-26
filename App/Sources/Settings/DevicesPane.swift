import AgentsKitCore
import SwiftUI

/// The devices that may be told when an agent needs somebody.
///
/// A device pairs by scanning the code this pane shows (security review, Phase 3, which
/// replaced pairing by just opening Agents on this network). The pane says, per FR-023,
/// when a device has not let its own system show notifications, because otherwise it
/// would appear to work and be chosen for silence. A paired device can reach this Mac
/// from anywhere, so each one can be forgotten: both of its links end at once.
struct DevicesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.devices.isEmpty {
                    Text("No device has paired. Choose Pair a Device and scan the code with Agents "
                         + "on your iPhone or iPad.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    DeviceLine(device: device) { forgetting = device }
                }
                Button("Pair a Device…") { pairing = true }
            } header: {
                Text("Devices")
            } footer: {
                Text("A device is told when an agent needs you and your Mac is not in use. "
                     + "What it is told is sealed to that device alone.")
            }
            .paperListRow()
        }
        .paperForm()
        .task { await model.refreshDevices() }
        .sheet(isPresented: $pairing) { PairDeviceSheet() }
        .confirmationDialog(forgetting.map { "Forget \($0.name)?" } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { device in
            Button("Forget", role: .destructive) {
                Task { await model.forgetDevice(device.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It stops reaching this Mac, at home and away, until you pair it again.")
        }
    }

    @State private var forgetting: Device?
    @State private var pairing = false
}

private struct DeviceLine: View {
    let device: Device
    let forget: () -> Void

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
            Button("Forget…", action: forget)
                .buttonStyle(.borderless)
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
