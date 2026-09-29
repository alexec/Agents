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

    private var launch: RuntimeLaunch { RuntimeLaunchCatalog.launch(for: runtimeID) }
    private var notice: RuntimeLaunch.SignInNotice? { launch.signInNotice }

    /// Ready or not, a runtime that signs in one provider at a time (049: OpenCode) keeps
    /// offering the next one.
    private var offersSignIn: Bool {
        !account.authMethods.isEmpty && (account.state != .ready || launch.providerSignOutWord != nil)
    }

    /// How to sign a provider out, for a runtime with no sign-out the app can call.
    private var providerSignOut: String? {
        account.authMethods.compactMap(\.terminalCommand).first.flatMap(launch.providerSignOutCommand(from:))
    }

    /// What servers borrow of this Mac's sign-in, and what stays here and why (049 D7), for a
    /// runtime whose server runs borrow it. Nil with no servers.
    private var serversNote: String? {
        guard !model.hosts.isEmpty, let reading = MacFileSignIn(runtimeID: runtimeID)?.read() else { return nil }
        if reading.unreadable { return "Servers can’t borrow this Mac’s \(name) sign-in: Agents couldn’t read it." }
        var said: [String] = []
        if !reading.lent.isEmpty {
            said.append("Servers borrow this Mac’s \(Self.names(reading.lent)) \(reading.lent.count == 1 ? "key" : "keys") for each run, and keep nothing.")
        } else {
            said.append("Servers use \(name)’s free models until this Mac signs in to a provider with a key.")
        }
        if !reading.kept.isEmpty {
            said.append("\(Self.names(reading.kept)) \(reading.kept.count == 1 ? "stays" : "stay") on this Mac: a browser sign-in renews itself, and a server renewing it would leave this Mac’s copy stale.")
        }
        return said.joined(separator: " ")
    }

    private static func names(_ providers: [String]) -> String {
        providers.map(providerName).formatted(.list(type: .and))
    }

    /// How a provider is named, from the id its sign-in file keys it by: the name OpenCode's
    /// own model menu shows for the common ones, else the id with its first letter raised.
    static func providerName(_ id: String) -> String {
        let known = ["anthropic": "Anthropic", "openai": "OpenAI", "github-copilot": "GitHub Copilot",
                     "google": "Google", "groq": "Groq", "openrouter": "OpenRouter", "xai": "xAI",
                     "mistral": "Mistral", "deepseek": "DeepSeek", "opencode": "OpenCode Zen",
                     "amazon-bedrock": "Amazon Bedrock", "azure": "Azure", "vercel": "Vercel"]
        if let name = known[id] { return name }
        let words = id.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(name).appText(.reading).fontWeight(.semibold)
            Text(state)
                .appText(.supporting)
                .foregroundStyle((account.state == .needsSignIn ? StateTint.failure : .none)
                                    .style(or: .secondary))

            if offersSignIn {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(account.orderedAuthMethods, id: \.id) { method in
                        Button(method.name ?? method.id) {
                            Task { terminalCommand = await model.signIn(runtimeID: runtimeID,
                                                                        methodID: method.id) }
                        }
                        .buttonStyle(.paperProminent)
                        // What the runtime says, minus anything telling the user to run a
                        // command. See ACP.AuthMethod.guidance: Cursor's advice names a
                        // binary that on this Mac belongs to Grok.
                        if let guidance = method.guidance {
                            Text(guidance).appText(.fine).foregroundStyle(.secondary)
                        }
                    }
                    // Words the runtime's vendor wants in front of the person at the moment
                    // of choosing (049: Antigravity's terms on third-party tools). Once, under
                    // the choices, when any of them is one it is about.
                    if let notice, account.orderedAuthMethods.contains(where: { notice.methods.contains($0.id) }) {
                        Text(notice.text).appText(.fine).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(notice.linkTitle, destination: notice.link).appText(.fine)
                    }
                    if let providerSignOut {
                        Text("To sign a provider out, run \(providerSignOut) in a terminal.")
                            .appText(.fine).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let servers = serversNote {
                        Text(servers).appText(.fine).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let terminalCommand {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(name) signs in from a terminal. Run this:")
                        .appText(.reading)
                    Text(terminalCommand)
                        .appText(.code)
                        .textSelection(.enabled)
                        .padding(8)
                        .paperWell(in: RoundedRectangle(cornerRadius: 6))
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
                    .buttonStyle(.paper)
                }
            }

            if !account.providers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Who answers").appText(.reading)
                    ForEach(account.providers, id: \.id) { provider in
                        HStack {
                            Button {
                                Task { await model.setProvider(runtimeID: runtimeID, providerID: provider.id) }
                            } label: {
                                HStack {
                                    Text(provider.id == account.currentProviderID ? "✓" : " ")
                                        .appText(.code)
                                    Text(provider.name ?? provider.id)
                                    if let wire = provider.protocol {
                                        Text(wire).appText(.fine).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            // Only where the runtime can take it: one it marks required
                            // stays on, and one it has not configured has nothing to stop.
                            if provider.canBeDisabled, provider.configured != false {
                                Button("Turn off") {
                                    Task { await model.disableProvider(runtimeID: runtimeID, providerID: provider.id) }
                                }
                                .buttonStyle(.plain)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack {
                if account.canLogOut, account.state == .ready {
                    Button("Sign out") { isConfirmingSignOut = true }
                        .buttonStyle(.paper)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.paper)
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
        case .ready:
            // The runtime's own word for the account, where it says (`_auth/status_update`).
            guard let signedInAs = account.signedInAs else { return "Signed in and ready" }
            return "Signed in with \(signedInAs.label), and ready"
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
