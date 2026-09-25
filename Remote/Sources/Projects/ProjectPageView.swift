import AgentsKitCore
import SwiftUI

/// The project itself: its name, and the agents working on it in their groups.
///
/// The second level, and the same page the Mac draws — the groups in the same order,
/// from the same `AgentGroup(for:)`, so the two cannot put an agent under different
/// headings. The Mac's 144pt gutter is not here: a phone is 390 points wide and a
/// gutter that size would leave a column of text a hundred points across.
///
/// New agent is in the toolbar, where it is in reach without scrolling however long
/// the page is, and opens a sheet of its own (029): the choices that go with starting
/// an agent do not belong over a list of the ones already working.
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.startingIn = model.selectedProject
                } label: {
                    Label("New agent", systemImage: "plus")
                }
                .disabled(model.selectedProject == nil)
            }
        }
        .onChange(of: model.selectedProject) { archivedShown = pageSize }
        .sheet(isPresented: Binding(get: { model.startingIn != nil },
                                    set: { if !$0 { model.startingIn = nil } })) {
            if let project = model.startingIn {
                StartAgentView(project: project)
                    .presentationDetents([.large])
                    .presentationSizing(.form)
            }
        }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let summary = model.selectedSummary, !summary.exists {
                    MissingFolder(path: summary.folder.path)
                }

                if let summary = model.selectedSummary {
                    ProjectTotal(summary: summary)
                }

                if !isEmpty {
                    SectionHeading(title: "Sessions")
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

                WorkflowsSection()

                if isEmpty {
                    Text("Nothing here yet. Start an agent with New agent and it appears here.")
                        .appText(.reading)
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

    /// Out of the way until it is wanted, ten at a time, as on the Mac, and behind the
    /// same chevron. On a mobile connection there is a second reason: the rest is not
    /// fetched until it is asked for.
    @ViewBuilder
    private var archivedSection: some View {
        if !archived.isEmpty {
            DisclosureHeading(title: "Archived", count: archived.count, isOpen: $showsArchived)
            if showsArchived {
                ForEach(archived.prefix(archivedShown)) { agent in
                    AgentCard(agent: agent)
                }
                if archived.count > archivedShown {
                    Button("Show more") { archivedShown += pageSize }
                        .appText(.reading)
                        .padding(.top, 4)
                }
            }
        }
    }
}

/// The one case where the folder is news: it has gone.
private struct MissingFolder: View {
    let path: String

    var body: some View {
        Label("This folder is not there any more", systemImage: "exclamationmark.triangle")
            .appText(.reading)
            .tinted(.failure)
            .padding(.top, 4)
            .accessibilityHint(path)
    }
}

/// One of the page's parts — the sessions, the workflows — a step above the
/// `GroupHeading`s inside them.
struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .appText(.reading).fontWeight(.semibold)
            .padding(.top, 18)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A `GroupHeading` that opens and closes what is under it, for what is put away.
struct DisclosureHeading: View {
    let title: String
    let count: Int
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .appText(.fine)
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appText(.fine).fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.top, 14)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
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
        .appText(.fine).fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.top, 14)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }
}
