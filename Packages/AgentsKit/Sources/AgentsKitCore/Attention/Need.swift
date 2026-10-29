import Foundation

/// What is being answered — not the agent.
///
/// The spec's edge case requires that the same agent asking twice is two needs and that
/// answering the first does not clear the second, so the identity is the question's own.
/// The case is part of the identity: a permission and an elicitation issued the same
/// UUID by two different code paths are two needs, and conflating them would clear the
/// wrong banner. A report carries no id of its own, so it is the agent and the report's
/// timestamp, and a second report on the same agent is a second need.
public enum NeedID: Hashable, Sendable, Codable {
    case permission(UUID)
    case elicitation(UUID)
    case report(UUID, Date)
    /// A change to one of the app's own files in a folder's `.agents`, waiting for Keep
    /// or Undo (#531): the folder and the file, since there is one question per file.
    case guardedChange(URL, String)
    /// What an agent told the person with `notify` (#2805): the host's id for it. Posted
    /// as a need is, but asks nothing, so never a Needs you row or a widget's.
    case notice(String)

    private enum CodingKeys: String, CodingKey { case permission, elicitation, report, guardedChange, notice }
    private struct Report: Codable { var agentID: UUID; var at: Date }
    private struct Guarded: Codable { var folder: URL; var path: String }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.permission) {
            self = .permission(try c.decode(UUID.self, forKey: .permission))
        } else if c.contains(.elicitation) {
            self = .elicitation(try c.decode(UUID.self, forKey: .elicitation))
        } else if c.contains(.report) {
            let r = try c.decode(Report.self, forKey: .report)
            self = .report(r.agentID, r.at)
        } else if c.contains(.guardedChange) {
            let g = try c.decode(Guarded.self, forKey: .guardedChange)
            self = .guardedChange(g.folder, g.path)
        } else if c.contains(.notice) {
            self = .notice(try c.decode(String.self, forKey: .notice))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "a need id names what is asked"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .permission(let id): try c.encode(id, forKey: .permission)
        case .elicitation(let id): try c.encode(id, forKey: .elicitation)
        case .report(let agentID, let at): try c.encode(Report(agentID: agentID, at: at), forKey: .report)
        case .guardedChange(let folder, let path):
            try c.encode(Guarded(folder: folder, path: path), forKey: .guardedChange)
        case .notice(let id): try c.encode(id, forKey: .notice)
        }
    }

    /// One string for the identifier a notification centre wants.
    public var token: String {
        switch self {
        case .permission(let id): return "permission:\(id.uuidString)"
        case .elicitation(let id): return "elicitation:\(id.uuidString)"
        case .report(let agentID, let at): return "report:\(agentID.uuidString):\(at.timeIntervalSinceReferenceDate)"
        case .guardedChange(let folder, let path): return "guarded:\(folder.path):\(path)"
        case .notice(let id): return "notice:\(id)"
        }
    }

    /// A notice (#2805): posted, never a Needs you row or a widget's.
    public var isNotice: Bool {
        if case .notice = self { return true }
        return false
    }

    /// The folder a guarded change's token names (#531), for a banner opened with no
    /// session behind it: its page is where the question is. Standardised as a folder's
    /// folder is, so `folder(_:)` finds it (#1367): a folder with a trailing slash is not
    /// equal to the folder's, and the tap opened nothing.
    public static func guardedFolder(fromToken token: String) -> URL? {
        guard token.hasPrefix("guarded:"), let colon = token.lastIndex(of: ":") else { return nil }
        let start = token.index(token.startIndex, offsetBy: "guarded:".count)
        guard start < colon else { return nil }
        return Folder.standardize(URL(filePath: String(token[start..<colon]), directoryHint: .isDirectory))
    }
}

/// What wants a person.
///
/// Derived, never stored, exactly as `AgentGroup` is — which is what makes it impossible
/// for an agent that needs somebody to have no need. **There is no new detection here and
/// there must never be a second definition** (FR-001): a need is built from the one
/// existing rule, `Agent.needsAPerson`, from the pending dictionaries the daemon already
/// keeps for questions and forms, and from the guarded changes waiting in its records
/// (#531) — the one kind that may have no agent behind it, when git brought the change.
///
/// `raisedAt` never moves. A need that is re-routed from one surface to another is the
/// same need, and the settling pause and the re-alert interval are measured from when
/// the daemon first saw it.
public struct Need: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case permission, elicitation, report, guardedChange
        /// What an agent told the person (#2805): posted, never a Needs you row.
        case notice
    }

    public var id: NeedID
    /// The session it is asked in. nil only for a guarded change no agent made (#531),
    /// which is the folder's: asked on its page.
    public var agentID: UUID?
    public var folder: URL
    public var kind: Kind
    public var raisedAt: Date
    public var headline: Headline

    public init(id: NeedID, agentID: UUID?, folder: URL, kind: Kind, raisedAt: Date, headline: Headline) {
        self.id = id
        self.agentID = agentID
        self.folder = folder
        self.kind = kind
        self.raisedAt = raisedAt
        self.headline = headline
    }
}
