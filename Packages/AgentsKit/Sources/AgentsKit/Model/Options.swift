import Foundation

/// One configurable option, exactly as the runtime advertised it.
///
/// This is the whole of the start form. All three runtimes advertise their models,
/// their modes and their effort levels through this one list, in this one shape, while
/// the older dedicated fields are sent inconsistently and are being retired. Nothing
/// here is interpreted: the form renders by `type`, orders by `category`, and knows
/// nothing about what a model or a mode is.
public struct ConfigOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var category: String?
    public var type: String
    public var currentValue: JSONValue?
    public var options: [ConfigChoice]?

    public init(id: String, name: String, description: String? = nil, category: String? = nil,
                type: String, currentValue: JSONValue? = nil, options: [ConfigChoice]? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.type = type
        self.currentValue = currentValue
        self.options = options
    }

    /// `select` is the only type all three runtimes use today. An option of a type we
    /// do not know is skipped rather than guessed at.
    public var isRenderable: Bool { type == "select" && !(options ?? []).isEmpty }

    /// The order the form puts categories in. Anything unrecognised goes last, in the
    /// order the runtime sent it, so a new category appears rather than disappearing.
    public static let categoryOrder = ["mode", "model", "thought_level", "model_config", "permissions"]

    public var categoryRank: Int {
        guard let category, let i = Self.categoryOrder.firstIndex(of: category) else {
            return Self.categoryOrder.count
        }
        return i
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
