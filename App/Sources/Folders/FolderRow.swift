import AgentsKitCore
import SwiftUI

/// One folder in the sidebar, the row its sessions fold under (#145).
///
/// The name is the directory's own, grown leftwards only when another folder would
/// otherwise share it, and on a server led by the server's name. The dot is the whole
/// reason to look at this list: it says something in here is waiting on you, whichever
/// folder you happen to have open, folded or not.
struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.FolderSummary
    /// The name as the sidebar shows it: `server:Folder` on a server.
    var label: String? = nil
    /// Folded, the row says what is under it; unfolded, the rows under it say that.
    var isFolded = true
    /// Drawn as its group's heading in the sidebar (#495): the name in grey, as a group's
    /// heading is, so the sessions under it read first.
    var asHeading = false
    /// What a click does: the fold opens or closes, and nothing else (#375), as the
    /// Remote's row and the web's do. A session starts from the fold's New session row.
    var onClick: () -> Void = {}

    /// The name's colour.
    private var nameStyle: HierarchicalShapeStyle { summary.exists && !asHeading ? .primary : .secondary }

    /// The dot grows with the title beside it (#750).
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // A pinned folder shows no pin: being at the top says it.
                    Text(label ?? summary.name)
                        .lineLimit(1)
                        .foregroundStyle(nameStyle)
                }
                if !summary.exists {
                    Text("Folder is missing")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else if isFolded, !asHeading, let subtitle {
                    Text(subtitle)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // As a heading, no count: its Sessions fold has one, and the folder holds more
            // than sessions (#2364). Who needs you is in Needs You at the top, so no dot.
            if !asHeading, needsPerson {
                Circle()
                    .fill(StateTint.attention.style(or: .secondary))
                    .frame(width: 7 * scale, height: 7 * scale)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        // Clicking a folder folds or unfolds it (#375); the detail stays as it was.
        // `simultaneousGesture` sits alongside the list's own handling rather than
        // replacing it, so the context menu keeps working.
        .simultaneousGesture(TapGesture().onEnded { onClick() })
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
    private var counts: [AgentGroup: Int] { model.counts(in: summary.key) }

    /// Whether a session in this folder needs the person to read or act, or a workflow
    /// here has stopped working (#989).
    private var needsPerson: Bool {
        (counts[.needsAttention] ?? 0) > 0 || summary.hasFailedWorkflow
    }

    /// What is going on in there, in as few words as it takes.
    ///
    /// Urgency first, and only ever two facts: this is a caption on one line in a
    /// column that can be 200pt wide, and a third would be the one that truncates.
    /// Unread is counted beside Needs you, not inside it (#70), so a folder with both
    /// says both.
    private var subtitle: String? {
        if needsPerson {
            let unread = model.unreadCount(in: summary.key)
            return unread > 0 ? "Needs you · \(unread) unread" : "Needs you"
        }
        // Every chat that is not archived is something: the agent working, the agent
        // waiting, or the person meaning to do something with it. So the row always
        // carries a number about the unarchived chats — the pressing ones first
        // (working, unread), and when there are none of those, what is left
        // (complete, stopped) — and is quiet only for a folder with nothing in it.
        let working = counts[.running] ?? 0
        let unread = model.unreadCount(in: summary.key)
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
        let home = RealHome.path
        let path = summary.folder.folder.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Said in words, because a coloured dot is not something VoiceOver can read.
    private var accessibilityLabel: String {
        var parts = [label ?? summary.name]
        if summary.folder.isPinned { parts.append("pinned") }
        if !summary.exists { parts.append("folder is missing") }
        if !asHeading, let subtitle {
            parts.append(subtitle)
        }
        return parts.joined(separator: ", ")
    }
}
