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
    /// Which question of a multi-question form is on screen.
    @State private var step = 0
    /// How tall the question on each page wants to be, measured rather than guessed.
    @State private var questionHeights: [Int: CGFloat] = [:]

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                Text(request.title).appText(.reading).fontWeight(.semibold)
                if let message = request.message, message != request.title {
                    Text(message).appText(.reading)
                }

                switch request.mode {
                case .form(let schema) where schema.singleChoice != nil:
                    if let description = schema.description {
                        Text(description).appText(.supporting).foregroundStyle(.secondary)
                    }
                    oneClick(schema)

                case .form(let schema):
                    pages(schema)

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
        // A second question arriving while the first is still on screen starts at
        // its own first page, not wherever the last one was left.
        .onChange(of: request.id) { _, _ in step = 0 }
    }

    /// A form of several questions, one to a page.
    ///
    /// Drawn all at once, a form of more than two or three questions is taller than
    /// the window, and the first thing to fall off the bottom is the button that
    /// sends it — the card becomes unanswerable by being too big to answer. So a page
    /// is one question: the question itself, a button for each of its options, and a
    /// box for an answer that is not among them. Clicking an option answers and moves
    /// on, which is the whole interaction for most forms. The row underneath holds
    /// the way back, where you are, and — only when they can do anything — Next and
    /// Submit.
    @ViewBuilder
    private func pages(_ schema: ElicitationSchema) -> some View {
        let pages = schema.pages
        let last = pages.count - 1
        let page = min(max(step, 0), last)
        if let description = schema.description {
            Text(description).appText(.supporting).foregroundStyle(.secondary)
        }
        // Every page is laid out, hidden, under the one that shows, so the card is as
        // tall as its tallest question whichever page is up. Answering the first
        // question then puts the second exactly where the first was; before this the
        // card shrank around a shorter question and, being pinned to the foot of the
        // pane, dropped it to wherever the shorter card's top now was.
        ZStack(alignment: .topLeading) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, group in
                question(group, page: index, last: last).hidden()
            }
            question(pages[page], page: page, last: last)
        }
        HStack(spacing: 8) {
            if last > 0 {
                turn(to: page - 1, "chevron.backward", "Previous question", enabled: page > 0)
                Text("\(page + 1)/\(pages.count)")
                    .appText(.fine)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            // On the last page this names whichever question is still unanswered,
            // which is why Submit will not go.
            if page == last, let problem = schema.problems(with: values).first {
                Text(problem)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Saying no is an answer, and the paged form is the one shape that used
            // to have nowhere to say it: a form you cannot finish and cannot dismiss
            // is a card that sits there for ever.
            Button("No thanks") {
                Task { await model.answerElicitation(request, action: .decline) }
            }
            .buttonStyle(.glass)
            // Always offered, on every page but the last. Clicking an option turns
            // the page by itself, so here Next is mostly the way past a question
            // that a click cannot answer: a boolean left alone, an optional box left
            // empty, a multi-select with nothing ticked. Gating it on the page being
            // answered made those pages dead ends, and because Submit lives on the
            // last page alone, one dead end made the whole form unanswerable.
            // Whether the answer will do is Submit's business, not this button's.
            if page < last {
                Button("Next") { step = page + 1 }
                    .buttonStyle(.glass)
            }
            if page == last {
                Button("Submit") {
                    Task { await model.answerElicitation(request, action: .accept, content: values) }
                }
                .buttonStyle(.glassProminent)
                .disabled(!schema.problems(with: values).isEmpty)
            }
        }
    }

    /// The question on this page — its choices, and the box for an answer that is not
    /// among them — bounded so that a long one cannot push the answer row off the
    /// bottom of the window.
    ///
    /// Measured first, then wrapped in a scroll view no taller than what was measured.
    /// A scroll view takes all the height it is offered, so wrapping before measuring
    /// left a short question sitting at the top of a card padded out to the cap; held
    /// to its content's height it is exactly the question when there is room. And it
    /// is wrapped whether or not it is over the cap, because the bound that matters
    /// is not only the cap but the pane: a plain stack ignores a height it cannot
    /// meet and overflows, and with the card pinned to the foot of the pane the
    /// overflow went below the window, taking the answer row with it. A scroll view
    /// keeps to what the pane leaves it after the prompt bar and the card's own words,
    /// so the row stays on the glass at any window height and the question scrolls.
    @ViewBuilder
    private func question(_ properties: [ElicitationSchema.Property],
                          page: Int, last: Int) -> some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            ForEach(properties) { property in
                part(property, page: page, last: last)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { questionHeights[page] = $0 }
        if let measured = questionHeights[page], measured > 0 {
            ScrollView { content }
                .frame(maxHeight: min(measured, Self.questionCap))
                .scrollBounceBehavior(.basedOnSize)
        } else {
            // The first pass, which is where the measurement comes from.
            content
        }
    }

    /// As tall as a question may get before it scrolls instead — beside the caps a
    /// long diff and the command list keep.
    private static let questionCap: CGFloat = 260

    private func turn(to page: Int, _ symbol: String, _ label: String, enabled: Bool) -> some View {
        Button { step = page } label: { Image(systemName: symbol) }
            .buttonStyle(.glass)
            .disabled(!enabled)
            .accessibilityLabel(label)
    }

    /// One part of a page: a question with its options as buttons, a list to tick, or
    /// an ordinary field for everything else.
    @ViewBuilder
    private func part(_ property: ElicitationSchema.Property, page: Int, last: Int) -> some View {
        switch property.kind {
        case .string(_, _, _, let choices?):
            asked(property)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(choices) { choice in
                    // Clicking answers and turns the page. On the last page there is
                    // nowhere to turn to, so it selects and waits for Submit.
                    option(choice.title, choice.description,
                           chosen: values[property.name]?.stringValue == choice.value) {
                        values[property.name] = .string(choice.value)
                        if page < last { step = page + 1 }
                    }
                }
            }
        case .multiSelect(let items, _, _):
            asked(property)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    // Several can be picked, so a click cannot mean "and move on":
                    // it adds or removes, and Next appears once anything is on.
                    option(item.title, item.description,
                           chosen: chosen(property.name).contains(item.value)) {
                        var picked = chosen(property.name)
                        if let at = picked.firstIndex(of: item.value) {
                            picked.remove(at: at)
                        } else {
                            picked.append(item.value)
                        }
                        values[property.name] = .array(picked.map(JSONValue.string))
                    }
                }
            }
        default:
            field(for: property)
        }
    }

    /// The question itself: its own words, above its options.
    private func asked(_ property: ElicitationSchema.Property) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(property.title ?? property.name)
                    .appText(.reading)
                    .fontWeight(.medium)
                if property.isRequired {
                    Text("needed").appText(.fine).foregroundStyle(.tertiary)
                }
            }
            if let description = property.description {
                Text(description).appText(.supporting).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// An option, full width down the card rather than along a row: there is one
    /// question on the page now, so there is room to read what each one means.
    @ViewBuilder
    private func option(_ title: String, _ description: String?,
                        chosen: Bool, choose: @escaping () -> Void) -> some View {
        if chosen {
            Button(action: choose) { optionLabel(title, description) }
                .buttonStyle(.glassProminent)
        } else {
            Button(action: choose) { optionLabel(title, description) }
                .buttonStyle(.glass)
        }
    }

    private func optionLabel(_ title: String, _ description: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            if let description, !description.isEmpty {
                Text(description)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
                    .appText(.fine)
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
                Text(property.title ?? property.name).appText(.reading)
                if property.isRequired { Text("needed").appText(.fine).foregroundStyle(.tertiary) }
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
                                    Text(description).appText(.supporting).foregroundStyle(.secondary)
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
                                    Text(description).appText(.supporting).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if let description = property.description {
                Text(description).appText(.supporting).foregroundStyle(.secondary)
            }
            if let problem = property.problem(with: values[property.name]), values[property.name] != nil {
                Text(problem).appText(.supporting).tinted(.failure)
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
