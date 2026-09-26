import Foundation

/// Methods a runtime invented, which we answer or listen for by name.
///
/// Each is keyed on the method, or on the capability the runtime advertised for it,
/// never on which runtime sent it: a second runtime that speaks the same method gets
/// the same behaviour for free. The research behind each is
/// `.agents/research/acp-vendor-extensions.md`.
extension ACP {
    public enum ExtensionMethod {
        /// Cursor's todo list. A request, not a notification: Cursor sends it through
        /// `extMethod`, which its SDK makes a `sendRequest`, and ignores the answer.
        public static let updateTodos = "cursor/update_todos"
        /// Cursor's question tool, blocking until answered. On `-32601` Cursor falls
        /// back to one permission prompt per single-choice question and drops the rest.
        public static let askQuestion = "cursor/ask_question"
        /// Which account the runtime is using, pushed whenever it changes. Sent by any
        /// runtime whose `agentCapabilities._meta.authStatus` is set: the Claude adapter
        /// and codex-acp today, until upstream's `auth/status` replaces it.
        public static let authStatusUpdate = "_auth/status_update"
    }
}

// MARK: Todos

/// A runtime's todo list, kept by id so a partial update can be laid over it.
///
/// Cursor sends `{todos: [{id, content, status}], merge}`: `merge: true` updates the
/// entries it names and adds the ones it does not, `false` is the whole list again.
/// Shown as the session's plan, where every other runtime's plan already goes.
public struct TodoList: Hashable, Sendable {
    public private(set) var items: [Item] = []

    public struct Item: Hashable, Sendable {
        public var id: String
        public var content: String
        public var status: String
    }

    public init() {}

    /// Lay one `cursor/update_todos` over the list. False when the params carried no
    /// list at all, which changes nothing.
    public mutating func apply(_ params: JSONValue?) -> Bool {
        guard let todos = params?["todos"]?.arrayValue else { return false }
        let incoming = todos.compactMap { todo -> Item? in
            guard let id = todo["id"]?.stringValue, let content = todo["content"]?.stringValue else { return nil }
            return Item(id: id, content: content, status: todo["status"]?.stringValue ?? "pending")
        }
        guard params?["merge"]?.boolValue == true else {
            items = incoming
            return true
        }
        for item in incoming {
            if let existing = items.firstIndex(where: { $0.id == item.id }) {
                items[existing] = item
            } else {
                items.append(item)
            }
        }
        return true
    }

    /// The list as a plan. A cancelled todo is left out: the plan says what the agent
    /// is going to do, and a plan entry has no way to say "not any more".
    public var plan: Plan {
        Plan(planID: nil, entries: items.compactMap { item in
            guard item.status != "cancelled" else { return nil }
            return PlanEntry(content: item.content,
                             status: PlanEntry.Status(rawValue: item.status) ?? .pending)
        })
    }
}

// MARK: Questions

/// Cursor's `ask_question`, drawn as the form card an elicitation already gets.
///
/// `{toolCallId, title, questions: [{id, prompt, options: [{id, label}], allowMultiple}]}`
/// becomes one property per question, named by the question's id, so the answer comes
/// back keyed the way Cursor wants it. Every question is optional: Cursor takes an
/// answer to some of them, which its own fallback also gives.
public enum CursorQuestion {
    /// Nil for a question set we cannot draw, which is left to Cursor's own fallback.
    public static func request(from params: JSONValue?, agentID: UUID) -> ElicitationRequest? {
        guard let questions = params?["questions"]?.arrayValue, !questions.isEmpty else { return nil }
        var properties: [ElicitationSchema.Property] = []
        for question in questions {
            guard let id = question["id"]?.stringValue else { return nil }
            let choices = (question["options"]?.arrayValue ?? []).compactMap { option -> ElicitationSchema.Property.Choice? in
                guard let value = option["id"]?.stringValue else { return nil }
                return .init(value: value, title: option["label"]?.stringValue)
            }
            guard !choices.isEmpty else { return nil }
            let kind: ElicitationSchema.Property.Kind = question["allowMultiple"]?.boolValue == true
                ? .multiSelect(items: choices, minItems: nil, maxItems: nil)
                : .string(format: nil, minLength: nil, maxLength: nil, choices: choices)
            properties.append(.init(name: id, title: question["prompt"]?.stringValue, kind: kind))
        }
        let title = params?["title"]?.stringValue
        return ElicitationRequest(agentID: agentID,
                                  message: title ?? (questions.count == 1 ? properties[0].title : nil),
                                  mode: .form(ElicitationSchema(title: title, properties: properties)))
    }

    /// The card's outcome in Cursor's reply shape. An accepted form with nothing
    /// chosen is a skip, which is what Cursor's fallback says for the same thing.
    public static func reply(to outcome: ElicitationOutcome) -> JSONValue {
        switch outcome {
        case .accept(let content):
            let answers = content.keys.sorted().compactMap { questionID -> JSONValue? in
                let chosen: [String]
                switch content[questionID] {
                case .string(let one)?: chosen = [one]
                case .array(let many)?: chosen = many.compactMap(\.stringValue)
                default: chosen = []
                }
                guard !chosen.isEmpty else { return nil }
                return ["questionId": .string(questionID),
                        "selectedOptionIds": .array(chosen.map { .string($0) })]
            }
            guard !answers.isEmpty else { return ["outcome": ["outcome": "skipped"]] }
            return ["outcome": ["outcome": "answered", "answers": .array(answers)]]
        case .decline:
            return ["outcome": ["outcome": "skipped", "reason": "The user skipped the questions"]]
        case .cancel:
            return ["outcome": ["outcome": "cancelled"]]
        }
    }
}

// MARK: Who is signed in

/// Which kind of account a runtime says it is using, from `_auth/status_update`.
///
/// Only what the runtime menu shows: the kind and the runtime's own label for it
/// ("Claude Max", "Anthropic API key"). The payload also carries the account's email
/// and organisation, which are never read, so they are never stored or relayed.
public struct AuthStatus: Codable, Hashable, Sendable {
    /// `account`, `api_key`, `gateway`, `external` or `none`. Kept as the runtime's
    /// own word, so a kind invented later still decodes on an older phone.
    public var kind: String
    public var label: String

    public init(kind: String, label: String) {
        self.kind = kind
        self.label = label
    }

    /// Read from the notification's params. Nil for a payload with no kind.
    public init?(wire: JSONValue?) {
        guard let status = wire?["authStatus"], let kind = status["kind"]?.stringValue else { return nil }
        self.init(kind: kind, label: status["label"]?.stringValue ?? kind)
    }

    /// The runtime says, in so many words, that nobody is signed in.
    public var isSignedOut: Bool { kind == "none" }
}
