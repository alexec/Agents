import AgentsKit
import SwiftUI

/// One folder in the sidebar.
///
/// The name is the directory's own, grown leftwards only when another project would
/// otherwise share it. The dot is the whole reason to look at this list: it says
/// something in here is waiting on you, whichever project you happen to have open.
struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.ProjectSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name)
                    .lineLimit(1)
                    .foregroundStyle(summary.exists ? .primary : .secondary)
                if !summary.exists {
                    Text("Folder is missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if needsPerson {
                Circle()
                    .fill(StateTint.attention.style(or: .secondary))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        // Clicking a project goes to the project, every time.
        //
        // The `List` selection binding cannot carry this: it fires only when the
        // selection changes, and the row you click to leave a conversation is the row
        // that is already selected. `simultaneousGesture` is the one gesture form that
        // sits alongside the list's own handling rather than replacing it, so the
        // highlight, the keyboard and the context menu all keep working.
        .simultaneousGesture(TapGesture().onEnded { model.showProject(summary.folder) })
        .help(abbreviatedPath)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// This window's own counts, from the one grouping its panel uses.
    ///
    /// Not `summary.counts`: the daemon computes those without knowing whether an
    /// agent has asked to be looked at, because it has no window and stores nothing
    /// for one. This window has that fact, so it completes the count itself — and the
    /// number on this row is then the number of rows under the heading, at the same
    /// moment, by construction (FR-007, FR-009).
    private var counts: [AgentGroup: Int] { model.counts(in: summary.folder) }

    /// Whether this project wants the person: exactly when something in it is under
    /// Needs attention, and on no other reckoning (FR-008). It used to OR the daemon's
    /// count with a separate "asked to be looked at" check that never consulted state,
    /// which is how a stopped agent went on wanting eyes.
    private var needsPerson: Bool { (counts[.needsAttention] ?? 0) > 0 }

    /// What is going on in there, in as few words as it takes.
    ///
    /// Urgency first, and only ever two facts: this is a caption on one line in a
    /// column that can be 200pt wide, and a third would be the one that truncates.
    /// "Needs attention" goes alone, undiluted — it is the only one of these that is
    /// asking for something.
    private var subtitle: String? {
        if needsPerson { return "Needs attention" }
        // Every chat that is not archived is something: the agent working, the agent
        // waiting, or the person meaning to do something with it. So the row always
        // carries a number about the unarchived chats — the pressing ones first
        // (working, unread), and when there are none of those, what is left
        // (complete, stopped) — and is quiet only for a project with nothing in it.
        let working = counts[.running] ?? 0
        let unread = model.unreadCount(in: summary.folder)
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if unread > 0 { parts.append("\(unread) unread") }
        if parts.isEmpty {
            let complete = counts[.finished] ?? 0
            let stopped = counts[.stopped] ?? 0
            if complete > 0 { parts.append("\(complete) complete") }
            if stopped > 0 { parts.append("\(stopped) stopped") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = summary.folder.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Said in words, because a coloured dot is not something VoiceOver can read.
    private var accessibilityLabel: String {
        var parts = [summary.name]
        if !summary.exists { parts.append("folder is missing") }
        if needsPerson { parts.append("needs attention") }
        if let subtitle, !needsPerson { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }
}
