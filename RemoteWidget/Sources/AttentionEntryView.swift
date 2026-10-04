import AgentsKitCore
import SwiftUI
import WidgetKit

/// The widget, drawn: a number on a small square, the newest few sessions on a wider one,
/// and more of them, with more of each, on a large one (#192). All read the same entry and
/// nothing else (FR-002).
///
/// The words are the app's own. "Needs you" is the heading the projects page files these
/// sessions under (`AgentGroup.needsAttention`), and a row's second line is the `Headline`
/// the push banner carries, so the same agent says the same thing in the notification, on
/// the project page, and here.
struct AttentionEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AttentionEntry

    var body: some View {
        AttentionLayout(entry: entry, size: Self.size(of: family))
    }

    /// WidgetKit's family as the snapshot's size, which is what says how many rows it has.
    static func size(of family: WidgetFamily) -> AttentionSnapshot.Size {
        switch family {
        case .systemMedium: .medium
        case .systemLarge: .large
        case .systemExtraLarge: .extraLarge
        default: .small
        }
    }
}

/// One size's layout, chosen by the snapshot's size rather than read from the environment,
/// so every size can be drawn outside a widget too (`specs/192-remote-widget/`).
struct AttentionLayout: View {
    let entry: AttentionEntry
    let size: AttentionSnapshot.Size

    var body: some View {
        switch size {
        case .small: Small(entry: entry)
        case .medium: Medium(entry: entry)
        case .large, .extraLarge: Large(entry: entry, size: size)
        }
    }
}

