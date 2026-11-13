import Foundation

// Resource leases (036): the types a lease is made of.
//
// Here, in the half both platforms hold, because the phone draws a status line from
// the same snapshot the Mac does. What decides who gets what is `LeaseBook`, beside
// this; what applies it is the daemon.

/// What a resource is called, in the form two agents' spellings are compared by.
///
/// Trimmed and lowercased, so "Screen", " screen " and "SCREEN" are one line to wait
/// in rather than three (FR-013). Anything else about the name is kept: a port called
/// "8080" and one called "port 8080" are two resources, because nothing here can know
/// they are the same.
public struct ResourceName: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let key: String

    /// Nil for a name that is only spaces. A lease on nothing is refused, not granted.
    public init?(_ given: String) {
        let key = given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        self.key = key
    }

    public var description: String { key }

    public static func < (a: ResourceName, b: ResourceName) -> Bool { a.key < b.key }

    /// The screen, mouse and keyboard: what an agent holds before clicking or typing
    /// into anything (spec, Assumptions).
    public static let screen = ResourceName("screen")!
}

extension ResourceName: Codable, CodingKeyRepresentable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let name = ResourceName(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "An empty resource name."))
        }
        self = name
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }

    public var codingKey: any CodingKey { Key(stringValue: key) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(codingKey.stringValue)
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Where a resource came from. The first three the app finds on the Mac; anything
/// else is a name an agent chose, such as a port or an account.
public enum ResourceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case screen
    case simulator
    case browser
    case named
}

/// A resource the person declared ahead of time, with what it is for (#116).
///
/// Kept by each host, beside its book: a lease is a turn with something on one
/// machine, and "build" on this Mac and "build" on a Linux server are two machines'
/// worth of compiling. It exists whether or not anyone holds it, so `list_resources`
/// and the Resources page can say it, with its description, while it is free.
public struct DeclaredResource: Codable, Hashable, Sendable, Identifiable {
    public var name: ResourceName
    /// As the person typed it: "build", "Staging DB".
    public var displayName: String
    /// What it is for and when to take it. Agents read this, and are told to lease the
    /// resource whenever it applies.
    public var description: String
    /// How many agents may hold it at once. One is a lock; more is a counted line.
    public var holders: Int
    /// What a lease lasts when the agent does not say. Nil is `LeaseLimits.defaultMinutes`.
    public var defaultMinutes: Int?
    /// The longest one may run. Nil is `LeaseLimits.maximumMinutes`, which no
    /// declaration can go past.
    public var maximumMinutes: Int?

    public var id: ResourceName { name }

    public init(name: ResourceName, displayName: String? = nil, description: String, holders: Int = 1,
                defaultMinutes: Int? = nil, maximumMinutes: Int? = nil) {
        self.name = name
        self.displayName = displayName ?? name.key
        self.description = description
        self.holders = holders
        self.defaultMinutes = defaultMinutes
        self.maximumMinutes = maximumMinutes
    }

    /// The rules a lease on it runs by.
    public var rules: LeaseRules {
        LeaseRules(holders: holders, defaultMinutes: defaultMinutes, maximumMinutes: maximumMinutes)
    }

    /// The most holders one declaration may allow. A counted line of more than this
    /// is not taking turns any more.
    public static let mostHolders = 20

    /// Why it cannot be kept as it stands, in a sentence for the person; nil when it can.
    public var problem: String? {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give it a name." }
        if ResourceKind.isFoundName(name) {
            return "\(displayName) is found on the Mac by itself; choose another name."
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Say what it is for, so agents know when to take it."
        }
        if !(1...Self.mostHolders).contains(holders) {
            return "Between 1 and \(Self.mostHolders) agents may hold it at once."
        }
        let ceiling = maximumMinutes ?? LeaseLimits.maximumMinutes
        if !(1...LeaseLimits.maximumMinutes).contains(ceiling) {
            return "The longest a lease can run is between 1 and \(LeaseLimits.maximumMinutes) minutes."
        }
        if let given = defaultMinutes, !(1...ceiling).contains(given) {
            return "The usual length is between 1 minute and the longest, \(ceiling)."
        }
        return nil
    }
}

/// How many may hold a resource at once, and how long a lease on it runs. Every
/// resource has the standard ones unless the person declared it otherwise.
public struct LeaseRules: Codable, Hashable, Sendable {
    public var holders: Int
    public var defaultMinutes: Int?
    public var maximumMinutes: Int?

    public init(holders: Int = 1, defaultMinutes: Int? = nil, maximumMinutes: Int? = nil) {
        self.holders = max(1, holders)
        self.defaultMinutes = defaultMinutes
        self.maximumMinutes = maximumMinutes
    }

