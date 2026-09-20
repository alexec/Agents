import AgentsKitCore
import SwiftUI

/// The project itself: its name, and the agents working on it in their groups.
///
/// The second level, and the same page the Mac draws — the groups in the same order,
/// from the same `AgentGroup(for:)`, so the two cannot put an agent under different
/// headings. The Mac's 144pt gutter is not here: a phone is 390 points wide and a
/// gutter that size would leave a column of text a hundred points across.
///
/// The prompt bar is not here yet. Starting an agent from the remote is US2, and this
/// page is built now so that the layout under it has stopped moving by the time it
/// arrives.
struct ProjectPageView: View {
    @Environment(RemoteModel.self) private var model
    @State private var showsArchived = false
    @State private var archivedShown = pageSize
    private static let pageSize = 10
    private var pageSize: Int { Self.pageSize }

    var body: some View {
        Group {
            if model.selectedProject == nil {
                ContentUnavailableView("No project chosen", systemImage: "folder",
                                       description: Text("Pick one to see what is working on it."))
            } else {
                page
            }
        }
        .navigationTitle(model.selectedSummary?.name ?? "Project")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .onChange(of: model.selectedProject) { archivedShown = pageSize }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let summary = model.selectedSummary, !summary.exists {
                    MissingFolder(path: summary.folder.path)
                }

                ForEach(AgentGroup.live, id: \.self) { group in
                    let agents = model.agents(group: group)
                    if !agents.isEmpty {
                        GroupHeading(title: group.title, count: agents.count)
                        ForEach(agents) { agent in
                            AgentCard(agent: agent)
                        }
                    }
                }

                archivedSection

                if isEmpty {
                    Text("Nothing here yet. Start an agent on the Mac and it appears here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableWidth()
        }
        .markedStale(model.isStale)
        .refreshable { await model.refreshEverything() }
    }

    private var isEmpty: Bool {
        AgentGroup.allCases.allSatisfy { model.agents(group: $0).isEmpty }
    }

    private var archived: [Agent] { model.agents(group: .archived) }

    /// Out of the way until it is wanted, ten at a time, as on the Mac. On a mobile
    /// connection there is a second reason: the rest is not fetched until it is asked
    /// for.
    @ViewBuilder
    private var archivedSection: some View {
        if showsArchived {
            GroupHeading(title: "Archived", count: archived.count)
            ForEach(archived.prefix(archivedShown)) { agent in
                AgentCard(agent: agent)
            }
            if archived.count > archivedShown {
                Button("Show more") { archivedShown += pageSize }
                    .font(.callout)
                    .padding(.top, 4)
            }
            Button("Hide archived") { showsArchived = false }
                .font(.callout)
                .padding(.top, 6)
        } else if !archived.isEmpty {
            Button("Archived (\(archived.count))") { showsArchived = true }
                .font(.callout)
                .padding(.top, 10)
        }
    }
}

/// The one case where the folder is news: it has gone.
private struct MissingFolder: View {
    let path: String

    var body: some View {
        Label("This folder is not there any more", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .tinted(.failure)
            .padding(.top, 4)
            .accessibilityHint(path)
    }
}

/// What the cards under it have in common, and how many there are.
struct GroupHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.top, 14)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }
}
