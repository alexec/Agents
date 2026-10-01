import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// Set or replace a secret. The value is written to `~/.agents/secrets.env` and never
/// shown again (060, frame E).
struct SetSecretSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let serverName: String
    let names: [String]
    var replacing = false
    var onSaved: () -> Void = {}

    @State private var values: [String: String] = [:]
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).appText(.title)
            Text("\(serverName) needs \(names.count == 1 ? "this" : "these"). The value is saved in your ~/.agents/secrets.env, and it is not shown again.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(names, id: \.self) { name in
                SecureField(name, text: binding(name))
                    .textFieldStyle(.roundedBorder)
            }
            if let failure {
                Text(failure).appText(.fine).foregroundStyle(SharedInk.attention)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper)
                Button(replacing ? "Replace" : "Save") { Task { await save() } }
                    .buttonStyle(.paperProminent)
                    .disabled(saving || names.contains { (values[$0] ?? "").isEmpty })
            }
        }
        .padding(20)
        .frame(width: 420)
        .paperSheet()
    }

    private var title: String {
        let verb = replacing ? "Replace" : "Set"
        return "\(verb) \(names.joined(separator: ", "))"
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name, default: ""] }, set: { values[name] = $0 })
    }

    private func save() async {
        saving = true
        defer { saving = false }
        for name in names {
            if let error = await model.mcpSetSecret(name: name, value: values[name] ?? "") {
                failure = MCPCatalogWords.sentence(error)
                return
            }
        }
        onSaved()
        dismiss()
    }
}
