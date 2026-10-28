import Foundation

/// An account added to a runtime (#840), beside the runtime's own sign-in, which is the
/// Default account and is not one of these. The person picks one when they start a
/// session; nothing switches to another by itself.
///
/// An account is a sign-in kept in a folder of its own (Claude's `CLAUDE_CONFIG_DIR`, Codex's
/// `CODEX_HOME`), or (#999) an organisation's route: an org key or a gateway, which the
/// machine's model relay reaches the model by. `reach` says which.
public struct AccountProfile: Codable, Hashable, Sendable, Identifiable {
    /// The host's own name for it. An agent keeps it as `accountID`.
    public var id: String
    public var runtimeID: String
    /// What the person called it, such as Work.
    public var name: String
    public var reach: AccountReach
    public var addedAt: Date
    /// Whether its folder holds a sign-in, as the host read it when it answered.
    public var signedIn: Bool
    /// Who it is signed in as, such as an email address, when the runtime's files say.
    public var signedInAs: String?
    /// The command that signs it in, in a terminal on the host, for a runtime the app
    /// cannot sign in itself (Claude). Nil for one that signs in with `runtimes/authenticate`.
    public var signInCommand: String?
    /// Who gave it (#999): nil or `person` for one the person added, `organisation` for an org
    /// route, which only the organisation can remove.
    public var source: String?
    /// The runtime's account for new sessions, **Reaches the Model By** (#999). When no account
    /// says so, the runtime's own sign-in is.
    public var isDefault: Bool?
    /// The organisation's policy refuses this account (#999, `runtimes.<id>.reach`).
    public var setBy: DaemonAPI.PolicySetBy?

    public init(id: String, runtimeID: String, name: String, reach: AccountReach, addedAt: Date = Date(),
                signedIn: Bool = false, signedInAs: String? = nil, signInCommand: String? = nil,
                source: String? = nil, isDefault: Bool? = nil, setBy: DaemonAPI.PolicySetBy? = nil) {
        self.id = id
        self.runtimeID = runtimeID
        self.name = name
        self.reach = reach
        self.addedAt = addedAt
        self.signedIn = signedIn
        self.signedInAs = signedInAs
        self.signInCommand = signInCommand
        self.source = source
        self.isDefault = isDefault
        self.setBy = setBy
    }

    /// An organisation's route (#999), not an account the person added.
    public var isOrganisation: Bool {
        if source == "organisation" { return true }
        switch reach {
        case .orgKey, .gateway: return true
        case .signIn, .other: return false
        }
    }

    /// The words under its name: **From your organisation** for an org account (spec FR-023),
    /// else who it is, or that it still needs signing in.
    public var state: String {
        if isOrganisation { return OrgAccountWords.fromOrganisation }
        guard signedIn else { return "Not signed in" }
        return signedInAs.map { "Signed in as \($0)" } ?? "Signed in"
    }

    /// The name the account picker gives the runtime's own sign-in: "Your Own Sign-In" (#999).
    public static let defaultName = OrgAccountWords.ownSignIn
}

/// How an account reaches the model (#840): a sign-in in a folder of its own, or (#999) an
/// organisation's route: an org key of the runtime's own vendor, or a gateway. Any way a newer
/// host names is kept whole as `other`, so the account list still decodes.
public enum AccountReach: Codable, Hashable, Sendable {
    case signIn(folder: String)
    /// An org key: the route's id.
    case orgKey(route: String)
    /// A gateway: the route's id and its kind (`bedrock`, `vertex`, `azure`, `baseURL`).
    case gateway(route: String, kind: String)
    /// A way this build does not know, as the host sent it.
    case other(JSONValue)

