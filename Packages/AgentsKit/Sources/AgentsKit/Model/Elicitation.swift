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
                askedAt: Date = Date()) {
        self.id = id
        self.elicitationID = elicitationID
        self.agentID = agentID
        self.message = message
        self.mode = mode
        self.scope = scope
        self.askedAt = askedAt
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

extension PermissionOption {
    /// The two options for a question the app is asking on an agent's behalf, when the
    /// agent gave us none of its own. Used for a served file write.
    public static let allowOrReject: [PermissionOption] = [
        PermissionOption(optionID: "allow_once", name: "Allow", kind: .allowOnce),
        PermissionOption(optionID: "reject_once", name: "Refuse", kind: .rejectOnce),
    ]
}
