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

    /// The row's symbol for its kind (#4026): each kind its own, so it says what is asked. A
    /// step's hand taps, because a raised hand is a session that needs the person.
    public var symbol: String {
        switch kind {
        case .decide: "questionmark.bubble"
        case .approve: "checkmark.shield"
        case .account: "person.badge.plus"
        case .step: "hand.tap"
        case .secret: "key"
        }
    }

    /// The grey line after the kind: the asker, and how many it blocks when more than one. A
    /// secret's use (#4017) says the asker and where the value goes: its title says what is asked.
    public func line(asker: String?) -> String {
        let parts: [String?] = secretUse.map { [asker, $0.where] } ?? [kindWord, asker]
        return (parts + [blocks > 1 ? "blocks \(blocks) sessions" : nil])
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The row's title: what is asked. A secret's use (#4017) names the secret first, as its
    /// banner does, so a narrow sidebar cuts the place and not the name.
    public func title(asker: String?) -> String {
        secretUse.map { "Wants to use \($0.name)" } ?? title
    }

    /// A use of a secret with Ask before use (#4015): its detail, when it is one.
    public var secretUse: SecretUse? {
        guard source == "secretUse", let use = try? detail["secretUse"]?.decode(SecretUse.self) else { return nil }
        return use
    }

    /// The wire's `RequestSecretUse`: the secret's name, never its value, and where agentsd
    /// puts the value.
    public struct SecretUse: Codable, Sendable, Hashable {
        /// fill (fill_secret), ci (set_ci_secret) or mcp (an HTTP MCP server's header, #4120).
        public var use: String
        public var name: String
        /// The page's domain for a fill, owner/repo for CI, the server's name for MCP.
        public var place: String
        /// The session's own secret (#3548): Allow always is the same as Allow for this session.
        public var sessionOnly: Bool?
        /// A Linux machine (#4058): an answer that allows the use goes signed with this
        /// device's lock key (`LockChannel.secretUseApproval`), or the machine refuses it.
        public var needsSignature: Bool?

        public init(name: String, use: String, place: String, sessionOnly: Bool? = nil, needsSignature: Bool? = nil) {
            self.name = name
            self.use = use
            self.place = place
            self.sessionOnly = sessionOnly
            self.needsSignature = needsSignature
        }

        /// Whether `action` goes signed: it allows the use, on a machine that asks for a signature.
        public func signs(_ action: Action) -> Bool {
            needsSignature == true && action != .deny
        }

        /// Where the value goes, as the row's grey line says it.
        public var `where`: String {
            switch use {
            case "ci": "CI secret in \(place)"
            case "mcp": "MCP server \(place)"
            default: "Fill on \(place)"
            }
        }

        /// The answers a person can give, in the order the row and the banner show them.
        public var actions: [Action] {
            sessionOnly == true ? [.once, .session, .deny] : Action.allCases
        }
    }

    /// The wire's `RequestSecretUseAnswer.action`.
    public enum Action: String, Codable, Sendable, CaseIterable {
        case once, session, always, deny

        /// The words on the row's menu, its swipes and the banner's buttons.
        public var word: String {
            switch self {
            case .once: "Allow Once"
            case .session: "Allow for This Session"
            case .always: "Allow Always"
            case .deny: "Deny"
            }
        }
    }
}

public extension DaemonAPI.Method {
    /// The open requests to a person (#3863), every folder's.
    static let requestsList = "requests/list"
    /// A person's answer to a request (#3863): today the clients send only a secret's use (#4017).
    static let requestsAnswer = "requests/answer"
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

    /// `requests/answer`'s params: the answer to a secret's use (#4017).
    struct RequestsAnswer: Codable, Sendable, Hashable {
        public struct Answer: Codable, Sendable, Hashable {
            public struct SecretUse: Codable, Sendable, Hashable {
                public var action: NeedRequest.Action
                /// The answer signed with this device's lock key, for a request that says
                /// needsSignature (#4058).
                public var approval: LockDelivery?
            }

            public var secretUse: SecretUse?
        }

        public var id: UUID
        public var answer: Answer

        public init(id: UUID, secretUse action: NeedRequest.Action, approval: LockDelivery? = nil) {
            self.id = id
            answer = Answer(secretUse: .init(action: action, approval: approval))
        }
    }

    /// `requests/changed`'s params, and what `requests/answer` and `requests/drop` answer.
    struct RequestUpdate: Codable, Sendable, Hashable {
        public var request: NeedRequest
    }
}
