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

    private enum CodingKeys: String, CodingKey { case permission, elicitation, report }
    private struct Report: Codable { var agentID: UUID; var at: Date }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.permission) {
            self = .permission(try c.decode(UUID.self, forKey: .permission))
        } else if c.contains(.elicitation) {
            self = .elicitation(try c.decode(UUID.self, forKey: .elicitation))
        } else if c.contains(.report) {
            let r = try c.decode(Report.self, forKey: .report)
            self = .report(r.agentID, r.at)
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
        }
    }

    /// One string for the identifier a notification centre wants.
    public var token: String {
        switch self {
        case .permission(let id): return "permission:\(id.uuidString)"
        case .elicitation(let id): return "elicitation:\(id.uuidString)"
        case .report(let agentID, let at): return "report:\(agentID.uuidString):\(at.timeIntervalSinceReferenceDate)"
        }
    }
}

/// What wants a person.
///
/// Derived, never stored, exactly as `AgentGroup` is — which is what makes it impossible
/// for a need to exist without an agent behind it, or for an agent that needs somebody
/// to have no need. **There is no new detection here and there must never be a second
/// definition** (FR-001): a need is built from the one existing rule, `Agent.needsAPerson`,
/// and from the pending dictionaries the daemon already keeps for questions and forms.
///
/// `raisedAt` never moves. A need that is re-routed from one surface to another is the
/// same need, and the settling pause and the re-alert interval are measured from when
/// the daemon first saw it.
public struct Need: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case permission, elicitation, report
    }

    public var id: NeedID
    public var agentID: UUID
    public var folder: URL
    public var kind: Kind
    public var raisedAt: Date
    public var headline: Headline

    public init(id: NeedID, agentID: UUID, folder: URL, kind: Kind, raisedAt: Date, headline: Headline) {
        self.id = id
        self.agentID = agentID
        self.folder = folder
        self.kind = kind
        self.raisedAt = raisedAt
        self.headline = headline
    }
}
