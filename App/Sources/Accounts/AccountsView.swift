import AgentsKitCore
import SwiftUI

/// Your setup ▸ Accounts (#3967): the person's outside accounts (gitlab.com, AWS, Slack…), the
/// accounts part of their settings, which the control plane keeps and sends to each machine of
/// theirs as it does their secrets (#1760). A record holds no secret, only the name of one in
/// Your setup ▸ Secrets. Agents read and add them with manage_accounts. The web page draws the
/// same in `Web/src/views/Accounts.tsx`.
struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var project = ""
    @State private var editing: DaemonAPI.OutsideAccount?
    @State private var isAdding = false
    @State private var removing: DaemonAPI.OutsideAccount?
    @State private var problem: String?

    private var state: UserScopeState { model.userScope }
    private var control: DaemonClient? { model.controlRequests }
    private var all: [DaemonAPI.OutsideAccount] {
        (try? state.settings?.accounts?.decode(DaemonAPI.OutsideAccounts.self))?.accounts ?? []
    }

    var body: some View {
        let shown = AccountsWords.of(all, project: project)
        Form {
            if let problem = problem ?? state.problem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            Section {
                let projects = AccountsWords.projects(all)
                if !projects.isEmpty {
                    Picker("Project", selection: $project) {
                        Text("All").tag("")
                        ForEach(projects, id: \.self) { Text($0).tag($0) }
                    }
                }
                ForEach(shown) { account in row(account) }
                Button("Add Account…") { isAdding = true }
                    .disabled(control == nil)
            } footer: {
                Text(AccountsWords.foot(shown)).appText(.fine).foregroundStyle(.secondary)
            }
            .paperListRow()
        }
        .paperForm()
        .task(id: control != nil) { await state.load(control) }
        .sheet(isPresented: $isAdding) {
            AccountSheet(account: nil) { await save(adding: $0, replacing: nil) }.paperSheet()
        }
        .sheet(item: $editing) { account in
            AccountSheet(account: account) { await save(adding: $0, replacing: account) }.paperSheet()
        }
        .confirmationDialog(removing.map { "Remove \($0.service)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { account in
            Button("Remove", role: .destructive) { Task { await save(adding: nil, replacing: account) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Only the record goes. The account itself, and its secrets, stay.")
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(AccountsWords.title)
    }

    private func row(_ account: DaemonAPI.OutsideAccount) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(account.service)
                Spacer()
                Text(AccountsWords.cost(account)).foregroundStyle(.secondary).monospacedDigit()
                Menu {
                    Button("Edit…") { editing = account }
                    Button("Remove…", role: .destructive) { removing = account }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .fixedSize()
                .accessibilityLabel("\(account.service) actions")
            }
            Text(AccountsWords.detail(account)).appText(.fine).foregroundStyle(.secondary)
            if let soon = AccountsWords.expiresSoon(account, now: Date()) {
                Text(soon).appText(.fine).tinted(.attention)
            }
        }
    }

    /// The accounts with `replacing` taken out and `adding` put in its place, set as the part.
    private func save(adding: DaemonAPI.OutsideAccount?, replacing: DaemonAPI.OutsideAccount?) async -> String? {
        var accounts = all
        let at = replacing.flatMap { old in accounts.firstIndex { $0.id == old.id } }
        if let at { accounts.remove(at: at) }
        if let adding { accounts.insert(adding, at: at ?? accounts.endIndex) }
        guard let value = try? JSONValue.encoding(DaemonAPI.OutsideAccounts(accounts: accounts)) else { return "The accounts could not be written." }
        let failed = await state.set(.accounts, to: value, on: control)
        if adding == nil { problem = failed }
        return failed
    }
}

struct AccountsRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AccountsWords.title).foregroundStyle(.primary)
            Spacer()
        }
        .help("Your outside accounts, for every machine and agent of yours")
    }
}

/// Add Account… and Edit…: the record's fields, each optional but the service.
private struct AccountSheet: View {
    let account: DaemonAPI.OutsideAccount?
    let save: (DaemonAPI.OutsideAccount) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String] = [:]
    @State private var problem: String?
    @State private var saving = false

    private func field(_ label: String, _ key: String, _ prompt: String) -> some View {
        TextField(label, text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }), prompt: Text(prompt))
            .autocorrectionDisabled()
    }

    var body: some View {
        Form {
            Section {
                field("Service", "service", "gitlab.com")
                field("Address", "address", "name@example.com")
                field("Plan", "plan", "Free")
                field("Monthly cost (USD)", "cost", "0")
                field("Card", "card", "The card's name in Secrets")
                field("Secret", "secret", "The token's name in Secrets")
                field("Two-factor", "twoFactor", "TOTP, passkey, SMS")
                field("Issue", "issue", "#12")
                field("Made", "made", "YYYY-MM-DD")
                field("Token expires", "tokenExpires", "YYYY-MM-DD")
                field("Projects", "projects", "None is all, else names with commas")
                field("Notes", "notes", "Where the password is")
            } header: {
                Text(account == nil ? "Add an Account" : "Edit \(account!.service)")
            } footer: {
                Text(problem ?? AccountsWords.noSecrets).appText(.fine)
                    .tinted(problem == nil ? .none : .failure)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(account == nil ? "Add" : "Save") {
                    Task {
                        saving = true
                        problem = await save(AccountsWords.account(fields))
                        saving = false
                        if problem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || (fields["service"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .rowButtons()
        }
        .paperForm()
        .frame(minWidth: 400)
        .onAppear { if let account { fields = AccountsWords.fields(account) } }
    }
}
