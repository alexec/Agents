import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Secrets (#1760, #3632): the person’s secrets, by name only, kept by the control
/// plane and sent to each machine of theirs. The window draws it; the web page
/// draws the same in `Web/src/views/UserScope.tsx`. A card (#3531) is a secret of its own kind.
/// Ask before use (#4016) is sealed with the value, so it is set on Add and Replace, which seal it
/// again: no client can read a value back to seal it with a new flag.
/// `extra` is what a client draws after them: the Mac's secrets for one session (#3548). The window
/// and the Remote (#4032) draw it.
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
            SecretSheet(name: nil, asks: true, description: nil) { name, value, ask, description in
                await state.setSecret(name, value: value, askBeforeUse: ask, description: description, on: control)
            }
            .paperSheet()
        }
        .sheet(isPresented: $isAddingCard) {
            CardSheet(name: nil, asks: true, description: nil) { name, value, ask, description in
                await state.setSecret(name, value: value, kind: CardSecret.kind, askBeforeUse: ask, description: description, on: control)
            }
            .paperSheet()
        }
        .sheet(item: $replacing) { row in
            if row.isCard {
                CardSheet(name: row.name, asks: row.asksBeforeUse, description: row.description) { name, value, ask, description in
                    await state.setSecret(name, value: value, kind: CardSecret.kind, replacing: row, askBeforeUse: ask,
                                          description: description, on: control)
                }
                .paperSheet()
            } else {
                SecretSheet(name: row.name, asks: row.asksBeforeUse, description: row.description) { name, value, ask, description in
                    await state.setSecret(name, value: value, replacing: row, askBeforeUse: ask, description: description, on: control)
                }
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
            Text("It is taken out of the sealed store on every machine of yours.")
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
                    Text(UserScopeWords.about(row.description)).appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(UserScopeWords.machines(row)).appText(.fine).foregroundStyle(.secondary)
                    if row.asksBeforeUse {
                        Label(AskBeforeUseWords.asks, systemImage: "hand.raised")
                            .appText(.fine).foregroundStyle(.secondary)
                    }
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
    /// Save, with the name, the value, Ask before use and the description (#4167).
    let save: (String, String, Bool, String?) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var value = ""
    @State private var askBeforeUse: Bool
    @State private var about: String
    @State private var problem: String?
    @State private var saving = false

    /// `asks`: Ask before use as the toggle starts: the replaced secret's, on for a new one (#4162).
    /// `description`: the replaced secret's, to change (#4167).
    init(name: String?, asks: Bool, description: String?, save: @escaping (String, String, Bool, String?) async -> String?) {
        self.name = name
        self.save = save
        _askBeforeUse = State(initialValue: asks)
        _about = State(initialValue: description ?? "")
    }

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
                SecretDescriptionField(text: $about)
                AskBeforeUseToggle(isOn: $askBeforeUse)
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
                        problem = await save(chosen, value, askBeforeUse, UserScopeWords.description(about))
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
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
        .onDisappear { value = "" }
    }
}

/// Add a Card… and a card's Replace… (#3531): a payment card for agents to fill into a page,
/// only one with a spend limit (a merchant or category lock is recommended). Its parts are one secret; none is shown again.
private struct CardSheet: View {
    /// The card replaced, or nil for a new one.
    let name: String?
    /// Save, with the name, the card's parts as one value, Ask before use and the description (#4167).
    let save: (String, String, Bool, String?) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var number = ""
    @State private var expiry = ""
    @State private var cvc = ""
    @State private var holder = ""
    @State private var zip = ""
    @State private var locked = false
    @State private var askBeforeUse: Bool
    @State private var about: String
    @State private var problem: String?
    @State private var saving = false

    /// `asks`: Ask before use as the toggle starts: the replaced card's, on for a new one (#4162).
    /// `description`: the replaced card's, to change (#4167).
    init(name: String?, asks: Bool, description: String?, save: @escaping (String, String, Bool, String?) async -> String?) {
        self.name = name
        self.save = save
        _askBeforeUse = State(initialValue: asks)
        _about = State(initialValue: description ?? "")
    }

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
                SecretDescriptionField(text: $about)
                AskBeforeUseToggle(isOn: $askBeforeUse)
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
                        problem = await save(chosen, card.value, askBeforeUse, UserScopeWords.description(about))
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
        #if os(macOS)
        .frame(minWidth: 400)
        #endif
        .onDisappear { number = ""; cvc = "" }
    }
}

/// A secret's Description field (#4167): one or two sentences, so it wraps rather than scrolls,
/// with the words that it is not sealed. Add a Secret…, Add a Card…, Replace… and Add for a
/// Session… draw it.
struct SecretDescriptionField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(UserScopeWords.descriptionLabel, text: $text, prompt: Text(UserScopeWords.descriptionPrompt), axis: .vertical)
                .lineLimit(1...3)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
            Text(UserScopeWords.descriptionHint).appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
