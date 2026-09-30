import AgentsKitCore
import SwiftUI
import WidgetKit

/// The widget, drawn: a number on a small square, and the newest few sessions on a wider
/// one. Both read the same entry and nothing else (FR-002).
///
/// The words are the app's own. "Needs you" is the heading the projects page files these
/// sessions under (`AgentGroup.needsAttention`), and a row's second line is the `Headline`
/// the push banner carries, so the same agent says the same thing in the notification, on
/// the project page, and here.
struct AttentionEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AttentionEntry

    var body: some View {
        switch family {
        case .systemMedium: Medium(entry: entry)
        default: Small(entry: entry)
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(entry.count)")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(StateTint.attention.color ?? .primary)
                Text(entry.count == 1 ? "needs you" : "need you")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if entry.leftover > 0 {
                    Text("+\(entry.leftover) more")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(entry.sessions) { session in
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
                Text(subtitle)
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
    private var subtitle: String {
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