/// The number, and nothing else. Orange when somebody is needed, which is the one colour
/// this codebase has for that (`StateTint`); grey when nobody is (FR-003).
private struct Small: View {
    let entry: AttentionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.isUnknown {
                Spacer(minLength: 0)
                Text("Open Agents")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                Text("to see what needs you")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text("\(entry.count)")
                    .font(.system(size: 40, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(countStyle)
                Text(entry.isEmpty ? "Nothing waiting" : "Needs you")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                if let age = entry.age(), entry.isStale() {
                    Spacer(minLength: 0)
                    Updated(age: age)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(AttentionLink.attention.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Nobody waiting is drawn in the app's own secondary, and somebody waiting in the
    /// app's one colour for that. The tint is asked for by case, never by colour.
    private var countStyle: AnyShapeStyle {
        entry.isEmpty ? StateTint.none.style(or: .secondary) : StateTint.attention.style(or: .primary)
    }

    private var accessibilityLabel: String {
        if entry.isUnknown { return "Agents. Open the app to see what needs you" }
        if entry.isEmpty { return "Nothing is waiting for you" }
        return "\(entry.count) \(entry.count == 1 ? "session needs" : "sessions need") you"
    }
}

/// The number, and the sessions behind it. Each row is a `Link` into that conversation
/// (FR-011); with nothing to list, the whole widget goes wherever the small one goes.
private struct Medium: View {
    let entry: AttentionEntry

    var body: some View {
        if entry.isUnknown {
            Unknown()
        } else if entry.isEmpty {
            NothingWaiting()
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 7) {
            Heading(count: entry.count, leftover: entry.leftover(for: .medium))
            ForEach(entry.rows(for: .medium)) { session in
                Link(destination: AttentionLink.agent(session.id).url) {
                    SessionRow(session: session)
                }
            }
            if let age = entry.age(), entry.isStale() {
                Updated(age: age)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The count in the one colour for a thing that needs a person, what it means, and how
/// many are waiting that are not drawn. The same over medium and large.
private struct Heading: View {
    let count: Int
    let leftover: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(count)")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .monospacedDigit()
                .foregroundStyle(StateTint.attention.color ?? .primary)
            Text(count == 1 ? "needs you" : "need you")
                .appText(.supporting)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if leftover > 0 {
                Text("+\(leftover) more")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// More sessions, and more of each: the headline over up to two lines and how long it has
/// waited (#192). The extra large one on an iPad is two columns of the same rows, read down
/// the first and then the second, as the app's own list is.
private struct Large: View {
    let entry: AttentionEntry
    let size: AttentionSnapshot.Size

    var body: some View {
        if entry.isUnknown {
            Unknown()
        } else if entry.isEmpty {
            NothingWaiting()
        } else {
            rows
        }
    }

    /// As many of the rows as fit, newest first, with the rest counted: at a large text
    /// size fewer fit, and a row is left out whole rather than cut off (#192).
    private var rows: some View {
        let all = entry.rows(for: size)
        return ViewThatFits(in: .vertical) {
            ForEach(Array(stride(from: all.count, through: 1, by: -1)), id: \.self) { drawn in
                fitted(Array(all.prefix(drawn)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fitted(_ sessions: [AttentionSnapshotSession]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(count: entry.count, leftover: max(0, entry.count - sessions.count))
            if size == .extraLarge {
                let half = (sessions.count + 1) / 2
                HStack(alignment: .top, spacing: 20) {
                    column(Array(sessions.prefix(half)))
                    column(Array(sessions.dropFirst(half)))
                }
            } else {
                column(sessions)
            }
            if let age = entry.age(), entry.isStale() {
                Updated(age: age)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func column(_ sessions: [AttentionSnapshotSession]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sessions) { session in
                Link(destination: AttentionLink.agent(session.id).url) {
                    LargeRow(session: session, now: entry.date)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One session with room: its title and how long it has waited, then the project and what
/// it is asking for, the asking allowed a second line before it truncates.
private struct LargeRow: View {
    let session: AttentionSnapshotSession
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: SessionRow.symbol(for: session.kind) ?? Self.unread)
                .appText(.fine)
                .foregroundStyle(session.kind == nil
                                 ? StateTint.none.style(or: .secondary) : StateTint.attention.style(or: .tertiary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .appText(.supporting)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(session.waited(at: now))
                        .appText(.fine)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                }
                Text(SessionRow.subtitle(for: session))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The app's mark for something done and not yet read (#70), for a session with no
    /// need pending.
    private static let unread = "circle.fill"

    private var accessibilityLabel: String {
        let state = switch session.kind {
        case .permission: "asks permission"
        case .elicitation: "asks a question"
        case .report: "has a report"
        case nil: "finished, unread"
        }
        let waited = session.since.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return [session.title, session.project, state, session.wanted, "since \(waited)"]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// One session: what it is called, where it is, and what it is asking for.
private struct SessionRow: View {
    let session: AttentionSnapshotSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The need's own kind, so a permission does not look like a question. Empty
            // for a session with nothing pending, which says what it is instead.
            if let symbol = Self.symbol(for: session.kind) {
                Image(systemName: symbol)
                    .appText(.fine)
                    .foregroundStyle(StateTint.attention.style(or: .tertiary))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .appText(.supporting)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(Self.subtitle(for: session))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The project's name, and what is being asked for where something is being asked.
    static func subtitle(for session: AttentionSnapshotSession) -> String {
        guard let wanted = session.wanted, !wanted.isEmpty else { return session.project }
        return "\(session.project) · \(wanted)"
    }

    private var accessibilityLabel: String {
        [session.title, session.project, session.wanted]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The same three shapes the app draws a need as, so a row here and a row in the app
    /// are the same thing seen twice.
    static func symbol(for kind: Need.Kind?) -> String? {
        switch kind {
        case .permission: "hand.raised.fill"
        case .elicitation: "questionmark.circle.fill"
        case .report: "exclamationmark.bubble.fill"
        case nil: nil
        }
    }
}

/// Nothing waiting. Said in words rather than shown as a zero with no rows under it, which
/// looks like a mistake (FR-008).
private struct NothingWaiting: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            Text("Nothing waiting")
                .appText(.reading)
                .fontWeight(.semibold)
            Text("Every agent is either working or done.")
                .appText(.fine)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(AttentionLink.attention.url)
    }
}

/// The app has not been opened since it was installed, so the widget has nothing and says
/// so. A zero here would be a claim it cannot back (FR-009).
private struct Unknown: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            Text("Open Agents")
                .appText(.reading)
                .fontWeight(.semibold)
            Text("This widget shows what needs you once the app has been open.")
                .appText(.fine)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(AttentionLink.attention.url)
    }
}

/// How long ago the number last moved, once it is old enough to matter (FR-017).
///
/// The app only writes the file when the count or the rows change, so this is when
/// something actually happened, not when the app last happened to look.
private struct Updated: View {
    let age: Date

    var body: some View {
        Text("Updated \(age, style: .relative) ago")
            .appText(.fine)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Last updated \(age.formatted(.relative(presentation: .named))) ago")
    }
}
