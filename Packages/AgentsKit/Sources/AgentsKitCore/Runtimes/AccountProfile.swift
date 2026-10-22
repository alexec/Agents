import Foundation

/// An account added to a runtime (#840), beside the runtime's own sign-in, which is the
/// Default account and is not one of these. The person picks one when they start a
/// session; nothing switches to another by itself.
///
/// Today an account is a sign-in kept in a folder of its own (Claude's `CLAUDE_CONFIG_DIR`,
/// Codex's `CODEX_HOME`). `reach` is how it gets to the model, so an org key or a gateway
/// (T6, #999) can be another case of it.
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

    public init(id: String, runtimeID: String, name: String, reach: AccountReach, addedAt: Date = Date(),
                signedIn: Bool = false, signedInAs: String? = nil, signInCommand: String? = nil) {
        self.id = id
        self.runtimeID = runtimeID
        self.name = name
        self.reach = reach
        self.addedAt = addedAt
        self.signedIn = signedIn
        self.signedInAs = signedInAs
        self.signInCommand = signInCommand
    }

    /// The words under its name: who it is, or that it still needs signing in.
    public var state: String {
        guard signedIn else { return "Not signed in" }
        return signedInAs.map { "Signed in as \($0)" } ?? "Signed in"
    }

    /// The name the account picker gives the runtime's own sign-in.
    public static let defaultName = "Default account"
}

/// How an account reaches the model (#840): a sign-in in a folder of its own. An organisation's
/// route (#999: `orgKey`, `gateway`) and any way a newer host names is kept whole as `other`, so
/// the account list still decodes when a route reaches a machine before this client draws it.
public enum AccountReach: Codable, Hashable, Sendable {
    case signIn(folder: String)
    /// A way this build does not draw yet, as the host sent it: `{"orgKey": {"route": …}}`.
    case other(JSONValue)

    private enum Key: String, CodingKey { case signIn }
    private struct Folder: Codable { var folder: String }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        if case .object(let object) = value, let signIn = object[Key.signIn.rawValue],
           let folder = try? signIn.decode(Folder.self) {
            self = .signIn(folder: folder.folder)
        } else {
            self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .signIn(let folder):
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(Folder(folder: folder), forKey: .signIn)
        case .other(let value):
            try value.encode(to: encoder)
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
}

public extension Array where Element == AccountProfile {
    /// The accounts added to one runtime, in the order they were added.
    func on(_ runtimeID: String) -> [AccountProfile] {
        filter { $0.runtimeID == runtimeID }
    }
}
