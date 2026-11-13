import AgentsKitCore
import SwiftUI

/// The "Last update 5 min ago" line (#5139, #5141) on its own, in `ink.secondary` at the
/// caption step: for the top of a pane that has no banner. A banner puts the words after its
/// own with `LastUpdateTimeline`. A status line, not a control.
struct LastUpdateText: View {
    let read: Date

    var body: some View {
        LastUpdateTimeline(read: read) { now in
            Text(LastUpdate.line(since: read, now: now))
                .appText(.fine)
                .foregroundStyle(Paper.secondary)
                .lineLimit(1)
                .accessibilityLabel(LastUpdate.spoken(since: read, now: now))
        }
        .help(read.formatted(date: .abbreviated, time: .shortened))
    }
}

/// Draws `content` again each time the words of a read's age can change: every 10 s for the
/// first minute, then once a minute. Only what it wraps is drawn again.
struct LastUpdateTimeline<Content: View>: View {
    let read: Date
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(LastUpdateSchedule(read: read)) { context in content(context.date) }
    }
}

/// `LastUpdate.nextChange` as a timeline's schedule.
struct LastUpdateSchedule: TimelineSchedule {
    let read: Date

    func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(read: read, upcoming: startDate)
    }

    struct Entries: Sequence, IteratorProtocol {
        let read: Date
        var upcoming: Date?

        mutating func next() -> Date? {
            guard let now = upcoming else { return nil }
            upcoming = LastUpdate.nextChange(since: read, after: now)
            return now
        }
    }
}
