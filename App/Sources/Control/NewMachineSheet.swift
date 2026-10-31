import AgentsKitCore
import SwiftUI

/// New Machine… (#691 US5, layouts.md L9): a form drawn from the provider's
/// `workspace_options`, then a confirmation that says what is made and, where the provider
/// says, what it costs. Nothing is made until that is confirmed (US5 AS3).
struct NewMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: ControlSettingsModel
    let provider: DaemonAPI.ProviderSummary
    /// A workspace that can't install on its first boot is added over ssh, as Add as Host… does.
    let addOverSSH: (ControlAddServerSheet.Prefill) -> Void

    @State private var schema: [Field] = []
    @State private var loading = true
    @State private var name = ""
    @State private var values: [String: JSONValue] = [:]
    /// Clone these folders (#1122): git URLs, one a line.
    @State private var clones = ""
    @State private var confirming = false
    @State private var working = false
    @State private var problem: String?

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
            Text("New Machine on \(provider.name)").appText(.title).fontWeight(.semibold)
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Form {
                    TextField("Name", text: $name, prompt: Text("build-2"))
                    ForEach(schema) { field in fieldView(field) }
                    TextField("Clone these folders", text: $clones,
                              prompt: Text("https://github.com/you/folder.git"), axis: .vertical)
                        .lineLimit(1...5)
                }
                .formStyle(.grouped)
            }
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            Text("It joins as a machine by itself once it has started, and is linked to it. Then it clones the folders you list, one a line, with this Mac’s git access when you allow it.")
                .appText(.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 480)
        .task { await load() }
        .confirmationDialog("Make \(trimmedName) on \(provider.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Make") { make() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(summary)
        }
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
            TextField(field.title, text: Binding(get: { values[field.id].map { $0.intValue.map(String.init) ?? "" } ?? "" },
                                                 set: { values[field.id] = Int($0).map(JSONValue.int) }),
                      prompt: field.placeholder.map(Text.init))
        default:
            TextField(field.title, text: binding(field, default: ""), prompt: field.placeholder.map(Text.init))
        }
    }

    private func binding(_ field: Field, default value: String) -> Binding<String> {
        Binding(get: { values[field.id]?.stringValue ?? value },
                set: { values[field.id] = $0.isEmpty ? nil : .string($0) })
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What the confirmation says: each choice, and its cost when the provider names one.
    private var summary: String {
        var parts: [String] = []
        var costs: [String] = []
        for field in schema {
            guard let value = chosen[field.id] else { continue }
            let text = value.stringValue ?? value.intValue.map(String.init) ?? (value.boolValue.map { $0 ? field.title : "" } ?? "")
            if !text.isEmpty { parts.append(text) }
            if let cost = value.stringValue.flatMap({ field.costs[$0] }) { costs.append(cost) }
        }
        return (parts + costs).joined(separator: " · ")
    }

    /// The choices with each enum's first value where none was picked, as the form shows it.
    private var chosen: [String: JSONValue] {
        var all = values
        for field in schema where field.kind == "enum" && all[field.id] == nil {
            if let first = field.choices.first { all[field.id] = .string(first) }
        }
        return all
    }

    private func load() async {
        switch await control.workspaceOptions(provider.id) {
        case .success(let schema): self.schema = Field.read(schema)
        case .failure(let refusal): problem = refusal.message
        }
        loading = false
    }

    private func make() {
        working = true
        problem = nil
        Task {
            let urls = clones.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let result = await control.makeMachine(provider.id, name: trimmedName, options: .object(chosen), clones: urls)
            working = false
            switch result {
            case .success(let made):
                dismiss()
                if !made.joining {
                    addOverSSH(.init(destination: made.workspace.ssh ?? "", name: made.workspace.name,
                                     tunnel: made.workspace.tunnel ?? false, provider: provider.id,
                                     workspace: made.workspace.id))
                }
            case .failure(let refusal):
                problem = refusal.message
            }
        }
    }
}
