import Foundation

/// A structured question from an agent.
///
/// The permission question grown up: held by the daemon, answerable from any window,
/// surviving having no window at all. The difference is that this one has a shape, and
/// an answer that does not fit the shape is not sent.
public struct ElicitationRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Theirs, where the request carried one, so `elicitation/complete` can withdraw it.
    public var elicitationID: String?
    public var agentID: UUID
    /// What the agent is asking for, in its own words.
    ///
    /// The question itself lives here, not in the schema: a one-question form arrives
    /// with an untitled field and the whole question in `message`.
    public var message: String?
    public var mode: Mode
    public var scope: Scope
    public var askedAt: Date
    /// An agent's `ask_secret` (#2885): the form's one field is drawn masked, and the host
    /// seals what is typed in the person's store. Nil for every other form.
    public var secret: Secret?
    /// An agent's `hand_to_person` (#3529): one step the person does on the page in the
    /// machine's browser. The form is one choice, Done or Can't do it; a client that shows
    /// the machine's browser adds Open the page. Nil for every other form.
    public var handOff: HandOff?

    /// One step on a page, handed to the person.
    public struct HandOff: Codable, Hashable, Sendable {
        /// What the person does: "Solve the CAPTCHA".
        public var step: String
        /// Why the agent needs them.
        public var reason: String?

        public init(step: String, reason: String? = nil) {
            self.step = step
            self.reason = reason
        }
    }

    /// One named secret an agent asks for.
    public struct Secret: Codable, Hashable, Sendable {
        /// As an environment variable: `OPENAI_API_KEY`.
        public var name: String
        /// Where to get it, when the agent knows.
        public var url: String?
        /// One is saved already, and what is typed replaces it.
        public var isSet: Bool
        /// The host can keep it for this session only (#3548). False from an older host.
        public var canBeSessionOnly: Bool
        /// The host keeps it with Ask before use unless the answer says `needsApproval` false
        /// (#4014, #4016). False from an older host, which has no such flag.
        public var canAskBeforeUse: Bool
        /// The agent's description of it (#4167), for the person to change before Save.
        public var description: String?

        public init(name: String, url: String? = nil, isSet: Bool = false, canBeSessionOnly: Bool = false,
                    canAskBeforeUse: Bool = false, description: String? = nil) {
            self.name = name
            self.url = url
            self.isSet = isSet
            self.canBeSessionOnly = canBeSessionOnly
            self.canAskBeforeUse = canAskBeforeUse
            self.description = description
        }

        private enum CodingKeys: String, CodingKey { case name, url, isSet, canBeSessionOnly, canAskBeforeUse, description }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            isSet = try c.decode(Bool.self, forKey: .isSet)
            canBeSessionOnly = try c.decodeIfPresent(Bool.self, forKey: .canBeSessionOnly) ?? false
            canAskBeforeUse = try c.decodeIfPresent(Bool.self, forKey: .canAskBeforeUse) ?? false
            description = try c.decodeIfPresent(String.self, forKey: .description)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encode(isSet, forKey: .isSet)
            if canBeSessionOnly { try c.encode(true, forKey: .canBeSessionOnly) }
            if canAskBeforeUse { try c.encode(true, forKey: .canAskBeforeUse) }
            try c.encodeIfPresent(description, forKey: .description)
        }
    }

    public enum Mode: Codable, Hashable, Sendable {
        case form(ElicitationSchema)
        /// Go and look at this, then come back and say how it went.
        case url(String)
    }

    /// Whether the answer outlives the turn that asked for it.
    public enum Scope: String, Codable, Hashable, Sendable {
        case session, request
    }

    public init(id: UUID = UUID(), elicitationID: String? = nil, agentID: UUID,
                message: String? = nil, mode: Mode, scope: Scope = .request,
                askedAt: Date = Date(), secret: Secret? = nil, handOff: HandOff? = nil) {
        self.id = id
        self.elicitationID = elicitationID
        self.agentID = agentID
        self.message = message
        self.mode = mode
        self.scope = scope
        self.askedAt = askedAt
        self.secret = secret
        self.handOff = handOff
    }

    /// Read a request off the wire. Nil when we cannot draw it, which is a decline
    /// rather than a half-answer.
    public init?(wire: JSONValue?, agentID: UUID) {
        guard let wire else { return nil }
        let mode: Mode
        if let url = wire["url"]?.stringValue {
            mode = .url(url)
        } else if let schema = ElicitationSchema(wire: wire["requestedSchema"]) {
            mode = .form(schema)
        } else {
            return nil
        }
        self.init(id: UUID(),
                  elicitationID: wire["elicitationId"]?.stringValue,
                  agentID: agentID,
                  message: wire["message"]?.stringValue,
                  mode: mode,
                  // Tied to a session, unless it names the request it belongs to —
                  // which is how a runtime asks before there is a session at all.
                  scope: wire["requestId"] == nil ? .session : .request)
    }

    /// A hand-off's answer, as its form takes it: Done, or Can't do it with what stopped
    /// them (#3529). The daemon names the choice `outcome` and the line beside it
    /// `outcome_note`, as `ask_question` names a choice and its note.
    public static func handOffAnswer(done: Bool, note: String = "") -> [String: JSONValue] {
        guard !done else { return ["outcome": .string("done")] }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? ["outcome": .string("cannot")] : ["outcome": .string("cannot"), "outcome_note": .string(note)]
    }

    /// The one field of a secret's form, as the daemon names it.
    public static let secretField = "value"
    /// The answer's choice to keep the secret for this session only (#3548), beside the field.
    public static let sessionOnlyField = "sessionOnly"
    /// The answer's Ask before use (#4014, #4016): the host takes it as on when it is left out.
    public static let needsApprovalField = "needsApproval"
    /// The answer's description (#4167), as the person left it: the host keeps it with the secret.
    public static let descriptionField = "description"

    /// A secret card's answer: the value, the choice to keep it for this session only, Ask
    /// before use (nil, for a host that has no such flag, sends none) and the description (nil
    /// sends none, and the host keeps the agent's).
    public static func secretAnswer(_ typed: String, sessionOnly: Bool, askBeforeUse: Bool? = nil,
                                    description: String? = nil) -> [String: JSONValue] {
        var content: [String: JSONValue] = [secretField: .string(typed)]
        if sessionOnly { content[sessionOnlyField] = .bool(true) }
        if let askBeforeUse { content[needsApprovalField] = .bool(askBeforeUse) }
        if let description { content[descriptionField] = .string(description) }
        return content
    }

    /// Why the agent asks for its secret: the one field's title.
    public var secretReason: String? {
        guard secret != nil, case .form(let schema) = mode else { return nil }
        return schema.properties.first?.title
    }

    public var title: String {
        switch mode {
        case .form(let schema): return schema.title ?? message ?? "The agent needs something"
        case .url: return "The agent wants you to open a page"
        }
    }
}

