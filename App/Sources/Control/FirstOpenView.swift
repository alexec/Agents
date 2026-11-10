import AgentsKitCore
import SwiftUI

/// What the window shows while it has no control plane (#4226). In the one app it asks
/// nothing: it sets up everything on this Mac, pairs itself, and the session list takes
/// its place. A step that fails shows one line with **Try Again** and **Show Details**, and
/// **Open Login Items** when macOS wants the person to allow the app there.
///
/// With the control plane on another machine, the window connects to that control plane with a code or a sign-in.
struct FirstOpenView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // The mark of a team (#1007): no prompt here, so the Blobs only look around.
            Huddle(promptFocused: false, pointer: nil)
            if let firstOpen = HostScenes.firstOpen {
                steps(firstOpen)
            } else {
                elsewhere
            }
        }
        // A floor on the width: laid out narrower, the words fixed to their height push
        // the window thousands of points tall.
        .frame(minWidth: 520, maxWidth: 640, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperGround()
        .sheet(isPresented: $connecting) { ConnectSheet().paperSheet() }
        // A walk's window pairs itself from AGENTS_CONTROL; nothing else sets it.
        .task { await model.pairForWalk() }
    }

    @ViewBuilder
    private func steps(_ firstOpen: FirstOpen) -> some View {
        Group {
            switch firstOpen.step {
            case .working(let words):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(words).appText(.reading).foregroundStyle(.secondary)
                }
            case .failed(let line, let details):
                failed(firstOpen, line: line, details: details)
            case .elsewhere:
                elsewhere
            }
        }
        .task { await firstOpen.run(pair: pair) }
        // The open question of the spec: while Login Items waits for the person, the app
        // looks again by itself and carries on once it is allowed.
        .task(id: firstOpen.needsApproval) {
            if firstOpen.needsApproval { await firstOpen.waitForApproval(pair: pair) }
        }
    }

    private func failed(_ firstOpen: FirstOpen, line: String, details: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(line, systemImage: "exclamationmark.triangle")
                    .appText(.reading)
                    .tinted(.attention)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if firstOpen.needsApproval {
                    Button("Open Login Items") { firstOpen.openLoginItems() }
                }
                Button(showingDetails ? "Hide Details" : "Show Details") { showingDetails.toggle() }
                Button("Try Again") { Task { await firstOpen.run(pair: pair) } }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
            }
            if showingDetails {
                Text(details)
                    .appText(.supporting).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show Logs") { firstOpen.showLogs() }.buttonStyle(.link)
            }
        }
    }

    /// The window's pairing with this Mac's own control plane, from the code the app made.
    private func pair(_ code: ControlCode) async throws {
        let membership = try await ControlConfig.pair(with: code)
        await model.adopt(.remote(membership))
    }

    /// The control plane is on another machine: the window connects to it.
    private var elsewhere: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect this window").appText(.title).fontWeight(.semibold)
            Text("This Mac’s agents report to a control plane on another machine. Connect this window to it with a pairing code or a sign-in.")
                .appText(.reading).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect…") { connecting = true }
                .buttonStyle(.paperProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
