import Foundation

// Catalogue governance (#2019, M5; #2335): a person asks for an MCP server or skill in Settings ▸
// Policy, and sees their own requests of the last 30 days. Console ▸ Requests and Console ▸
// Catalogue, where an admin decides, are the web page's only (#1804), so only the ask is here.

public extension DaemonAPI {
    /// Where a request stands.
    enum CatalogRequestState: String, Codable, Sendable, Hashable {
        case waiting
        case approved
        case refused
    }

    /// `governance/request`: a person asks for an MCP server or skill, with why.
    struct CatalogAsk: Codable, Sendable, Hashable {
        public var kind: CatalogKind
        public var name: String
        public var source: String?
        public var why: String?

        public init(kind: CatalogKind, name: String, source: String? = nil, why: String? = nil) {
            self.kind = kind
            self.name = name
            self.source = source
            self.why = why
        }
    }

    /// A request for an MCP server or skill. Approved for a group, it is approved at once for every
    /// member who asks again.
    struct CatalogRequest: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var kind: CatalogKind
        public var name: String
        public var source: String?
        public var why: String?
        public var user: String
        public var userName: String
        public var at: Date
        public var state: CatalogRequestState
        public var group: String?
        public var groupName: String?
        public var decidedBy: String?
        public var decidedAt: Date?

        public init(id: String, kind: CatalogKind, name: String, source: String? = nil, why: String? = nil,
                    user: String, userName: String, at: Date, state: CatalogRequestState = .waiting,
                    group: String? = nil, groupName: String? = nil, decidedBy: String? = nil, decidedAt: Date? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.source = source
            self.why = why
            self.user = user
            self.userName = userName
            self.at = at
            self.state = state
            self.group = group
            self.groupName = groupName
            self.decidedBy = decidedBy
            self.decidedAt = decidedAt
        }
    }

    /// `governance/requests`: every waiting request to an admin, and to anyone their own of the last
    /// 30 days, oldest first.
    struct CatalogRequestList: Codable, Sendable, Hashable {
        public var requests: [CatalogRequest]

        public init(requests: [CatalogRequest]) {
            self.requests = requests
        }
    }
}

public extension DaemonAPI.Method {
    /// `CatalogAsk` → `CatalogRequest`: any person's (#2019).
    static let governanceRequest = "governance/request"
    /// `Empty` → `CatalogRequestList`: any person's own, and an admin's waiting ones (#2019).
    static let governanceRequests = "governance/requests"
}

public extension DaemonAPI.Notification {
    /// `CatalogRequest`: a request was made or decided (#2019).
    static let controlGovernanceRequested = "control/governanceRequested"
}

/// The words of the ask in Settings ▸ Policy, the same as `Web/src/model/governance.ts`.
public enum GovernanceWords {
    public static let askTitle = "Ask for an MCP Server or Skill"
    public static let askFoot = "An admin approves it for you or for a group of yours. Once a group has it approved, each of its members has it approved at once."
    public static let ask = "Ask"
    public static let namePrompt = "github"
    public static let whyPrompt = "To review pull requests"

    public static func kindName(_ kind: DaemonAPI.CatalogKind) -> String {
        kind == .skills ? "Skill" : "MCP server"
    }

    /// "the MCP server github" or "the skill review".
    public static func item(_ kind: DaemonAPI.CatalogKind, _ name: String) -> String {
        kind == .skills ? "the skill \(name)" : "the MCP server \(name)"
    }

    /// A person's line for their own request, by its state.
    public static func mine(_ request: DaemonAPI.CatalogRequest) -> String {
        let item = item(request.kind, request.name)
        let first = item.prefix(1).uppercased() + item.dropFirst()
        switch request.state {
        case .approved: return request.groupName.map { "\(first): approved for \($0)" } ?? "\(first): approved for you"
        case .refused: return "\(first): refused"
        case .waiting: return "\(first): waiting for an admin"
        }
    }

    /// The person's own requests: an admin's list also has everyone's waiting ones.
    public static func own(_ requests: [DaemonAPI.CatalogRequest], user: String?, isAdmin: Bool) -> [DaemonAPI.CatalogRequest] {
        isAdmin ? requests.filter { $0.user == user } : requests
    }

    /// The ask to send, or nil while the name is empty. A why of spaces only is no why.
    public static func request(kind: DaemonAPI.CatalogKind, name: String, why: String) -> DaemonAPI.CatalogAsk? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = why.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return DaemonAPI.CatalogAsk(kind: kind, name: name, why: why.isEmpty ? nil : why)
    }
}
