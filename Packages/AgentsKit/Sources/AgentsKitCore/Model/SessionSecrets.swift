import Foundation

/// Secrets for this session only (#3548): set on the `ask_secret` card or in Settings ▸
/// Secrets for one session. Only that session's agent can use one, and its host deletes it
/// when the session is archived. `secrets/sessionList` gives them by name, never a value.
public struct SessionSecret: Codable, Sendable, Hashable, Identifiable {
    public var agentID: UUID
    /// The session's title, as the session list shows it.
    public var title: String
    public var name: String
    public var setAt: Date
    /// Ask before use (#4014): sealed in the session's file, never there as plain text.
    public var needsApproval: Bool?
    /// What it is for (#4167).
    public var description: String?
    /// When the name was first set for the session (#4158); a new value keeps it.
    public var created: Date?
    /// The value's last 4 (#4158); nil for a short value.
    public var hint: String?
    /// Its newest operation (#4158).
    public var lastOp: DaemonAPI.SecretLastOp?
    /// Always false (#4158): it is on this machine only.
    public var backedUp: Bool?

    public var id: String { "\(agentID.uuidString)/\(name)" }
    public var asksBeforeUse: Bool { needsApproval == true }

    public init(agentID: UUID, title: String, name: String, setAt: Date, needsApproval: Bool? = nil, description: String? = nil,
                created: Date? = nil, hint: String? = nil, lastOp: DaemonAPI.SecretLastOp? = nil, backedUp: Bool? = nil) {
        self.agentID = agentID
        self.title = title
        self.name = name
        self.setAt = setAt
        self.needsApproval = needsApproval
        self.description = description
        self.created = created
        self.hint = hint
        self.lastOp = lastOp
        self.backedUp = backedUp
    }
}

public struct SessionSecrets: Codable, Sendable, Hashable {
    public var secrets: [SessionSecret]

    public init(secrets: [SessionSecret] = []) {
        self.secrets = secrets
    }
}

/// secrets/sessionSet's request: the value is one line.
public struct SessionSecretSetRequest: Codable, Sendable, Hashable {
    public var agentID: UUID
    public var name: String
    public var value: String
    /// Ask before use (#4014); nil is off.
    public var needsApproval: Bool?
    /// What it is for (#4167); nil has none.
    public var description: String?

    public init(agentID: UUID, name: String, value: String, needsApproval: Bool? = nil, description: String? = nil) {
        self.agentID = agentID
        self.name = name
        self.value = value
        self.needsApproval = needsApproval
        self.description = description
    }
}

/// `secrets/setNeedsApproval` (#4014): a person turns Ask before use on or off for a secret of
/// the machine's sealed store, or for one session's (`agentID`). The person's own clients only.
public struct SecretNeedsApprovalRequest: Codable, Sendable, Hashable {
    public var name: String
    public var agentID: UUID?
    public var needsApproval: Bool

    public init(name: String, agentID: UUID? = nil, needsApproval: Bool) {
        self.name = name
        self.agentID = agentID
        self.needsApproval = needsApproval
    }
}

/// secrets/sessionRemove's request.
public struct SessionSecretRemoveRequest: Codable, Sendable, Hashable {
    public var agentID: UUID
    public var name: String

    public init(agentID: UUID, name: String) {
        self.agentID = agentID
        self.name = name
    }
}

/// The words of a secret for this session only, on the card and in Settings ▸ Secrets; the
/// web page's are the same, in `Web/src/model/sessionSecrets.ts`.
public enum SessionSecretWords {
    /// The card's checkbox, and the sheet's title.
    public static let toggle = "For this session only"
    public static let header = "For One Session"
    public static let footer = "Only that session's agent can use one, and it is deleted when the session is archived. "
        + "It stays on this machine and is not sent to your other machines."
    public static let none = "No secrets for one session."
    public static let add = "Add for a Session…"
    public static let sheetTitle = "Add a Secret for a Session"
    public static let session = "Session"
    public static let noSessions = "No session to add one for."
    public static let removeMessage = "Its agent is told it expired."

    /// Under the card's field, with the checkbox on.
    public static func keeping(on host: String) -> String {
        "Kept on \(host) for this session only, and deleted when it is archived. The agent gets its name, never the value."
    }

    public static func removeQuestion(_ secret: SessionSecret) -> String {
        "Remove \(secret.name) from “\(secret.title)”?"
    }
}
