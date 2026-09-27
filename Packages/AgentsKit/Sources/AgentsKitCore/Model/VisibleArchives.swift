import Foundation

/// Which archived sessions stay in the list, and which the Archived disclosure holds.
///
/// A session that archives itself would otherwise vanish into a section that starts
/// closed. The three archived latest today stay under their own heading. Anything
/// older, undated, or past those three stays in the disclosure, in the order given.
public enum VisibleArchives {
    /// Heading for the archives that stay in the list.
    public static let todayTitle = "Archived today"

    /// How many of today's archives stay out of the disclosure.
    public static let keptLimit = 3

    public struct Split: Sendable {
        /// Today's latest archives, most recently archived first.
        public var kept: [Agent]
        /// The rest, in the order they were given.
        public var hidden: [Agent]
    }

    public static func split(_ agents: [Agent], now: Date, calendar: Calendar = .current) -> Split {
        let todays = agents.filter { agent in
            guard let archivedAt = agent.archivedAt else { return false }
            return calendar.isDate(archivedAt, inSameDayAs: now)
        }
        let kept = Array(todays.sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }.prefix(keptLimit))
        let keptIDs = Set(kept.map(\.id))
        return Split(kept: kept, hidden: agents.filter { !keptIDs.contains($0.id) })
    }
}
