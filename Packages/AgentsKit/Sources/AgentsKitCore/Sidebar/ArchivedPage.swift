import Foundation

/// What a folder's Archived Sessions and Archived Workflows pages show (#4448): the day
/// groups, the time on a row, the footer and the page's state. The Mac's window and the
/// Remote both draw it; the web has its copy in `Web/src/model/archivedPage.ts`. It
/// replaces `ArchivedSessionsNote` (#664): never "none" until the host has said so, and
/// never a capped page passed off as the whole archive.
public enum ArchivedPage {
    /// How many archived sessions a page holds at first, and how many more Load more asks for.
    public static let pageSize = SidebarFolderFold.archivedShown

    /// What the page draws in place of, or over, its rows.
    public enum State: Equatable, Sendable {
        /// The host has not answered yet: placeholder rows.
        case loading
        /// The host did not answer, or is offline, and nothing was read: the strip alone.
        case hostSilent
        /// The host answered with none.
        case empty
        /// A filter matched none of what is held or what the host found.
        case noMatch
        /// Rows to draw; `stale` when its machine is not answering, so they are what was
        /// last read, dimmed under the strip.
        case rows(stale: Bool)
    }

    /// `held` is the rows the page holds after its filter; `answered` is nil while the ask
    /// is on its way.
    public static func state(held: Int, filtering: Bool, answered: Bool?, hostOffline: Bool) -> State {
        if held > 0 { return .rows(stale: hostOffline || answered == false) }
        if hostOffline || answered == false { return .hostSilent }
        if answered == nil { return .loading }
        return filtering ? .noMatch : .empty
    }

    /// The strip over what was last read, and alone when nothing was.
    public static let staleStrip = "Its machine isn’t answering. Showing what was last read."
    public static let loading = "Loading…"
    public static let loadingMore = "Loading more…"
    public static let filterPrompt = "Filter"

    public enum Sessions {
        public static let title = "Archived Sessions"
        public static let emptyTitle = "No Archived Sessions"
        public static let emptyLine = "Sessions you archive in Agents show here."
        public static let noMatch = "No archived sessions match"
        public static let systemImage = "archivebox"
    }

    public enum Workflows {
        public static let title = "Archived Workflows"
        public static let emptyTitle = "No Archived Workflows"
        public static let emptyLine = "Workflows you archive in Agents show here."
        public static let noMatch = "No archived workflows match"
        public static let systemImage = "clock.arrow.circlepath"
    }

    /// "128 archived sessions", the sidebar row's help and the whole footer.
    public static func sessionCount(_ count: Int) -> String {
        count == 1 ? "1 archived session" : "\(count) archived sessions"
    }

    public static func workflowCount(_ count: Int) -> String {
        count == 1 ? "1 archived workflow" : "\(count) archived workflows"
    }

    /// The footer's words, before Load more: "50 of 128 archived sessions" while the host
    /// has more, "128 archived sessions" with every one held.
    public static func footer(shown: Int, total: Int) -> String {
        total > shown ? "\(shown) of \(sessionCount(total))" : sessionCount(shown)
    }

    /// Whether the footer offers Load more.
    public static func hasMore(shown: Int, total: Int) -> Bool { total > shown }

    /// The limit Load more asks the host for: the next page after what is held.
    public static func nextLimit(held: Int) -> Int { held + pageSize }

    /// One day's rows, under its heading.
    public struct Day: Identifiable, Equatable, Sendable {
        /// The day's start.
        public var id: Date
        public var title: String
        public var isToday: Bool
        public var agents: [Agent]
    }

    /// The sessions in a `Day` each, by when each was archived (`archivedOrder`). In the
    /// order given, newest archived first as the host lists them (#2153): no re-sort.
    public static func days(_ agents: [Agent], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var days: [Day] = []
        for agent in agents {
            let start = calendar.startOfDay(for: agent.archivedOrder)
            if let index = days.firstIndex(where: { $0.id == start }) {
                days[index].agents.append(agent)
            } else {
                days.append(Day(id: start, title: dayTitle(start, now: now, calendar: calendar),
                                isToday: calendar.isDate(start, inSameDayAs: now), agents: [agent]))
            }
        }
        return days
    }

    /// "Today", "Yesterday", then "Friday 7 November", with the year when it is not this year.
    public static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = sameYear ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return formatter.string(from: date)
    }

    /// A row's time, when it was archived: "2 h ago" (or "12 min ago", "now") today, the
    /// clock time ("18:40") on any other day.
    public static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let minutes = max(0, Int((now.timeIntervalSince(date) / 60).rounded(.down)))
            if minutes < 1 { return "now" }
            if minutes < 60 { return "\(minutes) min ago" }
            return "\(minutes / 60) h ago"
        }
        let at = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", at.hour ?? 0, at.minute ?? 0)
    }
}
