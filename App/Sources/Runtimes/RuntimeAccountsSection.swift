import AgentsKitCore
import SwiftUI

/// The accounts added to a runtime (#840), in its sign-in sheet: each one's state, a way
/// to sign it in, and Remove; and Add Account. Only for a runtime whose sign-in is a folder
/// (Claude, Codex). The runtime's own sign-in above is the Default account.
struct RuntimeAccountsSection: View {
    @Environment(AppModel.self) private var model
    let runtimeID: String
    let name: String
    /// The runtime's sign-in methods, for one that signs an account in by itself (Codex).
    let methods: [ACP.AuthMethod]
    @Binding var terminalCommand: String?

    @State private var isAdding = false
    @State private var newName = ""
    @State private var addProblem: String?
    @State private var removing: AccountProfile?

    private var added: [AccountProfile] { model.accountProfiles.on(runtimeID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts").appText(.reading)
            Text("The sign-in above is \(name)’s Default account. Add another to choose it when you start a session.")
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(added) { account in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                        Text(account.state).appText(.fine)
                            .foregroundStyle((account.signedIn ? StateTint.none : StateTint.failure).style(or: .secondary))
                    }
                    Spacer()
                    if !account.signedIn {
                        Button("Sign In") { signIn(account) }
                            .buttonStyle(.paper)
                    }
                    Button("Remove…") { removing = account }
                        .buttonStyle(.plain)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            if isAdding {
                HStack {
                    TextField("Name, such as Work", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.paperProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") {
                        isAdding = false
                        addProblem = nil
                    }
                    .buttonStyle(.paper)
                }
                if let addProblem {
                    Text(addProblem).appText(.fine).foregroundStyle(StateTint.failure.style(or: .secondary))
                }
            } else {
                Button("Add Account…") {
                    newName = ""
                    isAdding = true
                }
                .buttonStyle(.paper)
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this account")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let account = removing else { return }
                Task { await model.removeAccount(account) }
            }
        } message: {
            let stopped = removing.map(model.agentsHolding(account:)) ?? []
            Text((stopped.isEmpty ? "Nothing is running on it." :
                    "This stops \(stopped.count) agent\(stopped.count == 1 ? "" : "s") mid-conversation.")
                 + " Its sign-in is deleted from this Mac.")
        }
    }

    private func add() {
        let text = newName.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            addProblem = await model.addAccount(runtimeID: runtimeID, name: text)
            if addProblem == nil { isAdding = false }
        }
    }

    /// Claude signs in from a terminal, with the account's folder in front of `claude`;
    /// Codex signs in by itself, as its own sign-in does.
    private func signIn(_ account: AccountProfile) {
        if let command = account.signInCommand {
            terminalCommand = command
            return
        }
        guard let method = methods.first else { return }
        Task { terminalCommand = await model.signIn(runtimeID: runtimeID, methodID: method.id, accountID: account.id) }
    }
}
