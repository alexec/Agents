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
            .paperListRow()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // One shade deeper than the page, as the Mac's projects column is.
        .background(Paper.sidebar)
        .toolbarBackground(Paper.sidebar, for: .navigationBar)
        .navigationTitle("Projects")
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        // Pinned under the projects, as on the Mac: it is about all of them, and the
        // foot of this column is where the money has always been.
        .safeAreaInset(edge: .bottom, spacing: 0) { SpendingRow() }
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
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else if let subtitle {
                    Text(subtitle)
                        .appText(.fine)
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

/// The way into Spending, and what today has cost on the way past — the Mac's row,
/// drawn whether or not anything has been spent so it is always there to go in by.
private struct SpendingRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        NavigationLink {
            TotalsView()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(today == nil ? "Spending" : "Today")
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if let today {
                        Text(today).monospacedDigit()
                    }
                    if let state = model.costState, let left = state.dayHeadroom,
                       let daily = state.limits.daily {
                        Text("\(left.money(in: daily.currency)) left")
                            .appText(.fine)
                    }
                }
                Image(systemName: "chevron.right")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
            }
            .appText(.supporting)
            .foregroundStyle((model.costState?.dayIsCloseToFull == true ? StateTint.failure : .none)
                                .style(or: .secondary))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Paper.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
        .accessibilityHint("Opens Spending")
    }

    private var today: String? {
        model.costState.flatMap { Cost.total(of: $0.today) }
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
