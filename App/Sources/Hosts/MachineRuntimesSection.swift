import AgentsKitCore
import SwiftUI

/// The runtimes installed on a machine (#3629), as a section of its page: one line each, its
/// version and, where the machine says, signed in. Only the installed ones (#3743): Your setup
/// lists every runtime. **Update** on This Mac, whose daemon installs from the app (048), and
/// **Install** on the ones it can install, closed under Not installed: this page is where
/// This Mac installs one after start-up. A server installs its runtimes when it is set up,
/// and refuses an install from a client. **Sign In…** on This Mac opens the runtime's sign-in sheet.
/// Accounts and allowances are the person's, not the machine's: they stay in Your setup.
/// The web page draws the same in Web/src/views/MachinePage.tsx.
struct MachineRuntimesSection: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef

    /// The runtime whose sign-in sheet is open.
    @State private var signingIn: String?

    private var runtimes: [RuntimeStatus] { model.runtimes(on: host).filter(\.isInstalled) }
    /// What This Mac can install, closed until the person opens it.
    private var installable: [RuntimeStatus] {
        host == .mac ? model.runtimes(on: host).filter { !$0.isInstalled && $0.offersInstall } : []
    }

    var body: some View {
        Section {
            if runtimes.isEmpty {
                Text("None installed here yet.").foregroundStyle(.secondary)
            }
            ForEach(runtimes) { status in row(status) }
            if !installable.isEmpty {
                DisclosureGroup("Not installed (\(installable.count))") {
                    ForEach(installable) { status in row(status) }
                }
            }
            Button("Every runtime, your accounts and allowances, in Your setup") { model.showRuntimes() }
                .buttonStyle(.link)
                .appText(.supporting)
        } header: {
            Text("Runtimes")
                .help("What agents can start on here")
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

    private func row(_ status: RuntimeStatus) -> some View {
        LabeledContent {
            HStack(spacing: 6) { actions(status) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.runtime.name)
                Text(status.machineLine).appText(.supporting).foregroundStyle(.secondary).lineLimit(1)
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
