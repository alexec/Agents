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
                if let message = request.message, message != request.title {
                    Text(message).font(.callout)
                }

                switch request.mode {
                case .form(let schema) where schema.singleChoice != nil:
                    if let description = schema.description {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                    oneClick(schema)

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

                case .url(let url):
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
        // Floats above the prompt bar, in its column.
        .chatColumn()
        .onAppear { fillInDefaults() }
    }

    /// A question whose whole answer is one choice, answered by clicking the choice.
    ///
    /// Drawn the way `PermissionView` draws a permission question, because that is
    /// what this is: the agent's own wording, on buttons, answered outright. The
    /// description stays under each title — what separates two choices is usually
    /// there rather than in the labels, and dropping it would make the buttons a row
    /// of bare words.
    ///
    /// It scrolls sideways for the same reason the prompt bar's option row does: these
    /// are the agent's words in a column of bounded width, so there is no bound on how
    /// wide the row wants to be, and a layout that measures its own width and picks a
    /// layout from that has crashed this app through AppKit before.
    @ViewBuilder
    private func oneClick(_ schema: ElicitationSchema) -> some View {
        if let single = schema.singleChoice {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(single.choices) { choice in
                        answerButton(title: choice.title, description: choice.description,
                                     prominent: true) {
                            answer(single.property.name, with: .string(choice.value))
                        }
                    }
                    // Picking nothing is an answer too, where the agent said the
                    // question may go unanswered. Still one click (FR-040).
                    if !single.property.isRequired {
                        answerButton(title: "No answer", description: nil, prominent: false) {
                            answer(single.property.name, with: .string(""))
                        }
                    }
                    // Not the same thing as answering with nothing, and the daemon
                    // already tells the two apart.
                    answerButton(title: "No thanks", description: nil, prominent: false) {
                        Task { await model.answerElicitation(request, action: .decline) }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Prominent for a real answer, plain for the two ways of not giving one — the
    /// same split `PermissionView` makes between an option that allows and one that
    /// does not.
    @ViewBuilder
    private func answerButton(title: String, description: String?,
                              prominent: Bool, choose: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: choose) { answerLabel(title, description) }
                .buttonStyle(.glassProminent)
        } else {
            Button(action: choose) { answerLabel(title, description) }
                .buttonStyle(.glass)
        }
    }

    private func answerLabel(_ title: String, _ description: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            if let description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 240, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func answer(_ name: String, with value: JSONValue) {
        Task { await model.answerElicitation(request, action: .accept, content: [name: value]) }
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
                    // Rows rather than a menu: what separates two options is usually
                    // their description, and a menu has nowhere to put it.
                    Picker("", selection: binding(for: property.name)) {
                        ForEach(choices) { choice in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.title)
                                if let description = choice.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(JSONValue.string(choice.value))
                        }
                        if !property.isRequired {
                            // Picking nothing is an answer too, and without a row for
                            // it the picker cannot be put back.
                            Text("No answer").tag(JSONValue.string(""))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
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
                        Toggle(isOn: Binding(
                            get: { chosen(property.name).contains(item.value) },
                            set: { isOn in
                                var chosen = chosen(property.name)
                                if isOn { chosen.append(item.value) } else { chosen.removeAll { $0 == item.value } }
                                values[property.name] = .array(chosen.map(JSONValue.string))
                            })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                if let description = item.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if let description = property.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = property.problem(with: values[property.name]), values[property.name] != nil {
                Text(problem).font(.caption).tinted(.failure)
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
