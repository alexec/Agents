import AgentsKitCore
import SwiftUI

/// A pull request waiting for the person's approval in For Review (#3330), drawn as an
/// approval's row is (#773): the mark, the title and its folder, the time, and one grey line,
/// its number and repo. A press opens its page in the browser, so its title is drawn as a link
/// is, in the accent and underlined. Its title is bold until the person opens it, as an unread
/// mail's is (#3464). The window and the Remote both draw it; each adds its own Dismiss.
struct ReviewPullRowLabel: View {
    let pull: ReviewPull
    /// Which folder it is in, after the title, as a smart group's rows name theirs.
    var place: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.pull")
                .sidebarMark(AnyShapeStyle(Paper.accent))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // A link, not white as other rows' titles are (#587): a press leaves the app.
                    Text(pull.title)
                        .appText(.supporting)
                        .fontWeight(pull.isUnread ? .semibold : .regular)
                        .underline()
                        .foregroundStyle(Paper.accent)
                        .lineLimit(1)
                    if let place {
                        Text(place)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(-1)
                    }
                }
                Text(line)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ActivityTime(date: pull.updatedAt)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(pull.isUnread ? "unread pull request waiting for your approval"
                                          : "pull request waiting for your approval")
    }

    /// "Pull request #3330 · alexec/agents".
    var line: String { "Pull request #\(pull.number) · \(pull.repo)" }
}
