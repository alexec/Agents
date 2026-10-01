import AgentsKitCore
import SwiftUI

/// The code a phone scans to pair (security review, Phase 3).
///
/// It holds this Mac's key and a secret good for five minutes or one device. The sheet
/// asks for a fresh one each time it opens and lets it go when it closes, so a code is
/// only ever working while somebody is looking at it. It closes itself on the device
/// that used it appearing in the list.
struct PairDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code: DaemonAPI.ControlCodeShown?
    @State private var problem: String?
    @State private var paired: Device?
    @State private var known: Set<UUID> = []

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a Device")
                .appText(.title)
            if let paired {
                Label("\(paired.name) is paired", systemImage: "checkmark.circle")
                    .appText(.reading)
                Text("It can reach this Mac at home and away.")
                    .foregroundStyle(.secondary)
            } else if let code {
                Text("Open Agents on your iPhone or iPad, on this Wi-Fi, and scan this code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    // Wrapped, not cut short: the sheet is narrow and this is the instruction.
                    .fixedSize(horizontal: false, vertical: true)
                QRCode(text: code.text)
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("Pairing code")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(remaining(until: code.expires, now: context.date))
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
            known = Set(model.devices.map(\.id))
            do {
                code = try await model.startPairing()
            } catch let error as JSONRPCError {
                problem = error.message
            } catch {
                problem = "Couldn't make a pairing code: \(error.localizedDescription)"
            }
        }
        .onChange(of: model.devices) { _, devices in
            // The device that used the code: the one not here when the sheet opened.
            if paired == nil, let new = devices.first(where: { !known.contains($0.id) }) {
                paired = new
                code = nil
            }
        }
        .onDisappear {
            if paired == nil { Task { await model.stopPairing() } }
        }
    }

    private func remaining(until expires: Date, now: Date) -> String {
        let seconds = max(0, Int(expires.timeIntervalSince(now)))
        if seconds == 0 { return "This code has run out. Close this and pair again." }
        return String(format: "Good for %d:%02d", seconds / 60, seconds % 60)
    }
}
