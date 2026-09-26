import Foundation

/// One move of one chat from one runtime to another (052, `switches.jsonl`, and the
/// note in the chat).
public struct SwitchRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var at: Date
    public var agentID: UUID
    public var from: Side
    public var to: Side
    public var reason: Reason
    /// Each setting the new runtime started with, and where its value came from.
    public var carried: [CarriedSetting]
    public var dropped: [Dropped]
    /// How many earlier turns the handoff left out, when it had to shorten.
    public var shortened: Int?
    /// How the entry switched onto is paid for.
    public var billing: Payment
    /// The old runtime's expected return, for "until 07:00".
    public var fromReturnsAt: Date?

    public init(id: UUID = UUID(), at: Date, agentID: UUID, from: Side, to: Side, reason: Reason,
                carried: [CarriedSetting] = [], dropped: [Dropped] = [], shortened: Int? = nil,
                billing: Payment, fromReturnsAt: Date? = nil) {
        self.id = id
        self.at = at
        self.agentID = agentID
        self.from = from
        self.to = to
        self.reason = reason
        self.carried = carried
        self.dropped = dropped
        self.shortened = shortened
        self.billing = billing
        self.fromReturnsAt = fromReturnsAt
    }

    public struct Side: Codable, Hashable, Sendable {
        public var entryID: UUID?
        public var runtimeID: String
        public var model: JSONValue?
        public var mode: JSONValue?

        public init(entryID: UUID? = nil, runtimeID: String, model: JSONValue? = nil, mode: JSONValue? = nil) {
            self.entryID = entryID
            self.runtimeID = runtimeID
            self.model = model
            self.mode = mode
        }
    }

    public enum Reason: String, Codable, Hashable, Sendable {
        case allowanceSpent, overage, creditUsedUp, rateLimitPersisted, everyoneOutResumed, byHand
    }
}

/// One setting on the new runtime, and why it has the value it has (FR-015a).
public struct CarriedSetting: Codable, Hashable, Sendable {
    public var optionID: String
    public var name: String
    public var from: JSONValue?
    public var to: JSONValue?
    public var source: Source

    public init(optionID: String, name: String, from: JSONValue?, to: JSONValue?, source: Source) {
        self.optionID = optionID
        self.name = name
        self.from = from
        self.to = to
        self.source = source
    }

    public enum Source: Codable, Hashable, Sendable {
        case level(String)
        case sameValue
        case poolEntry
        case remembered
        case runtimeDefault
        case strictestMode
        case closestNoLooser
        case person
    }
}

/// Something that did not carry over, said plainly in the note and on the sheet.
public enum Dropped: Codable, Hashable, Sendable {
    case extraArguments([String])
    case alwaysAllow(count: Int)
    case queuedSlashCommand(String)
}
