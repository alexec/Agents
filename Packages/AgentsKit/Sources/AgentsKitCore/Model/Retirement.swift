import Foundation

/// What an archived agent's row says about being retired (051).
///
/// Set by the daemon's check and carried on the record, so the Mac and the phone draw the
/// same words from the same fact and neither works anything out for itself.
public enum Retirement: Codable, Hashable, Sendable {
    /// Retired by age at this time. Only set once that is within a week.
    case at(Date)
    /// The next to go if the archive grows past the cap.
    case nextUnderCap
    /// Past its time and kept, for this reason.
    case held(Hold)
    /// Something a newer daemon wrote. Drawn as nothing.
    case unknown(String)

    private enum Key: String, CodingKey { case at, nextUnderCap, held }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let date = try? c.decode(Date.self, forKey: .at) {
            self = .at(date)
        } else if c.contains(.nextUnderCap) {
            self = .nextUnderCap
        } else if let raw = try? c.decode(String.self, forKey: .held) {
            self = Hold(rawValue: raw).map(Retirement.held) ?? .unknown(raw)
        } else {
            self = .unknown(c.allKeys.first?.stringValue ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .at(let date): try c.encode(date, forKey: .at)
        case .nextUnderCap: try c.encode([String: String](), forKey: .nextUnderCap)
        case .held(let hold): try c.encode(hold.rawValue, forKey: .held)
        // Nothing this build can say about it, and nothing it should invent.
        case .unknown: break
        }
    }
}

/// Why an archived agent past its time is not retired yet (051, FR-007).
public enum Hold: String, Codable, Hashable, Sendable, CaseIterable, CodingKeyRepresentable {
    /// Archived under a day ago. Only ever reported in `OverCap`: a day-old agent is not
    /// past its time, so its row has nothing to explain.
    case firstDay
    /// Its app-made worktree has changes that are not committed, or commits not merged.
    case worktreeHasWork
    /// A workflow run it belongs to has not finished.
    case workflowRunning
    /// A window or a device is reading it, or read it in the last few minutes.
    case openInWindow
}

/// Why an agent was retired.
public enum RetiredBecause: String, Codable, Hashable, Sendable {
    case age, cap, person
}

/// The archive is over its cap and nothing more can be retired yet (051, FR-013).
public struct OverCap: Codable, Hashable, Sendable {
    public var bytesOver: Int
    /// How many agents each reason is keeping.
    public var holding: [Hold: Int]

    public init(bytesOver: Int, holding: [Hold: Int]) {
        self.bytesOver = bytesOver
        self.holding = holding
    }
}

/// What is left of a retired agent (051, FR-015).
///
/// Enough that everything naming the agent still has something to name — an event, the
/// agent it started, a worktree, a project's costs — and nothing else: no prompts, no
/// transcript, no options, no credentials. Under 2 KB, which a test holds it to.
public struct Tombstone: Codable, Hashable, Sendable, Identifiable {
    /// The longest title kept.
    public static let titleLimit = 200

    public var id: UUID
    public var title: String?
    public var project: URL
    public var runtimeID: String
    /// Which machine it ran on, as the window that heard of it says. In memory only,
    /// like `Agent.host`: the daemon that owns the record does not know its own name.
    public var host: HostID = .mac
    public var createdAt: Date
    public var lastActivityAt: Date
    public var archivedAt: Date
    public var retiredAt: Date
    public var endedReason: EndedReason?
    public var archivedReason: Agent.ArchivedReason
    public var costToDate: [String: Decimal]
    public var startedByWorkflow: String?
    public var startedByRun: UUID?
    public var startedByAgent: UUID?
    public var worktreeName: String?
    public var worktreeBranch: String?
    public var retiredBecause: RetiredBecause

    enum CodingKeys: String, CodingKey {
        case id, title, project, runtimeID, createdAt, lastActivityAt, archivedAt, retiredAt
        case endedReason, archivedReason, costToDate, startedByWorkflow, startedByRun
        case startedByAgent, worktreeName, worktreeBranch, retiredBecause
    }

    public init(from agent: Agent, retiredAt: Date, because: RetiredBecause) {
        id = agent.id
        title = agent.title.map { String($0.prefix(Self.titleLimit)) }
        project = agent.projectFolder
        runtimeID = agent.runtimeID
        host = agent.host
        createdAt = agent.createdAt
        lastActivityAt = agent.lastActivityAt
        archivedAt = agent.archivedAt ?? retiredAt
        self.retiredAt = retiredAt
        endedReason = agent.endedReason
        archivedReason = agent.archivedReason ?? .byUser
        costToDate = agent.costToDate
        startedByWorkflow = agent.startedByWorkflow
        startedByRun = agent.startedByRun
        startedByAgent = agent.startedByAgent
        worktreeName = agent.worktree?.name
        worktreeBranch = agent.worktree?.branch
        retiredBecause = because
    }
}
