import AgentsKitCore
import SwiftUI

/// The accounts added to a runtime (#840), in its sign-in sheet: each one's state, a way
/// to sign it in, and Remove; and Add Account, for a runtime whose sign-in is a folder
/// (Claude, Codex). Then the organisation's accounts (#999), which only it can remove, and
/// **Reaches the Model By**: the account new sessions use (spec FR-024).
struct RuntimeAccountsSection: View {
    @Environment(AppModel.self) private var model
    let runtimeID: String
    let name: String
    /// The runtime's sign-in methods, for one that signs an account in by itself (Codex).
    let methods: [ACP.AuthMethod]
    /// Whether the runtime keeps its sign-in in a folder, so the person can add an account.
    let takesMore: Bool
    @Binding var terminalCommand: String?

    @State private var isAdding = false
    @State private var newName = ""
    @State private var addProblem: String?
    @State private var removing: AccountProfile?
    @State private var defaultProblem: String?

    private var added: [AccountProfile] { model.accountProfiles.added(to: runtimeID) }
    private var organisation: [AccountProfile] { model.accountProfiles.organisation(runtimeID) }
    private var choices: AccountChoices {
        AccountChoices(runtimeID: runtimeID, profiles: model.accountProfiles, policy: model.policyState?.policy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts").appText(.reading)
            if takesMore {
                Text("The sign-in above is \(name)’s own. Add another account to choose it when you start a session.")
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            // The organisation's (#999): its name and where it is from, never a key or an address.
            ForEach(organisation) { account in
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                    Text(account.state).appText(.fine).foregroundStyle(.secondary)
                }
            }
            if takesMore { adding }
            if choices.shows { reachesTheModelBy }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this account")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let account = removing else { return }
                Task { await model.removeAccount(account) }
            }
        } message: {
            Text(AccountWords.removeMessage(stopping: removing.map(model.agentsHolding(account:))?.count ?? 0,
                                            from: "this Mac"))
        }
    }

    /// Add Account, and its name field while it is open.
    @ViewBuilder private var adding: some View {
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

    /// The account new sessions use: the runtime's own sign-in, or one of its accounts.
    /// A choice the organisation's policy refuses is dimmed, with its line.
    private var reachesTheModelBy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(OrgAccountWords.reachesTheModelBy).appText(.reading).padding(.top, 8)
            let current = choices.defaultAccount
            SelectChoice(title: AccountProfile.defaultName, description: nil, isChosen: current == nil,
                         setBy: choices.ownSetBy) { setDefault(nil) }
            ForEach(choices.accounts) { account in
                SelectChoice(title: account.name, description: account.isOrganisation ? account.state : nil,
                             isChosen: current?.id == account.id, setBy: account.setBy) { setDefault(account.id) }
            }
            Text(defaultProblem ?? OrgAccountWords.reachesFoot)
                .appText(.fine)
                .foregroundStyle(defaultProblem == nil ? AnyShapeStyle(.secondary) : StateTint.failure.style(or: .secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setDefault(_ accountID: String?) {
        Task { defaultProblem = await model.setDefaultAccount(runtimeID: runtimeID, accountID: accountID) }
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
