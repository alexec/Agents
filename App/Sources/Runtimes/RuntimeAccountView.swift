import AgentsKit
import SwiftUI

/// Whether a runtime can be used, and what to do when it cannot.
///
/// "Installed but not signed in" is a state the app has always been able to detect and
/// never been able to fix. Copilot even hands over the exact command, which is better
/// advice than any we could invent, so where a terminal is needed that is what is shown.
struct RuntimeAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let runtimeID: String

    @State private var terminalCommand: String?
    @State private var isConfirmingSignOut = false

    private var account: RuntimeAccount { model.accounts[runtimeID] ?? RuntimeAccount(runtimeID: runtimeID) }
    private var name: String { RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(name).font(.headline)
            Text(state)
                .font(.callout)
                .foregroundStyle(account.state == .needsSignIn ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))

            if account.state != .ready, !account.authMethods.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(account.authMethods, id: \.id) { method in
                        Button(method.name ?? method.id) {
                            Task { terminalCommand = await model.signIn(runtimeID: runtimeID,
                                                                        methodID: method.id) }
                        }
                        .buttonStyle(.glassProminent)
                        if let description = method.description {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let terminalCommand {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(name) signs in from a terminal. Run this:")
                        .font(.callout)
                    Text(terminalCommand)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Button("Open Terminal") { openTerminal(with: terminalCommand) }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(terminalCommand, forType: .string)
                        }
                        Button("I have done it") {
                            self.terminalCommand = nil
                            Task { await model.refreshAccounts() }
                        }
                    }
                    .buttonStyle(.glass)
                }
            }

            if !account.providers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Who answers").font(.callout)
                    ForEach(account.providers, id: \.id) { provider in
                        Button {
                            Task { await model.setProvider(runtimeID: runtimeID, providerID: provider.id) }
                        } label: {
                            HStack {
                                Text(provider.id == account.currentProviderID ? "✓" : " ")
                                    .font(.footnote.monospaced())
                                Text(provider.name ?? provider.id)
                                if let wire = provider.protocol {
                                    Text(wire).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                if account.canLogOut, account.state == .ready {
                    Button("Sign out") { isConfirmingSignOut = true }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await model.refreshAccounts() }
        .confirmationDialog("Sign out of \(name)?", isPresented: $isConfirmingSignOut) {
            Button("Sign out", role: .destructive) {
                Task { await model.signOut(runtimeID: runtimeID) }
            }
        } message: {
            let stopped = model.agentsHolding(runtimeID: runtimeID)
            Text(stopped.isEmpty
                 ? "Nothing is running on it."
                 : "This stops \(stopped.count) agent\(stopped.count == 1 ? "" : "s") mid-conversation.")
        }
    }

    private var state: String {
        switch account.state {
        case .ready: return "Signed in and ready"
        case .needsSignIn: return "Installed, and needs signing in"
        case .unknown: return "Not asked yet"
        }
    }

    private func openTerminal(with command: String) {
        // The command goes on the clipboard as well, because a terminal that opens in
        // the wrong folder is still one keystroke from working.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Terminal.app"))
    }
}
