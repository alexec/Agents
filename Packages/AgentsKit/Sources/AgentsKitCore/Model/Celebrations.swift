import Foundation

/// Pull requests the host's hourly count found newly merged (#986), for the Blob to
/// celebrate. Sent as `prs/landed`, only when the count went up: never for the first
/// count, which looks back over days the person has already seen.
public struct PRsLanded: Codable, Hashable, Sendable {
    /// How many more than the last count said.
    public var count: Int
    /// Whether today had none merged before these: the day's first merge.
    public var firstToday: Bool

    public init(count: Int, firstToday: Bool) {
        self.count = count
        self.firstToday = firstToday
    }
}

extension TimeHistory {
    /// What `counts` for `days` add to the counts held: nil where nothing more merged, or
    /// where nothing was counted before, so a first count back-fills without a party.
    public func landed(_ counts: [String: Int], on days: [String], today: String) -> PRsLanded? {
        guard recap.values.contains(where: { $0.prsMerged != nil }) else { return nil }
        let before = { (day: String) in recap[day]?.prsMerged ?? 0 }
        let more = days.reduce(0) { $0 + max(0, (counts[$1] ?? 0) - before($1)) }
        guard more > 0 else { return nil }
        return PRsLanded(count: more, firstToday: before(today) == 0 && (counts[today] ?? 0) > 0)
    }
}

/// One moment the Blob celebrates (#986): a pull request landed, with confetti for the
/// day's first and for a milestone earned. Held by the model until a client plays it.
public struct Celebration: Hashable, Sendable, Identifiable {
    /// Moves with each one, so a client plays a new one even when it looks the same.
    public var id: Int
    public var confetti: Bool

    public init(id: Int, confetti: Bool) {
        self.id = id
        self.confetti = confetti
    }

    /// Where each client keeps its Settings ▸ Appearance switch, on by default, on that
    /// device only.
    public static let defaultsKey = "celebrations"

    /// How long the Blob stays: up, one bounce, and away.
    public static let seconds: Double = 2.2
}
