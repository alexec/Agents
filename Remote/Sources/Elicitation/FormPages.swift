import AgentsKitCore
import SwiftUI

/// A form of several questions, on the phone, one to a page.
///
/// The Mac's `ElicitationView` pages through a form the same way, for the same reason
/// and more so here: drawn all at once, three questions are taller than a phone, and
/// the first thing to go off the bottom is the button that sends them. So a page is one
/// question — its words, a full-width button for each of its answers, and the box for
/// an answer that is not among them — and tapping an answer answers it and turns the
/// page, which is the whole interaction for most forms. Under it: the way back, No
/// thanks, and Next or Submit.
///
/// Every shape the schema can describe is drawn, rather than the phone sending the
/// awkward ones to the Mac: text, numbers, yes or no, a date, a list to tick. They are
/// rarer than a choice, but a question that reaches you and cannot be answered where
/// you are is the thing this app exists to avoid.
struct FormPages: View {
    @Environment(RemoteModel.self) private var model
    let request: ElicitationRequest
    let schema: ElicitationSchema
    /// Hands the answer to the sheet, which shows it going and puts the buttons back if
    /// it did not.
    let send: (_ what: String, _ action: DaemonAPI.AnswerElicitationRequest.Action,
               _ content: [String: JSONValue]) -> Void

    @State private var values: [String: JSONValue] = [:]
    @State private var step = 0
    /// How tall the page wants to be, measured, so a short question is not padded out
    /// to the cap and a long one scrolls rather than pushing the buttons off screen.
    @State private var pageHeight: CGFloat = 0
    @FocusState private var focusedField: String?

    /// As tall as one page gets before it scrolls: enough for five answers with a line
    /// of explanation each, and short enough to leave the conversation visible above.
    private static let pageCap: CGFloat = 380

    private var pages: [[ElicitationSchema.Property]] { schema.pages }
    private var last: Int { pages.count - 1 }
    private var page: Int { min(max(step, 0), last) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = schema.description {
                Text(description)
                    .appText(.reading)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if last > 0 {
                Text("Question \(page + 1) of \(pages.count)")
                    .appText(.fine)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            current
            footer
        }
        .onAppear(perform: fillInDefaults)
        .animation(.snappy(duration: 0.2), value: page)
    }

    // MARK: The page

    private var current: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(pages[page]) { property in
                    part(property)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: pageHeight > 0 ? min(pageHeight, Self.pageCap) : nil)
        // A fresh scroll position per page, so page two does not open half-way down
        // because page one was long.
        .id(page)
    }

