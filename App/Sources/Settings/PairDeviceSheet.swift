import AgentsKitCore
import SwiftUI

/// The code a phone scans to pair with the control plane (058, US5): a device code, good
/// for five minutes and one device.
///
/// The sheet asks for a fresh one each time it opens and lets it go when it closes, so a
/// code is only ever working while somebody is looking at it. It says who paired once a
/// client the control plane did not have before appears.
struct PairDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: ControlSettingsModel
    @State private var shown: DaemonAPI.ControlCodeShown?
    @State private var problem: String?
    /// Who was there when the code was made, so whoever it lets in can be named.
    @State private var before: Set<UUID> = []

    /// The client that arrived since the code was made: the code let it in, and is spent.
    private var paired: ClientRecord? {
        guard shown != nil else { return nil }
        return control.clients.first { !before.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a Device")
                .appText(.title)
            if let paired {
                Label("\(paired.name) is paired", systemImage: "checkmark.circle")
                    .appText(.reading)
                Text("It reaches your agents through the control plane, as a Device.")
                    .foregroundStyle(.secondary)
            } else if let shown {
                Text("Open Agents on your iPhone or iPad and scan this code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    // Wrapped, not cut short: the sheet is narrow and this is the instruction.
                    .fixedSize(horizontal: false, vertical: true)
                QRCode(text: shown.text)
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("Pairing code")
                    .accessibilityValue(shown.text)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(remaining(until: shown.expires, now: context.date))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if let problem {
                Text(problem)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView()
            }
            HStack {
                Spacer()
                Button(paired == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(paired == nil ? .cancelAction : .defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task {
            before = Set(control.clients.map(\.id))
            shown = await control.startCode(forHost: false, grant: .device)
            if shown == nil { problem = control.problem ?? "Couldn't make a pairing code." }
        }
        .onDisappear { Task { await control.stopCodes() } }
    }

    private func remaining(until expires: Date, now: Date) -> String {
        let seconds = max(0, Int(expires.timeIntervalSince(now)))
        if seconds == 0 { return "This code has run out. Close this and pair again." }
        return String(format: "Good for %d:%02d", seconds / 60, seconds % 60)
    }
}
