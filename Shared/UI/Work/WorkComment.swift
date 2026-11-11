import AgentsKitCore
import SwiftUI

/// A line of an item page's timeline (#4391, parts.md section 6): a 2-point grey line down the
/// leading edge, through the avatars, with a marker on it (an avatar or an event's icon) and the
/// entry beside it.
struct WorkTimelineEntry<Marker: View, Content: View>: View {
    @ViewBuilder var marker: Marker
    @ViewBuilder var content: Content

    /// The marker's column: an avatar's width.
    static var column: CGFloat { 28 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker.frame(width: Self.column)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 14)
        .background(alignment: .leading) {
            Rectangle().fill(Paper.rule).frame(width: 2).padding(.leading, Self.column / 2 - 1)
        }
    }
}

/// A comment on the timeline: an avatar on the line, the author (semibold), "commented 20 min ago"
/// with the exact time as its help, a "bot" capsule for a bot, and the body in a box with a
/// hairline border. On a narrow page (#4400) the avatar goes into the header, 20 points, and the
/// box takes the width. `words` says what in place of "commented 20 min ago" (the body's "opened
/// this").
struct WorkCommentView<Body: View>: View {
    let comment: DaemonAPI.ForgeComment
    var words: String?
    var compact = false
    @ViewBuilder var markdown: Body

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                header
                box
            }
            .padding(.bottom, 14)
        } else {
            WorkTimelineEntry {
                WorkAvatar(login: comment.author, url: comment.avatar, side: WorkTimelineEntry<EmptyView, EmptyView>.column)
            } content: {
                VStack(alignment: .leading, spacing: 6) {
                    header.padding(.top, 5)
                    box
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if compact { WorkAvatar(login: comment.author, url: comment.avatar, side: 20) }
            Text(comment.author).appText(.fine).fontWeight(.semibold)
            if comment.bot == true { WorkBotCapsule() }
            Text(words ?? WorkLook.commentedWords(comment.at))
                .appText(.fine).foregroundStyle(.secondary)
                .help(words == nil ? comment.at.formatted(date: .abbreviated, time: .shortened) : "")
        }
    }

    private var box: some View {
        markdown
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.raised))
            .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
    }
}

/// "bot", after a bot's name.
struct WorkBotCapsule: View {
    var body: some View {
        Text("bot")
            .appText(.fine)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .overlay(Capsule().strokeBorder(Paper.rule))
    }
}

/// An event on the timeline (a label, a state change, a linked pull request): an icon on the line
/// in place of the avatar, a small grey line, no box. The forge's own events come with #4373.
struct WorkTimelineEvent: View {
    let symbol: String
    let words: String
    var at: Date?

    /// The icon of a forge's event; a close takes the issue's reason (#4365).
    static func symbol(_ e: DaemonAPI.ForgeEvent, stateReason: String?) -> String {
        switch e.kind {
        case "labeled", "unlabeled": "tag"
        case "assigned", "unassigned": "person"
        case "closed": stateReason == "not_planned" ? "slash.circle" : "checkmark.circle"
        case "reopened": "arrow.uturn.backward.circle"
        case "referenced": "arrow.turn.down.right"
        default: "circle"
        }
    }

    var body: some View {
        WorkTimelineEntry {
            Image(systemName: symbol)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Paper.well))
        } content: {
            Text([words, at.map { WorkLook.ageWords(Date().timeIntervalSince($0)) }].compactMap { $0 }.joined(separator: " · "))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
        }
    }
}
