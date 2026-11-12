import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Accounts (#3967, #3998): the person's outside accounts (gitlab.com, AWS,
/// Slack…), the accounts part of their settings, which the control plane keeps and sends to each
/// machine of theirs as it does their secrets (#1760). A record holds no secret, only the name of
/// one in Settings ▸ You ▸ Secrets. Agents read and add them with manage_accounts. The window and
/// the Remote (#4033) draw it; the web page draws the same in `Web/src/views/Accounts.tsx`. Each
/// row has the last 4 of the secret it names, when it was made, edited and last used, and a
/// warning when that secret is not backed up (#4160), as the Secrets rows have (#4159).
struct AccountsPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let state: UserScopeState
    /// Each of the person's machines' names, by id, for the not-backed-up warning.
    var machineNames: [String: String] = [:]

    @State private var project = ""
    @State private var editing: DaemonAPI.OutsideAccount?
    @State private var isAdding = false
    @State private var removing: DaemonAPI.OutsideAccount?
    @State private var problem: String?
    /// The control plane's `control/status`, for its capabilities (#4190); nil until it comes.
    @State private var status: DaemonAPI.ControlStatus?

    private var all: [DaemonAPI.OutsideAccount] {
        (try? state.settings?.accounts?.decode(DaemonAPI.OutsideAccounts.self))?.accounts ?? []
    }

    var body: some View {
        let shown = AccountsWords.of(all, project: project)
        let secrets = state.secrets?.secrets ?? []
        let only = SecretInfoWords.onlyMachine(secrets)
        Form {
            if let problem = problem ?? state.problem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            // An older control plane refuses the accounts part, so the pane offers none (#4190).
            if let refusal = AccountsWords.refusal(status) {
                Section {
                    Text(refusal).appText(.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            } else if status != nil {
                if let only, all.contains(where: { AccountsWords.secretName($0) != nil }) {
                    Section {
                        Label(SecretInfoWords.onlyMachineLine(only, names: machineNames), icon: "exclamationmark.triangle")
                            .appText(.supporting).tinted(.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .paperListRow()
                }
                accounts(shown, secrets: secrets, oneMachine: only != nil)
            }
        }
        .paperForm()
        .task(id: control != nil) { await load() }
        .refreshable { await load() }
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
    }

    private func accounts(_ shown: [DaemonAPI.OutsideAccount], secrets: [DaemonAPI.UserSecretRow], oneMachine: Bool) -> some View {
        Section {
            let projects = AccountsWords.projects(all)
            if !projects.isEmpty {
                Picker("Project", selection: $project) {
                    Text("All").tag("")
                    ForEach(projects, id: \.self) { Text($0).tag($0) }
                }
            }
            ForEach(shown) { account in row(account, secrets: secrets, oneMachine: oneMachine) }
            Button("Add Account…") { isAdding = true }
                .disabled(control == nil)
        } footer: {
            Text(AccountsWords.foot(shown)).appText(.fine).foregroundStyle(.secondary)
        }
        .paperListRow()
    }

    /// The control plane's capabilities first, then the person's settings.
    private func load() async {
        if let control {
            status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        }
        await state.load(control)
    }

    private func row(_ account: DaemonAPI.OutsideAccount, secrets: [DaemonAPI.UserSecretRow], oneMachine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(account.service)
                Spacer()
                Text(AccountsWords.cost(account)).foregroundStyle(.secondary).monospacedDigit()
                Text(AccountsWords.hint(account, rows: secrets)).appText(.code).foregroundStyle(.secondary)
                Menu {
                    Button("Edit…") { editing = account }
                    Button("Remove…", role: .destructive) { removing = account }
                } label: {
                    Image(icon: "ellipsis.circle")
                }
                .fixedSize()
                .accessibilityLabel("\(account.service) actions")
            }
            Text(AccountsWords.detail(account)).appText(.fine).foregroundStyle(.secondary)
            Text(AccountsWords.about(account)).appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecretInfoLine(parts: AccountsWords.line(account))
            if AccountsWords.asks(account) {
                Label(AskBeforeUseWords.asks, icon: "hand.raised").appText(.fine).foregroundStyle(.secondary)
            }
            if let soon = AccountsWords.expiresSoon(account, now: Date()) {
                Text(soon).appText(.fine).tinted(.attention)
            }
            if !oneMachine, let warning = AccountsWords.notBackedUp(account, rows: secrets, names: machineNames) {
                Text("⚠ " + warning).appText(.fine).tinted(.attention)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Ask before use (#4163) on Add Account… and Edit…: on at first. As `AskBeforeUseToggle`, with
/// an account's words under it.
private struct AccountAskToggle: View {
    @Binding var fields: [String: String]

    var body: some View {
        let isOn = Binding(get: { fields[AccountsWords.askField] != "off" },
                           set: { fields[AccountsWords.askField] = $0 ? nil : "off" })
        VStack(alignment: .leading, spacing: 2) {
            Toggle(AskBeforeUseWords.toggle, isOn: isOn)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .appText(.supporting)
            Text(AccountsWords.askHint(isOn.wrappedValue))
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        let text = Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
        #if os(iOS)
        // An iOS Form shows a field's prompt, not its label: the label goes before it.
        return LabeledContent(label) {
            TextField(label, text: text, prompt: Text(prompt), axis: key == "description" ? .vertical : .horizontal)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(key == "notes" || key == "description" ? .sentences : .never)
                .keyboardType(key == "cost" ? .decimalPad : key == "address" ? .emailAddress : .default)
        }
        #else
        // A description is one or two sentences: it wraps rather than scrolls (#4164).
        return TextField(label, text: text, prompt: Text(prompt), axis: key == "description" ? .vertical : .horizontal)
            .autocorrectionDisabled()
        #endif
    }

    var body: some View {
        Form {
            Section {
                field("Service", "service", "gitlab.com")
                field("Address", "address", "name@example.com")
                field("Description", "description", "What it is for, and who uses it")
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
                AccountAskToggle(fields: $fields)
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
        #if os(macOS)
        .frame(minWidth: 400)
        #endif
        .onAppear { if let account { fields = AccountsWords.fields(account) } }
    }
}
