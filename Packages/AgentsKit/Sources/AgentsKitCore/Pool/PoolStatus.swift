import Foundation

/// Everything the Pool page and the phone draw, in one answer to `pool/state` (052, US3).
public struct PoolStatus: Codable, Hashable, Sendable {
    public var settings: PoolSettings
    /// One per entry, in pool order.
    public var rows: [Row]
    /// Chats waiting for an allowance to come back (US4).
    public var waiting: [Waiting]
    /// Newest first.
    public var switches: [SwitchRecord]
    /// The chats the switches name, for their titles.
    public var titles: [UUID: String]
    public var at: Date

    public init(settings: PoolSettings, rows: [Row], waiting: [Waiting] = [], switches: [SwitchRecord] = [],
                titles: [UUID: String] = [:], at: Date) {
        self.settings = settings
        self.rows = rows
        self.waiting = waiting
        self.switches = switches
        self.titles = titles
        self.at = at
    }

    /// Lights the sidebar dot (FR-024).
    public var anyOut: Bool { rows.contains { $0.state.isOut } }

    /// "2 out · 3 chats on Codex": the Pool row's count line. Nil when nothing is out.
    public var countLine: String? {
        let out = rows.filter { $0.state.isOut }.count
        guard out > 0 else { return nil }
        let busiest = rows.filter { !$0.state.isOut && $0.chats > 0 }.max { $0.chats < $1.chats }
        let chats = busiest.map { " · \($0.chats) chat\($0.chats == 1 ? "" : "s") on \(PoolWords.runtimeName($0.entry.runtimeID))" } ?? ""
        return "\(out) out\(chats)"
    }

    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var entry: PoolEntry
        public var state: AllowanceState
        public var chats: Int
        /// Why it cannot be used at all: not signed in, not installed. Nil when it can.
        public var unusable: String?

        public var id: UUID { entry.id }

        public init(entry: PoolEntry, state: AllowanceState, chats: Int, unusable: String? = nil) {
            self.entry = entry
            self.state = state
            self.chats = chats
            self.unusable = unusable
        }

        /// The state line, in words (FR-020).
        public func line(now: Date) -> String {
            if let unusable { return "Can't be used: \(unusable)" }
            return PoolWords.state(state, now: now)
        }
    }

    public struct Waiting: Codable, Hashable, Sendable, Identifiable {
        public var agentID: UUID
        public var runtimeID: String
        public var resumeAt: Date
        public var id: UUID { agentID }

        public init(agentID: UUID, runtimeID: String, resumeAt: Date) {
            self.agentID = agentID
            self.runtimeID = runtimeID
            self.resumeAt = resumeAt
        }
    }
}
