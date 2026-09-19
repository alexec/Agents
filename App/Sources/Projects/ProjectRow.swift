import AgentsKit
import SwiftUI

/// One folder in the sidebar.
///
/// The name is the directory's own, grown leftwards only when another project would
/// otherwise share it. The dot is the whole reason to look at this list: it says
/// something in here is waiting on you, whichever project you happen to have open.
struct ProjectRow: View {
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
            if summary.needsInput {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .help(abbreviatedPath)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// What is going on in there, in as few words as it takes.
    private var subtitle: String? {
        let working = summary.counts[.running] ?? 0
        let waiting = summary.counts[.needsAttention] ?? 0
        if waiting > 0 { return "Needs attention" }
        if working > 0 { return working == 1 ? "1 working" : "\(working) working" }
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
        if summary.needsInput { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
