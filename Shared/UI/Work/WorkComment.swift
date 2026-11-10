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
/// hairline border.
struct WorkCommentView<Body: View>: View {
    let comment: DaemonAPI.ForgeComment
    @ViewBuilder var markdown: Body

    var body: some View {
        WorkTimelineEntry {
            WorkAvatar(login: comment.author, side: WorkTimelineEntry<EmptyView, EmptyView>.column)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.author).appText(.fine).fontWeight(.semibold)
                    if comment.bot == true { WorkBotCapsule() }
                    Text(WorkLook.commentedWords(comment.at))
                        .appText(.fine).foregroundStyle(.secondary)
                        .help(comment.at.formatted(date: .abbreviated, time: .shortened))
                }
                .padding(.top, 5)
                markdown
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.raised))
                    .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
            }
        }
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
/// in place of the avatar, a small grey line, no box. The wire gives the events with #4373.
struct WorkTimelineEvent: View {
    let symbol: String
    let words: String
    var at: Date?

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
