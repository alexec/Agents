import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Secrets (#1760, #3632): the person’s secrets, by name only, kept by the control
/// plane and sent to each machine of theirs. The window draws it; the web page
/// draws the same in `Web/src/views/UserScope.tsx`. A card (#3531) is a secret of its own kind.
/// `extra` is what a client draws after them: the window's secrets for one session (#3548).
struct SecretsPane<Extra: View>: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let state: UserScopeState
    let extra: Extra

    init(control: DaemonClient?, state: UserScopeState, @ViewBuilder extra: () -> Extra) {
        self.control = control
        self.state = state
        self.extra = extra()
    }

    @State private var problem: String?
    @State private var isAdding = false
    @State private var isAddingCard = false
    @State private var replacing: DaemonAPI.UserSecretRow?
    @State private var removing: DaemonAPI.UserSecretRow?

    var body: some View {
        Form {
            if let problem = problem ?? state.problem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            if let left = state.left {
                Section {
                    Text(UserScopeWords.secretsLeft(left)).appText(.supporting).tinted(.attention)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("OK") { state.left = nil }
                }
                .paperListRow()
            }
            secretsSection
            extra
        }
        .paperForm()
        .task(id: control != nil) { await state.load(control) }
        .refreshable { await state.load(control) }
        .sheet(isPresented: $isAdding) {
            SecretSheet(name: nil) { name, value in await state.setSecret(name, value: value, on: control) }
                .paperSheet()
        }
        .sheet(isPresented: $isAddingCard) {
            CardSheet(name: nil) { name, value in
                await state.setSecret(name, value: value, kind: CardSecret.kind, on: control)
            }
            .paperSheet()
        }
        .sheet(item: $replacing) { row in
            if row.isCard {
                CardSheet(name: row.name) { name, value in
                    await state.setSecret(name, value: value, kind: CardSecret.kind, replacing: row, on: control)
                }
                .paperSheet()
            } else {
                SecretSheet(name: row.name) { name, value in await state.setSecret(name, value: value, replacing: row, on: control) }
                    .paperSheet()
            }
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { row in
            Button("Remove", role: .destructive) {
                Task { problem = await state.removeSecret(row.name, on: control) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is taken out of secrets.env on every machine of yours.")
        }
    }

    private var secretsSection: some View {
        let rows: [DaemonAPI.UserSecretRow] = state.secrets?.secrets ?? []
        return Section {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.name).appText(.code)
                        if row.isCard {
                            Text(UserScopeWords.cardKind).appText(.fine).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Replace…") { replacing = row }
                            Button("Remove…", role: .destructive) { removing = row }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .fixedSize()
                        .accessibilityLabel("\(row.name) actions")
                    }
                    Text(UserScopeWords.machines(row)).appText(.fine).foregroundStyle(.secondary)
                    if let waiting = UserScopeWords.waiting(row) {
                        Text(waiting).appText(.fine).tinted(.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let left = UserScopeWords.leftOn(row) {
                        Text(left).appText(.fine).tinted(.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button(UserScopeWords.addSecret) { isAdding = true }
                .disabled(control == nil)
            Button(UserScopeWords.addCard) { isAddingCard = true }
                .disabled(control == nil)
        } footer: {
            Text(UserScopeWords.secretsFoot).appText(.fine).foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}

extension SecretsPane where Extra == EmptyView {
    init(control: DaemonClient?, state: UserScopeState) {
        self.init(control: control, state: state) { EmptyView() }
    }
}

/// Add a Secret… and Replace…: a name and a value. The value is never shown again.
private struct SecretSheet: View {
    /// The secret replaced, or nil for a new one.
    let name: String?
    let save: (String, String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var value = ""
    @State private var problem: String?
    @State private var saving = false

    private var chosen: String { name ?? typedName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                if name == nil {
                    TextField("Name", text: $typedName, prompt: Text("GITHUB_TOKEN"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                }
                SecureField("Value", text: $value)
            } header: {
                Text(name.map { "Replace \($0)" } ?? "Add a Secret")
            } footer: {
                Text(problem ?? UserScopeWords.nameHint).appText(.fine)
                    .tinted(problem == nil ? .none : .failure)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(name == nil ? "Add" : "Replace") {
                    Task {
                        saving = true
                        problem = await save(chosen, value)
                        saving = false
                        if problem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || value.isEmpty || !UserScopeWords.isSecretName(chosen))
            }
            .rowButtons()
        }
        .paperForm()
        .frame(minWidth: 360)
        .onDisappear { value = "" }
    }
}

/// Add a Card… and a card's Replace… (#3531): a payment card for agents to fill into a page,
/// only one with a spend limit (a merchant or category lock is recommended). Its parts are one secret; none is shown again.
private struct CardSheet: View {
    /// The card replaced, or nil for a new one.
    let name: String?
    let save: (String, String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var number = ""
    @State private var expiry = ""
    @State private var cvc = ""
    @State private var holder = ""
    @State private var zip = ""
    @State private var locked = false
    @State private var problem: String?
    @State private var saving = false

    private var chosen: String { name ?? typedName.trimmingCharacters(in: .whitespaces) }
    private var card: CardSecret { CardSecret(number: number, expiry: expiry, cvc: cvc, name: holder, zip: zip) }

    var body: some View {
        Form {
            Section {
                Text(UserScopeWords.cardRule).appText(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(UserScopeWords.cardConfirm, isOn: $locked)
                    .accessibilityLabel(UserScopeWords.cardConfirm)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
            }
            Section {
                if name == nil {
                    TextField("Name", text: $typedName, prompt: Text("SHOP_CARD"))
                        .autocorrectionDisabled()
                }
                SecureField("Card number", text: $number, prompt: Text("Digits"))
                TextField("Expiry", text: $expiry, prompt: Text("MM/YY"))
                    .autocorrectionDisabled()
                SecureField("CVC", text: $cvc, prompt: Text("3 or 4 digits"))
                TextField("Name on card", text: $holder, prompt: Text("As on the card"))
                    .autocorrectionDisabled()
                TextField("Billing ZIP", text: $zip, prompt: Text("ZIP or postal code"))
                    .autocorrectionDisabled()
            } header: {
                Text(name.map { "Replace \($0)" } ?? "Add a Card")
            } footer: {
                Text(problem ?? UserScopeWords.nameHint).appText(.fine)
                    .tinted(problem == nil ? .none : .failure)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(name == nil ? "Add" : "Replace") {
                    if let wrong = card.problem {
                        problem = wrong
                        return
                    }
                    Task {
                        saving = true
                        problem = await save(chosen, card.value)
                        saving = false
                        if problem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !locked || number.isEmpty || cvc.isEmpty || !UserScopeWords.isSecretName(chosen))
            }
            .rowButtons()
        }
        .paperForm()
        .frame(minWidth: 400)
        .onDisappear { number = ""; cvc = "" }
    }
}
