import Foundation

/// Something an agent asked the person for (#3862, spec 3862 §1): a question, a secret or a
/// step, kept by the daemon in a file of its own. Needs You lists each open one as a row
/// (#3864): what is asked, who asked it, how long it has waited and how many sessions it
/// blocks. Its asker's session row is not listed there too; the request's row stands for it.
/// The wire's `Request`.
public struct NeedRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case decide, approve, account, step, secret }
    public enum State: String, Codable, Sendable { case open, answered, dropped }

    public struct Waiter: Codable, Sendable, Hashable {
        public var agent: UUID
        public var since: Date

        public init(agent: UUID, since: Date) {
            self.agent = agent
            self.since = since
        }
    }

    /// For an app request, the same id as its `ElicitationRequest`.
    public var id: UUID
    public var kind: Kind
    /// question, secret, handOff, permission, guardedChange or forge. A string, so a source
    /// a later daemon adds still reads.
    public var source: String
    public var state: State
    /// One line, for the row.
    public var title: String
    /// The part that depends on the source, kept as it came.
    public var detail: JSONValue
    public var folder: URL
    /// The session that asked.
    public var askedBy: UUID?
    /// Every session that waits on it; the asker first.
    public var waiters: [Waiter]
    public var askedAt: Date
    public var answeredAt: Date?
    public var answeredBy: JSONValue?
    /// A summary for the row; never a secret's value.
    public var answer: String?
    public var droppedWhy: String?

    public init(id: UUID, kind: Kind, source: String, state: State = .open, title: String,
                detail: JSONValue = .object([:]), folder: URL, askedBy: UUID?, waiters: [Waiter] = [],
                askedAt: Date) {
        self.id = id
        self.kind = kind
        self.source = source
        self.state = state
        self.title = title
        self.detail = detail
        self.folder = folder
        self.askedBy = askedBy
        self.waiters = waiters
        self.askedAt = askedAt
    }

    /// How many sessions wait on it: at least its asker.
    public var blocks: Int { max(waiters.count, askedBy == nil ? 0 : 1) }

    /// What the person must do, as the row's grey line starts.
    public var kindWord: String {
        switch kind {
        case .decide: "Question"
        case .approve: "Approval"
        case .account: "Account"
        case .step: "Step for you"
        case .secret: "Secret"
        }
    }

    /// The row's symbol for its kind.
    public var symbol: String {
        switch kind {
        case .decide: "questionmark.bubble"
        case .approve: "checkmark.shield"
        case .account: "person.badge.plus"
        case .step: "hand.raised"
        case .secret: "key"
        }
    }

    /// The grey line after the kind: the asker, and how many it blocks when more than one.
    public func line(asker: String?) -> String {
        [kindWord, asker, blocks > 1 ? "blocks \(blocks) sessions" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

public extension DaemonAPI.Method {
    /// The open requests to a person (#3863), every folder's.
    static let requestsList = "requests/list"
}

public extension DaemonAPI.Notification {
    /// A request opened, ended, or its waiters changed (#3863).
    static let requestsChanged = "requests/changed"
}

public extension DaemonAPI {
    struct RequestsListRequest: Codable, Sendable, Hashable {
        /// open (the default), ended or all.
        public var state: String?
        public var folder: String?

        public init(state: String? = nil, folder: String? = nil) {
            self.state = state
            self.folder = folder
        }
    }

    struct RequestsListResult: Codable, Sendable, Hashable {
        public var requests: [NeedRequest]
    }

    /// `requests/changed`'s params, and what `requests/answer` and `requests/drop` answer.
    struct RequestUpdate: Codable, Sendable, Hashable {
        public var request: NeedRequest
    }
}
