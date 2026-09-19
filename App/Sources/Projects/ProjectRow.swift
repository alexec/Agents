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
                    .fill(Color.accentColor)
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

    /// Whether this project wants the person.
    ///
    /// Two ways to want somebody: an agent blocked on a question, which the daemon
    /// counts, and an agent that has asked for a file to be looked at, which only
    /// this window knows because the daemon deliberately stores nothing for it.
    private var needsPerson: Bool { summary.needsInput || model.wantsEyes(in: summary.folder) }

    /// What is going on in there, in as few words as it takes.
    ///
    /// Urgency first, and only ever two facts: this is a caption on one line in a
    /// column that can be 200pt wide, and a third would be the one that truncates.
    /// "Needs attention" goes alone, undiluted — it is the only one of these that is
    /// asking for something.
    private var subtitle: String? {
        let working = summary.counts[.running] ?? 0
        let complete = summary.counts[.finished] ?? 0
        if needsPerson { return "Needs attention" }
        if working > 0 {
            return complete > 0 ? "\(working) working · \(complete) complete" : "\(working) working"
        }
        // A project nobody is working in right now still says what is in it, so a
        // quiet row is a finished project rather than an empty one.
        if complete > 0 { return "\(complete) complete" }
        return nil
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
