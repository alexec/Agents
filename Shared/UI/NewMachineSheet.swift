import AgentsKitCore
import SwiftUI

/// Why the provider's form could not be read, in the app's words.
struct NewMachineRefusal: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// What New Machine makes, as its sheet has it (#4634).
struct NewMachineDraft: Equatable, Sendable {
    var provider: ProviderID
    var name: String
    var values: [String: JSONValue]
    /// Clone these folders (#1122): git URLs. Only Settings' Add a Machine… asks for them.
    var clones: [String] = []
}

/// The New Machine sheet up (#4634): for a provider (nil for the default one), or opened
/// again on the choices of a make the provider refused, with its reason.
struct NewMachineAsk: Identifiable, Equatable {
    let id = UUID()
    var provider: ProviderID?
    var again: NewMachineDraft?
    var problem: String?
}

/// New Machine (#691 US5, #4634): a form drawn from the provider's `providers/options`, with
/// every field already on what New Machine would make (the options used last on the
/// provider, else its first choices) and the next `machine-N`. Make is the confirmation:
/// nothing is made until it is pressed (US5 AS3), and Cancel makes nothing. Drawn by the
/// window and the Remote, as the web page's NewMachineSheet.
struct NewMachineSheet: View {
    typealias Refusal = NewMachineRefusal

    @Environment(\.dismiss) private var dismiss
    /// The providers New Machine can use: a picker when there are two or more.
    let providers: [DaemonAPI.ProviderSummary]
    /// Clone these folders: Settings' Add a Machine… has it; the sidebar's New Machine does
    /// not (you add a folder later, the wireframe).
    var showsClones = false
    /// The provider's form, with the values to start with; nil for the default provider.
    let load: @MainActor (ProviderID?) async -> Result<DaemonAPI.ProviderOptions, Refusal>
    /// Makes it: nil when the sheet may close, or the provider's reason, shown in the sheet.
    let make: @MainActor (NewMachineDraft) async -> String?

    @State private var provider: ProviderID?
    @State private var schema: [Field] = []
    @State private var loading = true
    @State private var name = ""
    @State private var values: [String: JSONValue] = [:]
    @State private var clones = ""
    @State private var working = false
    @State private var problem: String?
    /// A make that failed opens the sheet again on its choices and its reason.
    private let again: NewMachineDraft?

    init(providers: [DaemonAPI.ProviderSummary], provider: ProviderID? = nil, again: NewMachineDraft? = nil,
         problem: String? = nil, showsClones: Bool = false,
         load: @escaping @MainActor (ProviderID?) async -> Result<DaemonAPI.ProviderOptions, Refusal>,
         make: @escaping @MainActor (NewMachineDraft) async -> String?) {
        self.providers = providers
        self.showsClones = showsClones
        self.load = load
        self.make = make
        self.again = again
        _provider = State(initialValue: again?.provider ?? provider)
        _problem = State(initialValue: problem)
    }

    /// One property of the schema: a string, integer, boolean or enum, with a title.
    struct Field: Identifiable {
        var id: String
        var title: String
        var kind: String
        var choices: [String]
        var costs: [String: String]
        var placeholder: String?