    @ViewBuilder
    private func part(_ property: ElicitationSchema.Property) -> some View {
        switch property.kind {
        case .string(_, _, _, let choices?):
            asked(property)
            VStack(spacing: 8) {
                ForEach(choices) { choice in
                    option(choice.title, choice.description,
                           chosen: values[property.name]?.stringValue == choice.value) {
                        values[property.name] = .string(choice.value)
                        // On the last page there is nowhere to turn to, so it selects
                        // and waits for Submit. The question tool puts an "Other" box
                        // on every page; waiting for it would make every page two taps
                        // for the sake of a box most answers leave empty, and Back is
                        // how to reach it.
                        if page < last { step = page + 1 }
                    }
                }
            }
        case .multiSelect(let items, _, _):
            asked(property)
            VStack(spacing: 8) {
                ForEach(items) { item in
                    // Several can be picked, so a tap adds or removes, and Next is how
                    // the page is left.
                    option(item.title, item.description,
                           chosen: chosen(property.name).contains(item.value),
                           ticks: true) {
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
        case .boolean:
            Toggle(isOn: Binding(get: { values[property.name]?.boolValue ?? false },
                                 set: { values[property.name] = .bool($0) })) {
                asked(property)
            }
        case .string(.date?, _, _, nil):
            asked(property)
            DatePicker("", selection: date(for: property, format: Self.day),
                       displayedComponents: .date)
                .labelsHidden()
        case .string(.dateTime?, _, _, nil):
            asked(property)
            DatePicker("", selection: date(for: property, format: Self.moment))
                .labelsHidden()
        default:
            field(property)
        }
        if let problem = property.problem(with: values[property.name]),
           values[property.name] != nil {
            Text(problem).appText(.fine).tinted(.failure)
        }
    }

    /// The question in its own words, above its answers.
    private func asked(_ property: ElicitationSchema.Property) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(property.title ?? property.name)
                    .appText(.reading).fontWeight(.medium)
                if property.isRequired {
                    Text("needed").appText(.fine).foregroundStyle(.tertiary)
                }
            }
            if let description = property.description {
                Text(description).appText(.reading).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// An answer, full width and stacked, the way `PermissionSheet` draws one: three
    /// buttons across a phone at the largest type sizes are three truncated words.
    @ViewBuilder
    private func option(_ title: String, _ description: String?, chosen: Bool,
                        ticks: Bool = false, choose: @escaping () -> Void) -> some View {
        let label = HStack(spacing: 8) {
            if ticks {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
            AnswerLabel(title: title, note: description, onFill: chosen)
        }
        if chosen {
            Button(action: choose) { label }
                .buttonStyle(.paperProminent)
                .controlSize(.large)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: choose) { label }
                .buttonStyle(.paper)
                .controlSize(.large)
        }
    }

    /// Text or a number typed in. The free-text box beside a question's choices comes
    /// through here too, under its own title — "Other", from the question tool.
    private func field(_ property: ElicitationSchema.Property) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            asked(property)
            TextField(placeholder(for: property), text: text(for: property), axis: .vertical)
                .appText(.reading)
                .lineLimit(1...5)
                .keyboardType(keyboard(for: property))
                .textInputAutocapitalization(capitalisation(for: property))
                .autocorrectionDisabled(isMachineText(property))
                .focused($focusedField, equals: property.name)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .paperWell(in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Under the page

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // On the last page, which question is still unanswered, since that is why
            // Submit will not go.
            if page == last, let problem = schema.problems(with: values).first {
                Text(problem)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if page > 0 {
                    Button {
                        step = page - 1
                    } label: {
                        Image(systemName: "chevron.backward")
                            .frame(minHeight: 22)
                    }
                    .buttonStyle(.paper)
                    .controlSize(.large)
                    .accessibilityLabel("Previous question")
                }
                // Saying no is an answer, and a form that cannot be finished from here
                // must still be something you can get out of.
                Button { send("No thanks", .decline, [:]) } label: {
                    AnswerLabel(title: "No thanks", note: nil)
                }
                .buttonStyle(.paper)
                .controlSize(.large)
                // Always offered short of the last page. Tapping an answer turns the
                // page by itself, so Next is the way past what a tap cannot answer: a
                // box, a list to tick, a question left for later. Whether the whole
                // answer will do is Submit's business.
                if page < last {
                    Button {
                        focusedField = nil
                        step = page + 1
                    } label: {
                        AnswerLabel(title: "Next", note: nil)
                    }
                    .buttonStyle(.paper)
                    .controlSize(.large)
                } else {
                    Button {
                        focusedField = nil
                        send(summary, .accept, values)
                    } label: {
                        AnswerLabel(title: "Submit", note: nil, onFill: true)
                    }
                    .buttonStyle(.paperProminent)
                    .controlSize(.large)
                    .disabled(!schema.problems(with: values).isEmpty)
                }
            }
        }
    }

    /// What is shown going while the answer travels: the first choice made, which is
    /// usually the substance of it, or just that it was sent.
    private var summary: String {
        for property in schema.properties {
            if case .string(_, _, _, let choices?) = property.kind,
               let value = values[property.name]?.stringValue,
               let choice = choices.first(where: { $0.value == value }) {
                return choice.title
            }
        }
        return "Your answers"
    }

    // MARK: Values

    private func chosen(_ name: String) -> [String] {
        values[name]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Text is kept as text, and a number as a number once it reads as one, so the
    /// daemon's check on the shape sees what the agent asked for.
    private func text(for property: ElicitationSchema.Property) -> Binding<String> {
        Binding(
            get: {
                switch values[property.name] {
                case .string(let text): return text
                case .int(let value): return String(value)
                case .double(let value): return String(value)
                default: return ""
                }
            },
            set: { typed in
                switch property.kind {
                case .integer:
                    values[property.name] = Int(typed).map(JSONValue.int) ?? .string(typed)
                case .number:
                    values[property.name] = Double(typed).map(JSONValue.double) ?? .string(typed)
                default:
                    values[property.name] = .string(typed)
                }
                // Emptied is not answered: an optional box left blank must not stop
                // Submit with a complaint about its shape.
                if typed.isEmpty { values[property.name] = nil }
            })
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let moment: ISO8601DateFormatter = ISO8601DateFormatter()

    private func date(for property: ElicitationSchema.Property,
                      format: DateFormatter) -> Binding<Date> {
        Binding(get: { values[property.name]?.stringValue.flatMap(format.date(from:)) ?? .now },
                set: { values[property.name] = .string(format.string(from: $0)) })
    }

    private func date(for property: ElicitationSchema.Property,
                      format: ISO8601DateFormatter) -> Binding<Date> {
        Binding(get: { values[property.name]?.stringValue.flatMap(format.date(from:)) ?? .now },
                set: { values[property.name] = .string(format.string(from: $0)) })
    }

    private func placeholder(for property: ElicitationSchema.Property) -> String {
        switch property.kind {
        case .integer, .number: return "A number"
        case .string(.email?, _, _, _): return "name@example.com"
        case .string(.uri?, _, _, _): return "https://"
        default: return "Your answer"
        }
    }

    private func keyboard(for property: ElicitationSchema.Property) -> UIKeyboardType {
        switch property.kind {
        case .integer: return .numberPad
        case .number: return .decimalPad
        case .string(.email?, _, _, _): return .emailAddress
        case .string(.uri?, _, _, _): return .URL
        default: return .default
        }
    }

    private func isMachineText(_ property: ElicitationSchema.Property) -> Bool {
        switch property.kind {
        case .string(.email?, _, _, _), .string(.uri?, _, _, _): return true
        default: return false
        }
    }

    private func capitalisation(for property: ElicitationSchema.Property) -> TextInputAutocapitalization {
        isMachineText(property) ? .never : .sentences
    }

    private func fillInDefaults() {
        for property in schema.properties where values[property.name] == nil {
            if let value = property.defaultValue { values[property.name] = value }
        }
    }
}

/// An answer's words on a button: full width, wrapping rather than truncating, with
/// what it means underneath.
///
/// `onFill` is about contrast and was found by looking at it: what a choice means is
/// often the substance of the question, and `.secondary` on the prominent fill is the
/// one place it has no contrast left. On a fill the note is the fill's own text colour
/// held back a little; off one, `.secondary` as usual.
struct AnswerLabel: View {
    let title: String
    let note: String?
    var onFill = false

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
            if let note, !note.isEmpty {
                Text(note)
                    .appText(.fine)
                    .foregroundStyle(onFill ? AnyShapeStyle(Paper.ground.opacity(0.85))
                                            : AnyShapeStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}
