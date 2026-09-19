import Foundation

/// One configurable option, exactly as the runtime advertised it.
///
/// This is the whole of the start form. All three runtimes advertise their models,
/// their modes and their effort levels through this one list, in this one shape, while
/// the older dedicated fields are sent inconsistently and are being retired. Nothing
/// here is interpreted: the form renders by kind, orders by `category`, and knows
/// nothing about what a model or a mode is.
public struct ConfigOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var category: String?
    public var kind: Kind
    public var currentValue: JSONValue?

    /// What the control is. The protocol has two kinds and reserves the right to add
    /// more, so a kind we do not know is carried as itself rather than guessed at.
    public enum Kind: Hashable, Sendable {
        /// Choices, in groups. A runtime that sends a flat list has one unnamed group,
        /// which is the common case and the only one any runtime sends today.
        case select([ConfigChoiceGroup])
        case boolean
        case unsupported(String)

        public var wireName: String {
            switch self {
            case .select: return "select"
            case .boolean: return "boolean"
            case .unsupported(let name): return name
            }
        }
    }

    public init(id: String, name: String, description: String? = nil, category: String? = nil,
                kind: Kind, currentValue: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.kind = kind
        self.currentValue = currentValue
    }

    /// The shape the rest of the app and the tests use for a plain list of choices.
    public init(id: String, name: String, description: String? = nil, category: String? = nil,
                type: String, currentValue: JSONValue? = nil, options: [ConfigChoice]? = nil) {
        let kind: Kind
        switch type {
        case "select": kind = .select([ConfigChoiceGroup(name: nil, choices: options ?? [])])
        case "boolean": kind = .boolean
        default: kind = .unsupported(type)
        }
        self.init(id: id, name: name, description: description, category: category,
                  kind: kind, currentValue: currentValue)
    }

    /// Every choice, in order, with its group forgotten. What a menu shows when it is
    /// not drawing headings, and what a test asserts on.
    public var options: [ConfigChoice]? {
        guard case .select(let groups) = kind else { return nil }
        return groups.flatMap(\.choices)
    }

    public var groups: [ConfigChoiceGroup] {
        guard case .select(let groups) = kind else { return [] }
        return groups
    }

    public var isBoolean: Bool { kind == .boolean }

    /// An option of a kind we cannot draw is skipped rather than guessed at. A select
    /// with nothing to select from is not a control either.
    public var isRenderable: Bool {
        switch kind {
        case .select(let groups): return groups.contains { !$0.choices.isEmpty }
        case .boolean: return true
        case .unsupported: return false
        }
    }

    /// The order the form puts categories in. Anything unrecognised goes last, in the
    /// order the runtime sent it, so a new category appears rather than disappearing.
    public static let categoryOrder = ["mode", "model", "thought_level", "model_config", "permissions"]

    public var categoryRank: Int {
        guard let category, let i = Self.categoryOrder.firstIndex(of: category) else {
            return Self.categoryOrder.count
        }
        return i
    }

    /// Whether this option is about what the agent is allowed to do.
    ///
    /// Permission sits apart from the rest: it is the one that changes what an agent
    /// can do to a folder, and the others only change how well it does it. Claude's
    /// `mode` is its permission mode, and Copilot advertises both a mode and an
    /// allow-all, so this goes by category rather than by runtime.
    public var isAboutPermission: Bool {
        guard let category else { return false }
        return category == "mode" || category == "permissions"
    }

    /// What the control reads when it is closed: the choice, and nothing else.
    ///
    /// No label. Which setting it is comes from where it sits in the row and from
    /// what it says when opened, and a line of captioned controls reads as a form.
    public func closedTitle(for value: JSONValue?) -> String {
        choiceName(for: value) ?? name
    }

    func choiceName(for value: JSONValue?) -> String? {
        let chosen = value ?? currentValue
        return (options ?? []).first { $0.value == chosen }?.name
    }

    // MARK: Reading what a runtime sent

    /// Read a list of options out of whatever the runtime sent.
    ///
    /// Nothing in here may fail a session. An option with a shape we cannot read costs
    /// that option; a list we cannot read at all costs the list. This is deliberate and
    /// is the bug feature 003 exists to fix: the options arrive inside the `session/new`
    /// result, so a strict decode there fails the start rather than one control.
    public static func list(in value: JSONValue?) -> [ConfigOption] {
        guard let entries = value?.arrayValue else { return [] }
        return entries.compactMap(ConfigOption.init(wire:))
    }

    public init?(wire: JSONValue) {
        guard let id = wire["id"]?.stringValue else { return nil }
        self.id = id
        self.name = wire["name"]?.stringValue ?? id
        self.description = wire["description"]?.stringValue
        self.category = wire["category"]?.stringValue
        self.currentValue = wire["currentValue"]
        switch wire["type"]?.stringValue {
        case "select", nil:
            self.kind = .select(ConfigChoiceGroup.groups(in: wire["options"]))
        case "boolean":
            self.kind = .boolean
        case .some(let other):
            self.kind = .unsupported(other)
        }
    }

    // MARK: Stored

    enum CodingKeys: String, CodingKey {
        case id, name, description, category, type, currentValue, options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        currentValue = try c.decodeIfPresent(JSONValue.self, forKey: .currentValue)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "select"
        switch type {
        case "select":
            let raw = try c.decodeIfPresent(JSONValue.self, forKey: .options)
            kind = .select(ConfigChoiceGroup.groups(in: raw))
        case "boolean":
            kind = .boolean
        default:
            kind = .unsupported(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encode(kind.wireName, forKey: .type)
        try c.encodeIfPresent(currentValue, forKey: .currentValue)
        if case .select(let groups) = kind {
            // A single unnamed group is written back as the flat list it came in as,
            // so a record stays the shape the runtime sent.
            if groups.count == 1, groups[0].name == nil {
                try c.encode(groups[0].choices, forKey: .options)
            } else {
                try c.encode(groups, forKey: .options)
            }
        }
    }
}

/// Choices under a heading. The protocol allows a runtime to group its models, which
/// none of the three does today, and which used to fail the whole start.
public struct ConfigChoiceGroup: Codable, Hashable, Sendable, Identifiable {
    public var name: String?
    public var choices: [ConfigChoice]

    public var id: String { name ?? "" }

    public init(name: String?, choices: [ConfigChoice]) {
        self.name = name
        self.choices = choices
    }

    enum CodingKeys: String, CodingKey {
        case group, name, options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        choices = try c.decodeIfPresent([ConfigChoice].self, forKey: .options) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(name, forKey: .group)
        try c.encode(choices, forKey: .options)
    }

    /// Read either shape: a flat list of choices, or a list of groups. A malformed
    /// entry costs itself and nothing else.
    static func groups(in value: JSONValue?) -> [ConfigChoiceGroup] {
        guard let entries = value?.arrayValue else { return [] }
        var flat: [ConfigChoice] = []
        var grouped: [ConfigChoiceGroup] = []
        for entry in entries {
            if entry["group"] != nil || (entry["options"] != nil && entry["value"] == nil) {
                let choices = (entry["options"]?.arrayValue ?? []).compactMap(ConfigChoice.init(wire:))
                guard !choices.isEmpty else { continue }
                grouped.append(ConfigChoiceGroup(name: entry["name"]?.stringValue
                                                 ?? entry["group"]?.stringValue,
                                                 choices: choices))
            } else if let choice = ConfigChoice(wire: entry) {
                flat.append(choice)
            }
        }
        if !flat.isEmpty { grouped.insert(ConfigChoiceGroup(name: nil, choices: flat), at: 0) }
        return grouped
    }
}

public struct ConfigChoice: Codable, Hashable, Sendable, Identifiable {
    public var value: JSONValue
    public var name: String
    public var description: String?

    public var id: String { value.stringValue ?? name }

    public init(value: JSONValue, name: String, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }

    /// A choice with no value is not a choice. This is the entry the audit found: a
    /// group in the list where an option was expected, which failed the whole decode.
    init?(wire: JSONValue) {
        guard let value = wire["value"] else { return nil }
        self.value = value
        self.name = wire["name"]?.stringValue ?? value.stringValue ?? "Unnamed"
        self.description = wire["description"]?.stringValue
    }
}

/// What the user chose when starting an agent, kept so that picking it up later starts
/// the runtime the same way.
public struct StartOptions: Codable, Hashable, Sendable {
    /// Keyed by the advertised option id: `model`, `mode`, `reasoning_effort`, and
    /// whatever a runtime invents next.
    public var values: [String: JSONValue]

    /// The free-text field, already split the way a shell would.
    public var extraArguments: [String]

    public init(values: [String: JSONValue] = [:], extraArguments: [String] = []) {
        self.values = values
        self.extraArguments = extraArguments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decodeIfPresent([String: JSONValue].self, forKey: .values) ?? [:]
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
    }

    public static let none = StartOptions()
}