    public static let standard = LeaseRules()

    /// The longest a lease may run, in minutes: the declaration's, never past the app's.
    public var ceiling: Int { min(maximumMinutes ?? LeaseLimits.maximumMinutes, LeaseLimits.maximumMinutes) }

    /// The length asked for, in seconds, and whether it had to be cut to the longest
    /// allowed. Nothing shorter than a minute.
    public func length(_ minutes: Int?) -> (TimeInterval, capped: Bool) {
        let asked = max(1, minutes ?? min(defaultMinutes ?? LeaseLimits.defaultMinutes, ceiling))
        let given = min(asked, ceiling)
        return (TimeInterval(given * 60), asked > given)
    }
}

extension ResourceKind {
    /// Whether a name is one the Mac finds by itself — the screen, a simulator or a
    /// browser — and so cannot be declared.
    public static func isFoundName(_ name: ResourceName) -> Bool {
        name == .screen || name.key.hasPrefix("simulator:") || name.key.hasPrefix("browser:")
    }
}

/// One agent's right to one resource, until a time.
///
/// Only an agent ever holds one. The person can end a lease and take an agent out of
/// a line, but never takes one themselves (spec, Clarifications), so the holder is an
/// agent id and nothing else.
public struct Lease: Codable, Hashable, Sendable {
    public var resource: ResourceName
    /// What the resource is called where a person reads it. Carried on the lease so a
    /// note about one that has since been freed can still name it.
    public var displayName: String
    public var holder: UUID
    /// When this holder got it. Not moved by an extension: the page says "held since".
    public var grantedAt: Date
    public var expiresAt: Date
    /// Whether the warning before expiry has been left for the holder. Cleared by an
    /// extension, so a lease extended into a new warning window is warned again.
    public var warned: Bool

    public init(resource: ResourceName, displayName: String, holder: UUID,
                grantedAt: Date, expiresAt: Date, warned: Bool = false) {
        self.resource = resource
        self.displayName = displayName
        self.holder = holder
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.warned = warned
    }

    /// Inside the warning window and not yet expired.
    public func isEndingSoon(at now: Date) -> Bool {
        expiresAt > now && expiresAt.timeIntervalSince(now) <= LeaseLimits.warning
    }
}

/// An agent in line for a resource.
public struct Waiter: Codable, Hashable, Sendable {
    public var agentID: UUID
    /// The order of the line. First asked, first served (US2-AS5).
    public var askedAt: Date
    /// How long it asked for, applied when the lease reaches it.
    public var minutes: Int?
    /// Set while the agent's tool call is still open, waiting to be answered. Nil means
    /// the call has returned, and the agent has to be started again when its turn
    /// comes (FR-006). Always nil after a restart: no call survives one.
    public var waitID: UUID?

    public init(agentID: UUID, askedAt: Date, minutes: Int? = nil, waitID: UUID? = nil) {
        self.agentID = agentID
        self.askedAt = askedAt
        self.minutes = minutes
        self.waitID = waitID
    }

    public var isCallOpen: Bool { waitID != nil }
}

/// How a lease came to an end. Said in the holder's transcript (FR-016).
public enum LeaseEnding: String, Codable, Hashable, Sendable {
    case released
    case expired
    case endedByPerson
    case holderStopped
    case holderArchived
    /// It reached an agent that could not be started to use it, so it was passed on.
    case couldNotStart
}

/// Something an agent is told at the head of its next lease tool reply, rather than
/// interrupted with mid-turn (FR-012, US5-AS5).
public struct LeaseNotice: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case endedByPerson
        case expired
        case endingSoon(expiresAt: Date)
    }

    public var resource: ResourceName
    public var displayName: String
    public var kind: Kind
    public var at: Date

    public init(resource: ResourceName, displayName: String, kind: Kind, at: Date) {
        self.resource = resource
        self.displayName = displayName
        self.kind = kind
        self.at = at
    }
}

/// The numbers a lease runs by. Chosen in the spec rather than asked about, and
/// constants until someone wants them in Settings.
public enum LeaseLimits {
    /// What a lease lasts when nobody says.
    public static let defaultMinutes = 30
    /// The longest a lease may run without an extension.
    public static let maximumMinutes = 240
    /// How long before expiry the holder is warned.
    public static let warning: TimeInterval = 5 * 60
    /// How long a lease call may stay open waiting. Under the shortest runtime tool
    /// timeout there is — Codex's sixty seconds — so the call always comes back from
    /// us rather than failing on the runtime's side (research R3).
    public static let waitLimit: Duration = .seconds(45)
}
