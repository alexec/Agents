import Foundation

/// One thing in a folder waiting for the person's approval (#773), as its host lists it on
/// the folder's summary: a folder MCP server, a workflow, a plugin, a guarded `.agents`
/// file, or a session asking to be archived; and a workflow that failed (#989), waiting for
/// the person to fix it or dismiss it. Every client draws the one list in Needs You, the
/// same way for every kind, rather than each gathering it from six places.
///
/// The host says which answers each takes (`actions`), so a client offers what the host
/// would do and nothing else.
public struct Approval: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case mcpServer, workflow, plugin, file, archive
        /// A workflow that has stopped working (#989): `WorkflowFailure`. Its key is the
        /// workflow's id and its digest the failure's key.
        case workflowFailed
    }

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// Approve; for a guarded file, Keep; for an archive request, archive it.
        case approve
        /// It stays off and leaves the list until it changes again; for a guarded file,
        /// Undo; for an archive request, keep the session.
        case deny
        /// A note sent back to the agent that made the change. Only where one did.
        case requestChanges
        /// Out of Needs You until it fails again: a failed workflow's only answer (#989).
        case dismiss
    }

    public var kind: Kind
    /// What it is within its folder and kind: the server's name, the workflow's id, the
    /// plugin's folder name, the file's path, or the session's id.
    public var key: String
    /// Its name, as the row says it.
    public var title: String
    /// The version being approved; an answer to another version is refused. Nil for an
    /// archive request and a removed file.
    public var digest: String?
    /// What changed, in one grey line: "New with the last pull", "Changed since you approved it".
    public var line: String
    /// When it began waiting, where that is known.
    public var since: Date?
    public var actions: [Action]
    /// The agent Request changes goes to, or the session asking to be archived.
    public var agentID: UUID?

    public var id: String { "\(kind.rawValue):\(key)" }

    public init(kind: Kind, key: String, title: String, digest: String?, line: String, since: Date? = nil,
                actions: [Action], agentID: UUID? = nil) {
        self.kind = kind
        self.key = key
        self.title = title
        self.digest = digest
        self.line = line
        self.since = since
        self.actions = actions
        self.agentID = agentID
    }

    /// The kind in a person's words, as a row's label leads with it.
    public var kindWord: String {
        switch kind {
        case .mcpServer: "Connector"
        case .workflow: "Workflow"
        case .plugin: "Plugin"
        case .file: "File"
        case .archive: "Archive"
        case .workflowFailed: "Workflow"
        }
    }

    /// Each action's button, for this kind.
    public func word(for action: Action) -> String {
        switch (action, kind) {
        case (.approve, .file): "Keep"
        case (.approve, .archive): "Archive"
        case (.approve, _): "Approve"
        case (.deny, .file): "Undo"
        case (.deny, .archive): "Keep Session"
        case (.deny, _): "Deny"
        case (.requestChanges, _): "Request Changes"
        case (.dismiss, _): "Dismiss"
        }
    }

    /// What Approve and Deny do, under the buttons.
    public var explanation: String {
        switch kind {
        case .mcpServer:
            "No session here is given this server until you approve it. Deny leaves it off until its entry in "
                + ".agents/mcp.json changes again."
        case .workflow:
            "The workflow does not run until you approve it. Deny leaves it off on this machine until its file "
                + "changes again."
        case .plugin:
            "Nothing from this plugin reaches a session until you approve it. Deny leaves it out until its folder "
                + "changes again."
        case .file:
            "The app goes on using the copy you last approved until you choose. Keep uses the change from now "
                + "on; Undo puts the approved copy back in the file."
        case .archive:
            "The session asked to be archived. Keep Session takes the request away and leaves it where it is."
        case .workflowFailed:
            "The workflow has stopped working. It leaves Needs You when the cause is gone; Dismiss takes it out "
                + "until it fails again."
        }
    }

    /// Whether it has lines to read before an answer, which its Review page shows (#1472):
    /// a file's diff, a workflow's, a connector's entry or a plugin's files.
    public var hasReview: Bool {
        switch kind {
        case .mcpServer, .workflow, .plugin, .file: true
        case .archive, .workflowFailed: false
        }
    }

    /// Whether a session's own row draws it: an archive request is the session's row, with
    /// its mark, and not a row of its own.
    public var isSession: Bool { kind == .archive }

    /// Whether choosing the row reads something before an answer (#773), or opens what it
    /// is about: a failed workflow opens the run's agent, or the workflow (#989).
    public var opensItsSubject: Bool { kind == .workflowFailed }
}

/// Approve, Deny or Request changes, for one waiting item (#773).
public struct ApprovalAnswer: Codable, Sendable {
    public var folder: URL
    public var kind: Approval.Kind
    public var key: String
    /// The version shown; nil for an archive request and a removed file.
    public var digest: String?
    public var action: Approval.Action
    /// What Request changes sends to the agent.
    public var note: String?

    public init(folder: URL, kind: Approval.Kind, key: String, digest: String?, action: Approval.Action,
                note: String? = nil) {
        self.folder = folder
        self.kind = kind
        self.key = key
        self.digest = digest
        self.action = action
        self.note = note
    }

    public init(_ approval: Approval, in folder: URL, action: Approval.Action, note: String? = nil) {
        self.init(folder: folder, kind: approval.kind, key: approval.key, digest: approval.digest,
                  action: action, note: note)
    }
}

/// One waiting item to read before choosing (#773).
public struct ApprovalReadRequest: Codable, Sendable {
    public var folder: URL
    public var kind: Approval.Kind
    public var key: String

    public init(folder: URL, kind: Approval.Kind, key: String) {
        self.folder = folder
        self.kind = kind
        self.key = key
    }
}

extension Approval {
    enum CodingKeys: String, CodingKey { case kind, key, title, digest, line, since, actions, agentID }

    /// An action this build has not heard of is left out, so the item still offers the rest.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        key = try c.decode(String.self, forKey: .key)
        title = try c.decode(String.self, forKey: .title)
        digest = try c.decodeIfPresent(String.self, forKey: .digest)
        line = try c.decode(String.self, forKey: .line)
        since = try c.decodeIfPresent(Date.self, forKey: .since)
        actions = try c.decode([String].self, forKey: .actions).compactMap(Action.init(rawValue:))
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
    }
}

/// An item of a folder's `approvals`, or nil when it is of a kind this build has not heard of.
struct LenientApproval: Decodable {
    let approval: Approval?
    init(from decoder: any Decoder) throws { approval = try? Approval(from: decoder) }
}
