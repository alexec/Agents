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
    /// A change to one of the app's own files in a project's `.agents`, waiting for Keep
    /// or Undo (#531): the project and the file, since there is one question per file.
    case guardedChange(URL, String)
    /// What a Notify me choice brought (#2034): the host's id for it. Not a Needs you row.
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

    /// The project a guarded change's token names (#531), for a banner opened with no
    /// session behind it: its page is where the question is. Standardised as a project's
    /// folder is, so `project(_:)` finds it (#1367): a folder with a trailing slash is not
    /// equal to the project's, and the tap opened nothing.
    public static func guardedFolder(fromToken token: String) -> URL? {
        guard token.hasPrefix("guarded:"), let colon = token.lastIndex(of: ":") else { return nil }
        let start = token.index(token.startIndex, offsetBy: "guarded:".count)
        guard start < colon else { return nil }
        return Project.standardize(URL(filePath: String(token[start..<colon]), directoryHint: .isDirectory))
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
        /// Notify me (#2034): posted, never listed in Needs you.
        case notice
    }

    public var id: NeedID
    /// The session it is asked in. nil only for a guarded change no agent made (#531),
    /// which is the project's: asked on its page.
    public var agentID: UUID?
    public var folder: URL
    public var kind: Kind
    public var raisedAt: Date
    public var headline: Headline
    /// A notice's (#2034): the item's page on its site, which opening the notice opens.
    public var url: String?

    /// Whether it is a Needs you row: a notice is only posted (#2034).
    public var isNeedsYou: Bool { kind != .notice }

    public init(id: NeedID, agentID: UUID?, folder: URL, kind: Kind, raisedAt: Date, headline: Headline, url: String? = nil) {
        self.url = url
        self.id = id
        self.agentID = agentID
        self.folder = folder
        self.kind = kind
        self.raisedAt = raisedAt
        self.headline = headline
    }
}

/// A banner's three lines (spec 021, #2034): the agent, its project, and what is wanted; for
/// a notice, what happened, then where it came from. The Mac, the Remote and the push
/// extension say the same.
public struct BannerLines: Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String

    public init(_ headline: Headline, for need: NeedID) {
        if case .notice = need {
            title = headline.h3
            subtitle = ""
            body = "\(headline.h2) \u{00B7} \(headline.h1)"
        } else {
            title = headline.h2
            subtitle = headline.h1
            body = headline.h3
        }
    }
}

public extension NeedID {
    /// A Notify me notice (#2034): posted, never a Needs you row or a widget's.
    var isNotice: Bool {
        if case .notice = self { return true }
        return false
    }
}
