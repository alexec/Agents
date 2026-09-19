import AgentsKit
import SwiftUI

/// A question from the agent that wants a particular shape of answer.
///
/// The permission banner grown up: held by the daemon, answerable from any window,
/// still there when a window opens later. An answer that does not fit the shape is not
/// sent, because the agent asked for something specific and half of it is worse than
/// none.
struct ElicitationView: View {
    @Environment(AppModel.self) private var model
    let request: ElicitationRequest

    @State private var values: [String: JSONValue] = [:]

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                Text(request.title).font(.headline)

                switch request.mode {
                case .form(let schema):
                    if let description = schema.description {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(schema.properties) { property in
                        field(for: property)
                    }
                    HStack(spacing: 8) {
                        Button("Send") {
                            Task { await model.answerElicitation(request, action: .accept, content: values) }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!schema.problems(with: values).isEmpty)
                        Button("No thanks") {
                            Task { await model.answerElicitation(request, action: .decline) }
                        }
                        .buttonStyle(.glass)
                        Spacer(minLength: 0)
                        if let problem = schema.problems(with: values).first {
                            Text(problem).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                case .url(let url, let description):
                    if let description {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Open") {
                            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                        }
                        .buttonStyle(.glassProminent)
                        Button("Done") {
                            Task { await model.answerElicitation(request, action: .accept) }
                        }
                        .buttonStyle(.glass)
                        Button("Gave up") {
                            Task { await model.answerElicitation(request, action: .decline) }
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 144)
        .onAppear { fillInDefaults() }
    }

    @ViewBuilder
    private func field(for property: ElicitationSchema.Property) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(property.title ?? property.name).font(.callout)
                if property.isRequired { Text("needed").font(.caption).foregroundStyle(.tertiary) }
            }
            switch property.kind {
            case .string(_, _, _, let choices):
                if let choices {
                    Picker("", selection: binding(for: property.name)) {
                        ForEach(choices) { choice in
                            Text(choice.title).tag(JSONValue.string(choice.value))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } else {
                    TextField("", text: text(for: property.name))
                        .textFieldStyle(.roundedBorder)
                }
            case .number, .integer:
                TextField("", text: text(for: property.name))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: values[property.name]) { _, _ in coerceNumber(property) }
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { values[property.name]?.boolValue ?? false },
                    set: { values[property.name] = .bool($0) }))
                    .labelsHidden()
            case .multiSelect(let items, _, _):
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        Toggle(item.title, isOn: Binding(
                            get: { chosen(property.name).contains(item.value) },
                            set: { isOn in
                                var chosen = chosen(property.name)
                                if isOn { chosen.append(item.value) } else { chosen.removeAll { $0 == item.value } }
                                values[property.name] = .array(chosen.map(JSONValue.string))
                            }))
                    }
                }
            }
            if let description = property.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = property.problem(with: values[property.name]), values[property.name] != nil {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func chosen(_ name: String) -> [String] {
        values[name]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func binding(for name: String) -> Binding<JSONValue> {
        Binding(get: { values[name] ?? .string("") }, set: { values[name] = $0 })
    }

    private func text(for name: String) -> Binding<String> {
        Binding(get: { values[name]?.stringValue ?? numberText(name) },
                set: { values[name] = .string($0) })
    }

    private func numberText(_ name: String) -> String {
        switch values[name] {
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        default: return ""
        }
    }

    /// A number typed into a text field is text until it is a number.
    private func coerceNumber(_ property: ElicitationSchema.Property) {
        guard let typed = values[property.name]?.stringValue else { return }
        if case .integer = property.kind, let whole = Int(typed) {
            values[property.name] = .int(whole)
        } else if case .number = property.kind, let number = Double(typed) {
            values[property.name] = .double(number)
        }
    }

    private func fillInDefaults() {
        guard case .form(let schema) = request.mode else { return }
        for property in schema.properties where values[property.name] == nil {
            if let value = property.defaultValue { values[property.name] = value }
        }
    }
}
