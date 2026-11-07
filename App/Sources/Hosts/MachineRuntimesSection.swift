import AgentsKitCore
import SwiftUI

/// The runtimes installed on a machine (#3629), as a section of its page: each with whether
/// it is there and, where the machine says, signed in. **Install** and **Update** on This Mac,
/// whose daemon installs from the app (048); a server installs its runtimes when it is set
/// up, and refuses an install from a client. **Sign In…** on This Mac opens the runtime's
/// sign-in sheet. Accounts and allowances are the person's, not the machine's: they stay in
/// Runtimes. The web page draws the same in Web/src/views/MachinePage.tsx.
struct MachineRuntimesSection: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef

    /// The runtime whose sign-in sheet is open.
    @State private var signingIn: String?

    private var runtimes: [RuntimeStatus] { model.runtimes(on: host) }

    var body: some View {
        Section {
            if runtimes.isEmpty {
                Text("No runtimes known yet.").foregroundStyle(.secondary)
            }
            ForEach(runtimes) { status in
                LabeledContent {
                    HStack(spacing: 6) { actions(status) }
                } label: {
                    Text(status.runtime.name)
                    Text(status.machineLine)
                }
            }
        } header: {
            Text("Runtimes")
        } footer: {
            Text("What agents can start on here. Your accounts and allowances are in Your setup.")
                .foregroundStyle(.secondary)
        }
        .task(id: host) {
            if host == .mac { await model.refreshRuntimes() } else { await model.refreshServerRuntimes(host) }
        }
        .sheet(isPresented: Binding(get: { signingIn != nil }, set: { if !$0 { signingIn = nil } })) {
            if let signingIn {
                RuntimeAccountView(runtimeID: signingIn)
                    .paperSheet()
            }
        }
    }

    @ViewBuilder
    private func actions(_ status: RuntimeStatus) -> some View {
        if host == .mac {
            if case .needsSignIn = status.availability {
                Button("Sign In…") { signingIn = status.id }
                    .controlSize(.small)
            }
            if status.offersInstall || status.outdated {
                Button(status.outdated ? "Update" : "Install") {
                    Task { await model.installRuntime(status.id) }
                }
                .controlSize(.small)
            }
        }
    }
}