    private enum Key: String, CodingKey { case signIn, orgKey, gateway }
    private struct Folder: Codable { var folder: String }
    private struct Route: Codable { var route: String; var kind: String? }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let object) = value else {
            self = .other(value)
            return
        }
        if let signIn = object[Key.signIn.rawValue], let folder = try? signIn.decode(Folder.self) {
            self = .signIn(folder: folder.folder)
        } else if let key = object[Key.orgKey.rawValue], let route = try? key.decode(Route.self) {
            self = .orgKey(route: route.route)
        } else if let gateway = object[Key.gateway.rawValue], let route = try? gateway.decode(Route.self),
                  let kind = route.kind {
            self = .gateway(route: route.route, kind: kind)
        } else {
            self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .other(let value) = self {
            try value.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .signIn(let folder):
            try container.encode(Folder(folder: folder), forKey: .signIn)
        case .orgKey(let route):
            try container.encode(Route(route: route), forKey: .orgKey)
        case .gateway(let route, let kind):
            try container.encode(Route(route: route, kind: kind), forKey: .gateway)
        case .other:
            break
        }
    }

    /// The org route's id, for an org key or a gateway.
    public var route: String? {
        switch self {
        case .orgKey(let route), .gateway(let route, _): route
        case .signIn, .other: nil
        }
    }
}

public extension DaemonAPI {
    struct AddAccountRequest: Codable, Sendable {
        public var runtimeID: String
        public var name: String
        public init(runtimeID: String, name: String) {
            self.runtimeID = runtimeID
            self.name = name
        }
    }

    struct AccountRequest: Codable, Sendable {
        public var runtimeID: String
        public var accountID: String
        public init(runtimeID: String, accountID: String) {
            self.runtimeID = runtimeID
            self.accountID = accountID
        }
    }

    /// `runtimes/setDefaultAccount` (#999): a runtime's account for new sessions, **Reaches
    /// the Model By**. `default` (or nil) is the runtime's own sign-in.
    struct DefaultAccountRequest: Codable, Sendable {
        public var runtimeID: String
        public var accountID: String?
        public init(runtimeID: String, accountID: String?) {
            self.runtimeID = runtimeID
            self.accountID = accountID
        }
    }

    /// `agents/continueInNew` (#999): **Continue in New**, a session in the same folder that
    /// reads this one and carries on, on `accountID`, else the runtime's account for new
    /// sessions. Answered with the new agent's id.
    struct ContinueInNewRequest: Codable, Sendable {
        public var agentID: UUID
        public var accountID: String?
        /// As `StartRequest.requestID`: a retry answers with the first try's agent.
        public var requestID: UUID?
        /// Continue on Auto (#2658, FR-022): the successor starts where Auto would start one
        /// now, with the session's values. Only for an Auto session.
        public var auto: Bool?
        public init(agentID: UUID, accountID: String? = nil, requestID: UUID? = nil, auto: Bool? = nil) {
            self.agentID = agentID
            self.accountID = accountID
            self.requestID = requestID
            self.auto = auto
        }
    }
}

public extension DaemonAPI.Method {
    /// `DefaultAccountRequest` → `Empty` (#999).
    static let runtimesSetDefaultAccount = "runtimes/setDefaultAccount"
    /// `ContinueInNewRequest` → the new agent's id (#999).
    static let agentsContinueInNew = "agents/continueInNew"
}

/// The id `runtimes/setDefaultAccount` names a runtime's own sign-in by (#999).
public extension AccountProfile {
    static let ownSignInID = "default"
}

public extension Array where Element == AccountProfile {
    /// The accounts of one runtime: the ones added, in the order they were added, then the
    /// organisation's (#999).
    func on(_ runtimeID: String) -> [AccountProfile] {
        filter { $0.runtimeID == runtimeID }
    }

    /// The name of the account a session runs on (#2259): nil for the runtime's own sign-in,
    /// or for an account this list does not hold.
    func name(of accountID: String?, on runtimeID: String) -> String? {
        guard let accountID, accountID != AccountProfile.ownSignInID else { return nil }
        return first { $0.id == accountID && $0.runtimeID == runtimeID }?.name
    }

    /// The ones the person added to one runtime (#840): not the organisation's.
    func added(to runtimeID: String) -> [AccountProfile] {
        filter { $0.runtimeID == runtimeID && !$0.isOrganisation }
    }

    /// The organisation's accounts of one runtime (#999).
    func organisation(_ runtimeID: String) -> [AccountProfile] {
        filter { $0.runtimeID == runtimeID && $0.isOrganisation }
    }

    /// The runtime's account for new sessions, **Reaches the Model By** (#999): nil for its
    /// own sign-in.
    func defaultAccount(_ runtimeID: String) -> AccountProfile? {
        first { $0.runtimeID == runtimeID && $0.isDefault == true }
    }
}
