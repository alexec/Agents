import AgentsKitCore
import SwiftUI

/// When a session last did anything, in the corner of its row (#341): "5m", "3h", "2d", as
/// the page's row says it. The words are `ActivityWords.short`; the date in full is its help.
///
/// Read again on the minute, so a row nothing else redraws does not go on saying "5m" for
/// an hour. Only this text is redrawn, not the row.
struct ActivityTime: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(ActivityWords.short(since: date, now: context.date))
                .appText(.fine)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .fixedSize()
        .help(date.formatted(date: .abbreviated, time: .shortened))
    }
}