        static func read(_ schema: JSONValue) -> [Field] {
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let properties = schema["properties"]?.objectValue ?? [:]
            return properties.keys.sorted { a, b in
                // The schema's own order is lost in an object: required first, then by name.
                required.contains(a) != required.contains(b) ? required.contains(a) : a < b
            }.compactMap { key in
                guard let property = properties[key] else { return nil }
                let choices = property["enum"]?.arrayValue?.compactMap { $0.stringValue ?? $0.intValue.map(String.init) } ?? []
                return Field(id: key, title: property["title"]?.stringValue ?? key.capitalized,
                             kind: choices.isEmpty ? (property["type"]?.stringValue ?? "string") : "enum",
                             choices: choices,
                             costs: (property["x-costs"]?.objectValue ?? [:]).compactMapValues(\.stringValue),
                             placeholder: property["description"]?.stringValue)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(macOS)
            Text(title).appText(.title).fontWeight(.semibold)
            #endif
            Form {
                if providers.count > 1 {
                    Picker("Provider", selection: Binding(get: { provider ?? providers[0].id },
                                                          set: { chosen in
                                                              guard chosen != provider else { return }
                                                              provider = chosen
                                                              Task { await reload() }
                                                          })) {
                        ForEach(providers) { Text($0.name).tag($0.id) }
                    }
                    .disabled(working)
                }
                labeled("Name") {
                    TextField("Name", text: $name, prompt: Text("machine-1"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    ForEach(schema) { field in fieldView(field) }
                }
                if showsClones {
                    TextField("Clone these folders", text: $clones,
                              prompt: Text("https://github.com/you/folder.git"), axis: .vertical)
                        .lineLimit(1...5)
                }
                #if os(iOS)
                // The notes under the form, as a footer, where iOS puts a form's words.
                Section { } footer: { notes }
                #endif
            }
            .formStyle(.grouped)
            .disabled(working)
            #if os(macOS)
            notes
            HStack {
                if !cost.isEmpty {
                    Text(cost).appText(.supporting).foregroundStyle(.secondary)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make") { press() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
            #endif
        }
        #if os(macOS)
        .padding(28)
        .frame(width: 480)
        #else
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else { Button("Make") { press() }.disabled(!ready) }
            }
        }
        #endif
        .task { await reload(keeping: again) }
    }

    /// The provider's refusal, what happens once it is made, and on iOS what it costs.
    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            Text(showsClones
                 ? "It joins as a machine by itself once it has started, and is linked to it. Then it clones the folders you list, one a line, with this Mac’s git access when you allow it."
                 : "It joins as a machine by itself once it has started. The provider charges for it from when it is made.")
                .appText(.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            if !cost.isEmpty {
                Text(cost).appText(.supporting).foregroundStyle(.secondary)
            }
            #endif
        }
    }

    /// A text field with its title beside it: iOS's form shows only a field's prompt.
    @ViewBuilder
    private func labeled(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        #if os(iOS)
        LabeledContent(title) { field().multilineTextAlignment(.trailing) }
        #else
        field()
        #endif
    }

    private var title: String {
        guard let provider, let named = providers.first(where: { $0.id == provider }) else { return "New Machine" }
        return providers.count > 1 ? "New Machine" : "New Machine on \(named.name)"
    }

    @ViewBuilder
    private func fieldView(_ field: Field) -> some View {
        switch field.kind {
        case "enum":
            Picker(field.title, selection: binding(field, default: field.choices.first ?? "")) {
                ForEach(field.choices, id: \.self) { choice in
                    Text(field.costs[choice].map { "\(choice) — \($0)" } ?? choice).tag(choice)
                }
            }
        case "boolean":
            Toggle(field.title, isOn: Binding(get: { values[field.id]?.boolValue ?? false },
                                              set: { values[field.id] = .bool($0) }))
        case "integer", "number":
            labeled(field.title) {
                TextField(field.title, text: Binding(get: { values[field.id].map { $0.intValue.map(String.init) ?? "" } ?? "" },
                                                     set: { values[field.id] = Int($0).map(JSONValue.int) }),
                          prompt: field.placeholder.map(Text.init))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        default:
            labeled(field.title) {
                TextField(field.title, text: binding(field, default: ""), prompt: field.placeholder.map(Text.init))
            }
        }
    }

    private func binding(_ field: Field, default value: String) -> Binding<String> {
        Binding(get: { values[field.id]?.stringValue ?? value },
                set: { values[field.id] = $0.isEmpty ? nil : .string($0) })
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool { !loading && !working && provider != nil && AddMachine.validName(trimmedName) }

    /// What the chosen options cost, when the provider names it (`x-costs`).
    private var cost: String {
        schema.compactMap { field in chosen[field.id]?.stringValue.flatMap { field.costs[$0] } }.joined(separator: " · ")
    }

    /// The choices with each enum's first value where none was picked, as the form shows it.
    private var chosen: [String: JSONValue] {
        var all = values
        for field in schema where field.kind == "enum" && all[field.id] == nil {
            if let first = field.choices.first { all[field.id] = .string(first) }
        }
        return all
    }

    /// Reads the provider's form, and puts every field on what New Machine would make, or on
    /// the choices a make that failed had.
    private func reload(keeping kept: NewMachineDraft? = nil) async {
        loading = true
        defer { loading = false }
        switch await load(provider) {
        case .success(let options):
            provider = options.id ?? provider ?? providers.first?.id
            schema = Field.read(options.schema)
            if let kept {
                name = kept.name
                values = kept.values
                clones = kept.clones.joined(separator: "\n")
            } else {
                // A name typed already stays when the provider changes.
                if name.isEmpty || name.hasPrefix("machine-") { name = options.name ?? name }
                values = options.values?.objectValue ?? [:]
            }
        case .failure(let refusal):
            problem = refusal.message
        }
    }

    private func press() {
        guard let provider else { return }
        working = true
        problem = nil
        let urls = clones.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let draft = NewMachineDraft(provider: provider, name: trimmedName, values: chosen, clones: urls)
        Task {
            let refused = await make(draft)
            working = false
            if let refused { problem = refused } else { dismiss() }
        }
    }
}
