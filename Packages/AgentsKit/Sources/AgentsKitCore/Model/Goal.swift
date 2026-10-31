import Foundation

/// The standing aim an agent's runtime keeps working towards over many turns (#2742).
///
/// Codex's and Claude's adapters report it on a `session_info_update`, under
/// `_meta.jetbrains.air.goal`, and the host keeps the last one on `Agent.goal`. A runtime
/// that reports none has none, and no card is drawn. It is not a status: an active goal
/// says it can drive more work, not that a turn runs now, so the row keeps its own marks.
public struct Goal: Codable, Hashable, Sendable {
    public var objective: String
    public var status: Status
    /// How many turns it took towards the goal, where the runtime counts them (Claude).
    public var iterations: Int?
    /// Why it last stopped or paused, in the runtime's words.
    public var reason: String?
    public var tokensUsed: Int?
    /// The tokens it can use on the goal, when it has a budget (Codex).
    public var tokenBudget: Int?
    public var timeUsedSeconds: Double?
    /// When the host last heard of it.
    public var at: Date

    public enum Status: String, Codable, Hashable, Sendable {
        case active, paused, blocked, limited, complete
    }

    public init(objective: String, status: Status, iterations: Int? = nil, reason: String? = nil,
                tokensUsed: Int? = nil, tokenBudget: Int? = nil, timeUsedSeconds: Double? = nil, at: Date = Date()) {
        self.objective = objective
        self.status = status
        self.iterations = iterations
        self.reason = reason
        self.tokensUsed = tokensUsed
        self.tokenBudget = tokenBudget
        self.timeUsedSeconds = timeUsedSeconds
        self.at = at
    }
}

/// The goal card's words (#2742), said once for the window and the Remote. The page has its
/// own copy in `Web/src/model/goal.ts`, held to `Fixtures/web/goal/card.json`.
extension Goal {
    /// Where it stands, in a word or two at the card's end.
    public var statusWord: String {
        switch status {
        case .active: "Active"
        case .paused: "Paused"
        case .blocked: "Blocked"
        case .limited: "Limit reached"
        case .complete: "Met"
        }
    }

    /// Stopped short of the goal: the card says why under the line, when the runtime said.
    public var isStopped: Bool {
        status == .paused || status == .blocked || status == .limited
    }

    /// How far along, as far as the runtime says: "3 turns · 42 of 1,000 tokens · 12 min".
    /// Nil when it says nothing of it.
    public var progressLine: String? {
        var parts: [String] = []
        if let iterations { parts.append(iterations == 1 ? "1 turn" : "\(iterations) turns") }
        if let tokenBudget {
            parts.append("\(Self.count(tokensUsed ?? 0)) of \(Self.count(tokenBudget)) tokens")
        } else if let tokensUsed, tokensUsed > 0 {
            parts.append("\(Self.count(tokensUsed)) tokens")
        }
        if let timeUsedSeconds, timeUsedSeconds > 0 { parts.append(Self.duration(timeUsedSeconds)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How much of its budget it has used, for the bar; nil with no budget.
    public var budgetFraction: Double? {
        guard let tokenBudget, tokenBudget > 0 else { return nil }
        return min(Double(tokensUsed ?? 0) / Double(tokenBudget), 1)
    }

    /// The card read aloud: "Goal: Ship the change. Paused: Waiting on review. 3 turns".
    public var summary: String {
        var line = "Goal: \(objective). \(statusWord)"
        if let reason { line += ": \(reason)" }
        if let progressLine { line += ". \(progressLine)" }
        return line
    }

    /// "1,000", as the org policy's token counts are written.
    static func count(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_GB")))
    }

    /// "under a minute", "12 min", "1 h 5 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}
