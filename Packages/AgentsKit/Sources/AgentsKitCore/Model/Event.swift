import Foundation

/// Where an event is in the log. Only ever goes up, and is never given out twice, so an
/// agent can say "anything after this one" and mean exactly that (042 R6).
public typealias EventPosition = Int64

/// Whose an event is: this Mac's, or one project's.
///
/// An agent sees the Mac's events and its own project's, and nothing else (042 FR-015).
/// The folder is kept standardised the way every other folder in the app is, so two
/// spellings of one project are one scope.
public enum EventScope: Codable, Hashable, Sendable {
    case mac
    case project(URL)

    public static func project(folder: URL) -> EventScope { .project(Project.standardize(folder)) }

    public var folder: URL? {
        if case .project(let folder) = self { return folder }
        return nil
    }
}

/// The agent that published a `custom.*` event, as it was called when it did.
public struct EventPublisher: Codable, Hashable, Sendable {
    public var agentID: UUID
    public var title: String

    public init(agentID: UUID, title: String) {
        self.agentID = agentID
        self.title = title
    }
}

/// What the app did because of an event (042 FR-027).
///
/// Titles are copied at the time, so a consequence still reads rightly after its agent
/// has been archived or renamed. Each carries what it needs to lead to its agent or
/// workflow.
public enum Consequence: Codable, Hashable, Sendable {
    case woke(agentID: UUID, title: String)
    case fired(workflowID: String, folder: URL, agentID: UUID?)
    case refused(workflowID: String, folder: URL, reason: WorkflowRefusal)
    case couldNotWake(agentID: UUID, title: String, reason: String)
}

/// A named, recorded fact that something happened (042).
///
/// Workflows trigger on these, agents wait on them, and the person reads them. Nothing
/// in here is transcript text, file contents or a credential (FR-004): the sentence and
/// the details are made from titles, numbers and branch names the phone already has.
public struct Event: Codable, Hashable, Sendable, Identifiable {
    public var position: EventPosition
    /// `subject.what_happened`, lowercase and dotted (FR-002).
    public var name: String
    /// When it happened, or, for a change the app missed while it was not running, when
    /// it was noticed.
    public var at: Date
    /// Set once repeats have been folded into it (FR-031).
    public var lastAt: Date?
    public var count: Int
    public var scope: EventScope
    /// What happened, in plain words, written when it was raised.
    public var sentence: String
    /// The kind's details. An agent is named by id under `agent`, with `agent_title`
    /// beside it for reading.
    public var details: [String: String]
    public var publisher: EventPublisher?
    public var message: String?
    /// How deep in a workflow chain anything fired from this event would be (008 FR-021).
    public var chainDepth: Int
    public var consequences: [Consequence]

    public var id: EventPosition { position }

    public init(position: EventPosition, name: String, at: Date, lastAt: Date? = nil, count: Int = 1,
                scope: EventScope, sentence: String, details: [String: String] = [:],
                publisher: EventPublisher? = nil, message: String? = nil, chainDepth: Int = 0,
                consequences: [Consequence] = []) {
        self.position = position
        self.name = name
        self.at = at
        self.lastAt = lastAt
        self.count = count
        self.scope = scope
        self.sentence = sentence
        self.details = details
        self.publisher = publisher
        self.message = message
        self.chainDepth = chainDepth
        self.consequences = consequences
    }

    public init(_ draft: EventDraft, position: EventPosition) {
        self.init(position: position, name: draft.name, at: draft.at, scope: draft.scope,
                  sentence: draft.sentence, details: draft.details, publisher: draft.publisher,
                  message: draft.message, chainDepth: draft.chainDepth)
    }

    public var subject: EventSubject? { EventSubject(name: name) }

    /// When it last happened: the last repeat, or the first time.
    public var latest: Date { lastAt ?? at }
}

/// What a source hands to `raise`: an event before the log has given it a place.
public struct EventDraft: Codable, Hashable, Sendable {
    public var name: String
    public var at: Date
    public var scope: EventScope
    public var sentence: String
    public var details: [String: String]
    public var publisher: EventPublisher?
    public var message: String?
    public var chainDepth: Int

    public init(name: String, at: Date = Date(), scope: EventScope, sentence: String,
                details: [String: String] = [:], publisher: EventPublisher? = nil,
                message: String? = nil, chainDepth: Int = 0) {
        self.name = name
        self.at = at
        self.scope = scope
        self.sentence = sentence
        self.details = details
        self.publisher = publisher
        self.message = message
        self.chainDepth = chainDepth
    }

    // MARK: Limits (042 data-model)

    public static let maximumDetails = 10
    public static let maximumDetailLength = 200
    public static let maximumMessageLength = 500

    /// Whether the name has the shape every event name has.
    public static func isWellFormed(_ name: String) -> Bool {
        name.range(of: #"^[a-z][a-z_]*\.[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Why this draft cannot be recorded, in the words an agent reads. `nil` when it can.
    public var problem: String? {
        guard Self.isWellFormed(name) else {
            return "\"\(name)\" is not an event name: it is lowercase words joined by a dot, like custom.build_green."
        }
        if details.count > Self.maximumDetails {
            return "An event carries at most \(Self.maximumDetails) details; this one has \(details.count)."
        }
        if let long = details.first(where: { $0.value.count > Self.maximumDetailLength }) {
            return "The detail \"\(long.key)\" is longer than \(Self.maximumDetailLength) characters."
        }
        if let message, message.count > Self.maximumMessageLength {
            return "The message is longer than \(Self.maximumMessageLength) characters."
        }
        return nil
    }
}
