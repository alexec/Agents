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

    public static let policyStillBlocks = "Your organisation's Policy still blocks it if no marketplace it allows has it."

    /// A person's line for their own request, by its state. An approval does not add it, nor
    /// change what the Policy's marketplaces allow (#2434): the line says how to add it and,
    /// when the Policy names marketplaces, that they still decide.
    public static func mine(_ request: DaemonAPI.CatalogRequest, marketplacesLimited: Bool = false) -> String {
        let item = item(request.kind, request.name)
        let first = item.prefix(1).uppercased() + item.dropFirst()
        switch request.state {
        case .approved:
            let add = request.kind == .skills ? "Add it as you add any skill." : "Add it as you add any MCP server."
            return "\(first): approved for \(request.groupName ?? "you"). \(add)" + (marketplacesLimited ? " \(policyStillBlocks)" : "")
        case .refused: return "\(first): refused"
        case .waiting: return "\(first): waiting for an admin"
        }
    }

    /// The person's own requests: an admin's list also has everyone's waiting ones.
    public static func own(_ requests: [DaemonAPI.CatalogRequest], user: String?, isAdmin: Bool) -> [DaemonAPI.CatalogRequest] {
        isAdmin ? requests.filter { $0.user == user } : requests
    }

    // MARK: Ask an Admin on a catalogue sheet (#2355)

    /// The button under a catalogue sheet's policy refusal.
    public static let askAdmin = "Ask an Admin…"
    public static let askAdminHelp = "Ask your organisation's admins to approve it. They decide on Console ▸ Requests."

    /// The popover's title: "Ask for the MCP server github".
    public static func askFor(_ kind: DaemonAPI.CatalogKind, _ name: String) -> String {
        "Ask for \(item(kind, name))"
    }

    /// Whether a catalogue refusal's words are the organisation's policy: the machine says them after
    /// **Set by your organisation** (`PolicyRefusal.line`, the daemon's `orgSetBy`), and a sheet then
    /// offers Ask an Admin.
    public static func refusedByPolicy(_ words: String) -> Bool {
        words.hasPrefix(OrgPolicyWords.setBy)
    }

    /// The person's own request for this item, if they asked already: the sheet says where it stands
    /// rather than offering Ask again. Names are matched as the control plane matches them, case aside.
    public static func asked(_ requests: [DaemonAPI.CatalogRequest], kind: DaemonAPI.CatalogKind,
                             name: String) -> DaemonAPI.CatalogRequest? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return requests.last { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The ask to send, or nil while the name is empty. A why of spaces only is no why.
    public static func request(kind: DaemonAPI.CatalogKind, name: String, why: String,
                               source: String? = nil) -> DaemonAPI.CatalogAsk? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = why.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return DaemonAPI.CatalogAsk(kind: kind, name: name, source: source, why: why.isEmpty ? nil : why)
    }
}

public extension DaemonAPI.CatalogError {
    /// The organisation's words when its policy refused this (#2355), or nil.
    var policyWords: String? {
        if case .failed(let why) = self, GovernanceWords.refusedByPolicy(why) { return why }
        return nil
    }
}

public extension DaemonAPI.MCPCatalogError {
    /// The organisation's words when its policy refused this (#2355), or nil.
    var policyWords: String? {
        if case .failed(let why) = self, GovernanceWords.refusedByPolicy(why) { return why }
        return nil
    }
}