/// The shape of what an agent is asking for: named properties, each with a kind.
public struct ElicitationSchema: Codable, Hashable, Sendable {
    public var title: String?
    public var description: String?
    public var properties: [Property]

    public init(title: String? = nil, description: String? = nil, properties: [Property]) {
        self.title = title
        self.description = description
        self.properties = properties
    }

    public init?(wire: JSONValue?) {
        guard let wire, let raw = wire["properties"]?.objectValue else { return nil }
        let required = Set((wire["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        // Ordered by the schema's own ordering where it gives one, and by name
        // otherwise, so the form does not shuffle between two draws of the same thing.
        let order = (wire["propertyOrder"]?.arrayValue ?? []).compactMap(\.stringValue)
        let names = order.isEmpty ? raw.keys.sorted() : order
        var properties: [Property] = []
        for name in names {
            guard let value = raw[name],
                  let property = Property(name: name, wire: value, isRequired: required.contains(name))
            else { return nil } // A property we cannot draw makes the whole form undrawable.
            properties.append(property)
        }
        guard !properties.isEmpty else { return nil }
        self.init(title: wire["title"]?.stringValue,
                  description: wire["description"]?.stringValue,
                  properties: properties)
    }

    /// The single choice this whole form is asking for, when that is all it asks.
    ///
    /// A form like this is a permission question wearing a schema, and the app already
    /// answers permission questions in one click: the agent's own wording, on buttons.
    /// A radio group plus a Send button asks for two clicks to say one word.
    ///
    /// Nil for anything else. Two properties, free text, a number or a multi-select
    /// cannot be answered by one click, so they keep the form and its Send — a partial
    /// answer must not become sendable.
    public var singleChoice: (property: Property, choices: [Property.Choice])? {
        guard properties.count == 1, let only = properties.first,
              case .string(_, _, _, let choices) = only.kind,
              let choices, !choices.isEmpty
        else { return nil }
        return (only, choices)
    }

    /// The properties grouped into what belongs on one page of the form.
    ///
    /// Two properties on the wire are sometimes one question to whoever is answering:
    /// this app's own question tool sends `question_0` for the choices and
    /// `question_0_custom` for the free-text box beside them, whose description reads
    /// "add to your selection above". Drawn a page apart, "above" points at nothing.
    /// So an optional free-text property named after the property before it travels
    /// with it. Everything else gets a page of its own.
    public var pages: [[Property]] {
        var pages: [[Property]] = []
        for property in properties {
            if let previous = pages.last?.last, property.isNote(on: previous) {
                pages[pages.count - 1].append(property)
            } else {
                pages.append([property])
            }
        }
        return pages
    }

    public struct Property: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        public var title: String?
        public var description: String?
        public var isRequired: Bool
        public var kind: Kind
        public var defaultValue: JSONValue?

        public var id: String { name }

        public enum Kind: Codable, Hashable, Sendable {
            case string(format: Format?, minLength: Int?, maxLength: Int?, choices: [Choice]?)
            case number(minimum: Double?, maximum: Double?)
            case integer(minimum: Int?, maximum: Int?)
            case boolean
            case multiSelect(items: [Choice], minItems: Int?, maxItems: Int?)
        }

        public enum Format: String, Codable, Hashable, Sendable {
            case email, uri, date
            case dateTime = "date-time"
        }

        public struct Choice: Codable, Hashable, Sendable, Identifiable {
            public var value: String
            public var title: String
            /// What picking this one means. The whole substance of a question is often
            /// here rather than in the labels, so it is drawn rather than dropped.
            public var description: String?
            public var id: String { value }

            public init(value: String, title: String? = nil, description: String? = nil) {
                self.value = value
                self.title = title ?? value
                self.description = description
            }
        }

        public init(name: String, title: String? = nil, description: String? = nil,
                    isRequired: Bool = false, kind: Kind, defaultValue: JSONValue? = nil) {
            self.name = name
            self.title = title
            self.description = description
            self.isRequired = isRequired
            self.kind = kind
            self.defaultValue = defaultValue
        }

        init?(name: String, wire: JSONValue, isRequired: Bool) {
            let kind: Kind
            switch wire["type"]?.stringValue {
            case "string":
                kind = .string(format: wire["format"]?.stringValue.flatMap(Format.init(rawValue:)),
                               minLength: wire["minLength"]?.intValue,
                               maxLength: wire["maxLength"]?.intValue,
                               choices: Self.choices(in: wire["enum"] ?? wire["oneOf"]))
            case "number":
                kind = .number(minimum: wire["minimum"].flatMap(Self.double(in:)),
                               maximum: wire["maximum"].flatMap(Self.double(in:)))
            case "integer":
                kind = .integer(minimum: wire["minimum"]?.intValue, maximum: wire["maximum"]?.intValue)
            case "boolean":
                kind = .boolean
            case "array":
                // Titled choices travel under `items.anyOf`, bare ones under
                // `items.enum`; a plain array of strings is allowed to be the items.
                let itemsWire = wire["items"]
                guard let items = Self.choices(in: itemsWire?["enum"] ?? itemsWire?["anyOf"] ?? itemsWire)
                else { return nil }
                kind = .multiSelect(items: items,
                                    minItems: wire["minItems"]?.intValue,
                                    maxItems: wire["maxItems"]?.intValue)
            default:
                return nil
            }
            self.init(name: name,
                      title: wire["title"]?.stringValue,
                      description: wire["description"]?.stringValue,
                      isRequired: isRequired,
                      kind: kind,
                      defaultValue: wire["default"])
        }

        private static func choices(in value: JSONValue?) -> [Choice]? {
            guard let entries = value?.arrayValue, !entries.isEmpty else { return nil }
            let choices = entries.compactMap { entry -> Choice? in
                if let plain = entry.stringValue { return Choice(value: plain) }
                // A titled option names its value `const`. `value` is what the older
                // MCP spelling used, and costs nothing to keep taking.
                guard let value = (entry["const"] ?? entry["value"])?.stringValue else { return nil }
                return Choice(value: value,
                              title: entry["title"]?.stringValue,
                              description: entry["description"]?.stringValue)
            }
            return choices.isEmpty ? nil : choices
        }

        private static func double(in value: JSONValue) -> Double? {
            switch value {
            case .double(let v): return v
            case .int(let v): return Double(v)
            default: return nil
            }
        }

        /// Whether this is the free-text box belonging to the question before it:
        /// unconstrained text, optional, and named after it — `question_0_custom`
        /// beside `question_0`. A required field, or one with a length or a format of
        /// its own, is a question in its own right and keeps its own page.
        func isNote(on previous: Property) -> Bool {
            guard !isRequired, name.hasPrefix(previous.name + "_"),
                  case .string(nil, nil, nil, nil) = kind
            else { return false }
            return true
        }

        /// Why this value will not do, or nil if it will.
        public func problem(with value: JSONValue?) -> String? {
            let missing = value == nil || value?.isNull == true
                || (value?.stringValue?.isEmpty ?? false)
                || (value?.arrayValue?.isEmpty ?? false)
            if missing { return isRequired ? "\(title ?? name) is needed" : nil }
            guard let value else { return nil }
            switch kind {
            case .string(let format, let minLength, let maxLength, let choices):
                guard let text = value.stringValue else { return "\(name) must be text" }
                if let minLength, text.count < minLength { return "At least \(minLength) characters" }
                if let maxLength, text.count > maxLength { return "At most \(maxLength) characters" }
                if let choices, !choices.contains(where: { $0.value == text }) { return "Not one of the choices" }
                if let format, !Self.matches(format, text) { return "Not a \(format.rawValue)" }
            case .number(let minimum, let maximum):
                guard let number = Self.double(in: value) else { return "\(name) must be a number" }
                if let minimum, number < minimum { return "At least \(minimum)" }
                if let maximum, number > maximum { return "At most \(maximum)" }
            case .integer(let minimum, let maximum):
                guard case .int(let number) = value else { return "\(name) must be a whole number" }
                if let minimum, number < minimum { return "At least \(minimum)" }
                if let maximum, number > maximum { return "At most \(maximum)" }
            case .boolean:
                guard value.boolValue != nil else { return "\(name) must be yes or no" }
            case .multiSelect(let items, let minItems, let maxItems):
                guard let chosen = value.arrayValue?.compactMap(\.stringValue) else { return "\(name) must be a list" }
                if let minItems, chosen.count < minItems { return "Choose at least \(minItems)" }
                if let maxItems, chosen.count > maxItems { return "Choose at most \(maxItems)" }
                if chosen.contains(where: { choice in !items.contains { $0.value == choice } }) {
                    return "Not one of the choices"
                }
            }
            return nil
        }

        private static func matches(_ format: Format, _ text: String) -> Bool {
            switch format {
            case .email:
                // Deliberately loose. The agent validates its own input; this is here
                // so the form does not send something obviously wrong.
                let parts = text.split(separator: "@")
                return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            case .uri:
                return URL(string: text)?.scheme != nil
            case .date:
                return text.count == 10 && ACP.timestamp(from: text + "T00:00:00Z") != nil
            case .dateTime:
                return ACP.timestamp(from: text) != nil
            }
        }
    }

    /// Every reason the answer will not do. Empty means it will.
    public func problems(with answer: [String: JSONValue]) -> [String] {
        properties.compactMap { $0.problem(with: answer[$0.name]) }
    }

    /// What was asked and what was said, one line a page, in the words the card showed:
    /// a choice's title rather than its value, and the free-text box beside a choice
    /// joined onto it. A page left empty is left out.
    ///
    /// `message` stands in for the question when a lone property has no title of its
    /// own, which is how a one-question form arrives.
    public func answers(_ content: [String: JSONValue], message: String? = nil) -> [ElicitationAnswer] {
        let pages = pages
        return pages.compactMap { page in
            guard let first = page.first else { return nil }
            let said = page.flatMap { $0.words(for: content[$0.name]) }
            guard !said.isEmpty else { return nil }
            let question = first.title
                ?? (pages.count == 1 ? message : nil)
                ?? first.description
                ?? first.name
            return ElicitationAnswer(question: question, answer: said.joined(separator: ", "))
        }
    }
}

extension ElicitationSchema.Property {
    /// The value as the card drew it, or nothing when there is none.
    func words(for value: JSONValue?) -> [String] {
        guard let value, !value.isNull else { return [] }
        switch kind {
        case .string(_, _, _, let choices):
            guard let text = value.stringValue, !text.isEmpty else { return [] }
            return [choices?.first { $0.value == text }?.title ?? text]
        case .multiSelect(let items, _, _):
            return (value.arrayValue ?? []).compactMap(\.stringValue).map { chosen in
                items.first { $0.value == chosen }?.title ?? chosen
            }
        case .boolean:
            return value.boolValue.map { [$0 ? "Yes" : "No"] } ?? []
        case .number, .integer:
            switch value {
            case .int(let n): return [String(n)]
            case .double(let n): return [n.formatted()]
            default: return value.stringValue.map { [$0] } ?? []
            }
        }
    }
}

/// One question on a form and what the person said to it, kept in the record so the
/// conversation shows the answer after the card has gone.
public struct ElicitationAnswer: Codable, Hashable, Sendable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// What the user did with a form.
public enum ElicitationOutcome: Hashable, Sendable {
    case accept([String: JSONValue])
    /// Said no. An answer, not a failure: the agent carries on.
    case decline
    /// Closed it, or the agent withdrew it.
    case cancel

    public var wire: JSONValue {
        switch self {
        case .accept(let content):
            return ["action": "accept", "content": .object(content)]
        case .decline:
            return ["action": "decline"]
        case .cancel:
            return ["action": "cancel"]
        }
    }

    public var summary: String {
        switch self {
        case .accept: return "You answered the agent's form"
        case .decline: return "You declined the agent's form"
        case .cancel: return "The form was closed"
        }
    }
}
