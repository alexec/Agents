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
    /// Later (#4233): still open, and its sessions still wait, but out of Needs you, its
    /// counts and its notices until it comes back. Nil when it is not deferred.
    public var deferred: Deferral?

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

    /// The wire's `RequestDeferral` (#4233): it comes back at `until`, or when the person is
    /// next at the Mac, whichever is first.
    public struct Deferral: Codable, Sendable, Hashable {
        public var until: Date?
        public var atMac: Bool?
        /// When it was deferred.
        public var at: Date
        public var by: DaemonAPI.AuditActor?

        public init(until: Date? = nil, atMac: Bool? = nil, at: Date, by: DaemonAPI.AuditActor? = nil) {
            self.until = until
            self.atMac = atMac
            self.at = at
            self.by = by
        }

        /// When it comes back, as its row in Later says it: "Back at 18:00", "Back tomorrow at
        /// 09:00", "At my Mac", or both.
        public func back(now: Date = .now, calendar: Calendar = .current) -> String {
            let mac = atMac == true ? "at my Mac" : nil
            guard let until else { return "At my Mac" }
            let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar,
                                                        timeZone: calendar.timeZone))
            let day: String = if calendar.isDate(until, inSameDayAs: now) {
                "at \(time)"
            } else if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(until, inSameDayAs: next) {
                "tomorrow at \(time)"
            } else {
                "on " + until.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
                    .weekday(.abbreviated).day().month(.abbreviated)) + " at \(time)"
            }
            return (["Back \(day)"] + [mac].compactMap { $0 }).joined(separator: " or ")
        }
    }

    /// Later's choices (#4234), in the order its menu lists them: hours on from now (Alex,
    /// 2026-11-10: 1h, 4h, 8h, 1d), then At my Mac.
    public enum Later: String, CaseIterable, Sendable {
        case hour, fourHours, eightHours, day, atMac

        /// The timed ones, as the request's card has them.
        public static let timed: [Later] = [.hour, .fourHours, .eightHours, .day]

        /// The words on the row's menu.
        public var word: String {
            switch self {
            case .hour: "In 1 Hour"
            case .fourHours: "In 4 Hours"
            case .eightHours: "In 8 Hours"
            case .day: "In 1 Day"
            case .atMac: "At My Mac"
            }
        }

        /// The card's button: 1h, 4h, 8h, 1d.
        public var short: String {
            switch self {
            case .hour: "1h"
            case .fourHours: "4h"
            case .eightHours: "8h"
            case .day: "1d"
            case .atMac: "At my Mac"
            }
        }

        /// How long from now; nil for At my Mac, which waits for the person.
        public var hours: Int? {
            switch self {
            case .hour: 1
            case .fourHours: 4
            case .eightHours: 8
            case .day: 24
            case .atMac: nil
            }
        }

        /// When it comes back, from `now`.
        public func until(from now: Date = .now) -> Date? {
            hours.map { now.addingTimeInterval(TimeInterval($0) * 3600) }
        }

        /// What `requests/defer` takes for it.
        public func params(id: UUID, now: Date = .now) -> DaemonAPI.RequestsDefer {
            self == .atMac ? .init(id: id, atMac: true) : .init(id: id, until: until(from: now))
        }
    }

    /// Whether it is in Later (#4233).
    public var isDeferred: Bool { deferred != nil }

    /// As it will read once its host has put it in Later (#4786): drawn before the answer.
    public func deferring(_ params: DaemonAPI.RequestsDefer, at now: Date = .now) -> NeedRequest {
        var request = self
        request.deferred = Deferral(until: params.until, atMac: params.atMac, at: now)
        return request
    }

    /// As it will read once Bring Back has taken it out of Later (#4786).
    public var broughtBack: NeedRequest {
        var request = self
        request.deferred = nil
        return request
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
        secretUse.map(\.title) ?? title
    }

    /// A terminal's `agents-secret NAME` (#4179): a secret's use with no session.
    public var isTerminal: Bool { askedBy == nil && secretUse?.isTerminal == true }

    /// A use of a secret with Ask before use (#4015): its detail, when it is one.
    public var secretUse: SecretUse? {
        guard source == "secretUse", let use = try? detail["secretUse"]?.decode(SecretUse.self) else { return nil }
        return use
    }

    /// The wire's `RequestSecretUse`: the secret's name, never its value, and where agentsd
    /// puts the value.
    public struct SecretUse: Codable, Sendable, Hashable {
        /// fill (fill_secret), ci (set_ci_secret), mcp (an HTTP MCP server's header, #4120),
        /// terminal (`agents-secret NAME` with no session's grant, #4179), account (a
        /// manage_accounts read of an account with Ask before use, #4163), or browser and screen
        /// (an agent's lease of the browser or the screen on a machine that asks, #4264), or
        /// workflow and connector (an agent asks to turn on its folder's workflow or approve its
        /// folder's connector, #4538: `place` is then the folder's name).
        public var use: String
        public var name: String
        /// The page's domain for a fill, owner/repo for CI, the server's name for MCP, the
        /// command that ran agents-secret for a terminal, as it says it.
        public var place: String
        /// The session's own secret (#3548): Always Approve is the same as Approve for This Session.
        public var sessionOnly: Bool?
        /// A Linux machine (#4058): an answer that allows the use goes signed with this
        /// device's lock key (`LockChannel.secretUseApproval`), or the machine refuses it.
        public var needsSignature: Bool?
        /// For account (#4163): the manage_accounts call that waits, such as get. `name` is then
        /// the account's service and address, and `place` its id.
        public var call: String?
        /// For screen (#4264): the app drive_screen names. `name` is then "the screen", and
        /// `place` the machine.
        public var app: String?
        /// For connector (#4538): the server's entry digest when the agent asked. Approve
        /// approves only that entry.
        public var digest: String?

        public init(name: String, use: String, place: String, sessionOnly: Bool? = nil, needsSignature: Bool? = nil, call: String? = nil, app: String? = nil, digest: String? = nil) {
            self.name = name
            self.use = use
            self.place = place
            self.sessionOnly = sessionOnly
            self.needsSignature = needsSignature
            self.call = call
            self.app = app
            self.digest = digest
        }

        /// The row's title (#4017): the secret first, as its banner says it. A workflow or a
        /// connector (#4538) names the change the agent asks the person to make.
        public var title: String {
            switch use {
            case "workflow": "Wants to turn on \(name)"
            case "connector": "Wants to approve \(name)"
            case "account": "Wants to read \(name)"
            default: "Wants to use \(name)"
            }
        }

        /// Whether `action` goes signed: it allows the use, on a machine that asks for a signature.
        public func signs(_ action: Action) -> Bool {
            needsSignature == true && action != .deny
        }

        /// A terminal's (#4179): agentsd cannot tell its caller from an agent outside its session.
        public var isTerminal: Bool { use == "terminal" }

        /// Where the value goes, as the row's grey line says it. A terminal's says the known gap.
        public var `where`: String {
            switch use {
            case "ci": "CI secret in \(place)"
            case "mcp": "MCP server \(place)"
            case "terminal": "Terminal: \(place) · \(Self.terminalCaveat)"
            case "account": "Account: manage_accounts \(call ?? "get")"
            case "browser": "Browser on \(place)"
            case "screen": app.map { "Screen: \($0) on \(place)" } ?? "Screen on \(place)"
            case "workflow": "Workflow in \(place)"
            case "connector": "Connector in \(place)"
            default: "Fill on \(place)"
            }
        }

        /// The known gap (#4179), as agentsd's banner says it.
        public static let terminalCaveat = "Agents cannot tell a terminal from an agent outside its session."

        /// The answers a person can give, in the order the row and the banner show them. A
        /// terminal's are once, for 1 hour and deny (#4179).
        public var actions: [Action] {
            if isTerminal { return [.once, .hour, .deny] }
            // A workflow's or a connector's (#4538): the change is made once, by Approve.
            if use == "workflow" || use == "connector" { return [.once, .deny] }
            return sessionOnly == true ? [.once, .session, .deny] : [.once, .session, .always, .deny]
        }
    }

    /// The wire's `RequestSecretUseAnswer.action`.
    public enum Action: String, Codable, Sendable, CaseIterable {
        case once, session, always, hour, deny

        /// The words on the row's menu, its swipes and the banner's buttons.
        public var word: String {
            switch self {
            case .once: "Approve"
            case .session: "Approve for This Session"
            case .always: "Always Approve"
            case .hour: "Approve for 1 Hour"
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
    /// Later (#4233): out of Needs you, the counts and the notices until a time, or until
    /// the person is next at the Mac.
    static let requestsDefer = "requests/defer"
    /// Bring back now (#4233).
    static let requestsUndefer = "requests/undefer"
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

    /// `requests/defer`'s params (#4233): until, atMac or both; until is after now.
    struct RequestsDefer: Codable, Sendable, Hashable {
        public var id: UUID
        public var until: Date?
        public var atMac: Bool?

        public init(id: UUID, until: Date? = nil, atMac: Bool? = nil) {
            self.id = id
            self.until = until
            self.atMac = atMac
        }
    }

    /// `requests/undefer`'s params (#4233).
    struct RequestsUndefer: Codable, Sendable, Hashable {
        public var id: UUID
        public init(id: UUID) { self.id = id }
    }

    /// `requests/changed`'s params, and what `requests/answer` and `requests/drop` answer.
    struct RequestUpdate: Codable, Sendable, Hashable {
        public var request: NeedRequest
    }
}
