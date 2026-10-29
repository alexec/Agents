import AgentsKitCore
import SwiftUI

/// What an agent told the person with `notify` (#2805), where it called it: a bell, the
/// title in bold, the body under it, and the time with what became of the notification.
/// Not a bubble, since the agent did not say it in its reply; not a card, since it has
/// nothing to answer. The web page's "notified" row draws the same.
struct NotifiedLine: View {
    let notice: SentNotice
    let at: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bell")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).appText(.reading).bold()
                if let body = notice.body {
                    Text(body).appText(.reading)
                }
                Text("\(at.formatted(date: .omitted, time: .shortened)) \u{00B7} \(notice.outcomeText())")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
