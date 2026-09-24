import AgentsKitCore
import SwiftUI

/// The folders you work in, and which of them wants you.
///
/// The first level. On a phone it is the screen the app opens on; on a wide iPad it
/// sits beside the project. Adding a project is not here, and not by accident: making
/// one means choosing a folder on the Mac, and browsing the Mac's file system from a
/// phone is a feature of its own.
struct ProjectListView: View {
    @Environment(RemoteModel.self) private var model
    @Binding var selection: URL?

    var body: some View {
        List(model.projects, selection: $selection) { summary in
            NavigationLink(value: summary.folder) {
                ProjectRow(summary: summary)
            }
            .tag(summary.folder)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Projects")
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .overlay {
            if model.projects.isEmpty { Waiting() }
        }
        .refreshable { await model.refreshEverything() }
    }
}

/// One folder: its name, what is going on in it, and the dot that is the whole reason
/// to look at this list.
struct ProjectRow: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.ProjectSummary

    /// The phone's own counts, not `summary.counts`: the daemon's are made without
    /// knowing which agents have asked to be looked at, and the page under this row
    /// uses the phone's. The Mac's row does the same, for the same reason.
    private var counts: [AgentGroup: Int] { model.counts(in: summary.folder) }

    /// Exactly when something in it is under Needs attention on its page.
    private var needsPerson: Bool { (counts[.needsAttention] ?? 0) > 0 }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
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
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// What is going on in there, in as few words as it takes. The same two facts the
    /// Mac shows, in the same order.
    private var subtitle: String? {
        let working = counts[.running] ?? 0
        if needsPerson { return "Needs attention" }
        if working > 0 { return working == 1 ? "1 working" : "\(working) working" }
        return nil
    }

    /// Said in words, because a coloured dot is not something VoiceOver can read.
    private var accessibilityLabel: String {
        var parts = [summary.name]
        if !summary.exists { parts.append("folder is missing") }
        if needsPerson { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}

/// The first second of the app's life, over a connection with seconds in it.
///
/// Says which of the two things is happening rather than spinning at the user: still
/// asking, or asked and told nothing.
private struct Waiting: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if model.isStale {
            ContentUnavailableView("Can't reach your Mac",
                                   systemImage: "wifi.slash",
                                   description: Text("It needs to be awake and on a network. "
                                                     + "This screen fills in as soon as it answers."))
        } else {
            ProgressView()
        }
    }
}
