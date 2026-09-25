import Foundation

/// What one agent holds and waits for, as the chat's lease row and the card's mark say
/// it (036 FR-010).
///
/// Worked out here, once, from the daemon's snapshot, so the Mac's row and the phone's
/// card cannot say it two ways. Nothing is tinted: holding an agreement or waiting for
/// one is not a person being needed, a failure, or a vouched completion, which are the
/// only three things colour means in this app.
public struct LeaseStatus: Equatable, Sendable {
    public struct Holding: Equatable, Sendable {
        public var name: ResourceName
        public var shortName: String
        public var displayName: String
        public var expiresAt: Date
        public var minutesLeft: Int
        public var endingSoon: Bool
    }

    public struct Waiting: Equatable, Sendable {
        public var name: ResourceName
        public var shortName: String
        public var displayName: String
        public var holderName: String
        public var holder: UUID?
        public var until: Date?
        public var place: Int
    }

    public var holding: [Holding]
    public var waiting: [Waiting]

    public static let holdingSymbol = "\u{25A3}"   // ▣
    public static let waitingSymbol = "\u{25F7}"   // ◷

    /// Nil when the agent holds nothing and waits for nothing: then nothing is drawn.
    public static func of(_ agentID: UUID, in snapshot: DaemonAPI.LeaseSnapshot,
                          titles: [UUID: String]) -> LeaseStatus? {
        var holding: [Holding] = []
        var waiting: [Waiting] = []
        for state in snapshot.resources {
            let short = shortName(state.displayName, kind: state.kind)
            if let lease = state.lease, lease.holder == agentID {
                holding.append(Holding(
                    name: state.name, shortName: short, displayName: state.displayName,
                    expiresAt: lease.expiresAt,
                    minutesLeft: LeaseWords.minutesLeft(until: lease.expiresAt, now: snapshot.at),
                    endingSoon: state.endingSoon))
            }
            if let index = state.line.firstIndex(where: { $0.agentID == agentID }) {
                waiting.append(Waiting(
                    name: state.name, shortName: short, displayName: state.displayName,
                    holderName: LeaseWords.agentName(state.lease.flatMap { titles[$0.holder] }),
                    holder: state.lease?.holder, until: state.lease?.expiresAt, place: index + 1))
            }
        }
        guard !holding.isEmpty || !waiting.isEmpty else { return nil }
        return LeaseStatus(holding: holding, waiting: waiting)
    }

    /// The short form a narrow place has room for: "Screen", the device without its
    /// system, a browser's name, a named resource as named.
    public static func shortName(_ displayName: String, kind: ResourceKind) -> String {
        switch kind {
        case .screen: return "Screen"
        case .simulator:
            return displayName.components(separatedBy: " \u{00B7} ").first ?? displayName
        case .browser, .named: return displayName
        }
    }

    // MARK: Words

    /// One capsule each, holdings first: "▣ Screen · 18 min", "◷ Waiting for Screen ·
    /// held by “Fix login” until 14:12 · 2nd".
    public var capsules: [String] {
        holding.map { "\(Self.holdingSymbol) \(Self.holdingWords($0))" }
            + waiting.map { "\(Self.waitingSymbol) \(Self.waitingWords($0))" }
    }

    /// The full line, for a tooltip, a phone's sheet, or a screen reader.
    public var fullLine: String {
        (holding.map { "Holding \($0.displayName), \($0.minutesLeft) min left, until \(LeaseWords.clock($0.expiresAt))" }
            + waiting.map { wait in
                "Waiting for \(wait.displayName), held by \(wait.holderName)"
                    + (wait.until.map { " until \(LeaseWords.clock($0))" } ?? "")
                    + ", \(LeaseWords.ordinal(wait.place)) in line"
            }).joined(separator: ". ") + "."
    }

    /// The first lease or wait, in short: the card's mark and the row's.
    public var mark: String {
        if let first = holding.first { return "Holds \(Self.holdingWords(first))" }
        if let first = waiting.first {
            return "Waiting for \(first.shortName) \u{00B7} \(LeaseWords.ordinal(first.place)) in line"
        }
        return ""
    }

    public var markSymbol: String { holding.isEmpty ? Self.waitingSymbol : Self.holdingSymbol }

    /// How many more than the one the mark names: "and 1 more".
    public var moreCount: Int { holding.count + waiting.count - 1 }

    private static func holdingWords(_ held: Holding) -> String {
        "\(held.shortName) \u{00B7} \(held.minutesLeft) min" + (held.endingSoon ? " left" : "")
    }

    private static func waitingWords(_ wait: Waiting) -> String {
        "Waiting for \(wait.shortName) \u{00B7} held by \(wait.holderName)"
            + (wait.until.map { " until \(LeaseWords.clock($0))" } ?? "")
            + " \u{00B7} \(LeaseWords.ordinal(wait.place))"
    }
}
