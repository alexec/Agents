import AgentsKitCore
import SwiftUI

/// The project itself: its name, and the agents working on it in their groups.
///
/// The second level, and the same page the Mac draws — the groups in the same order,
/// from the same `AgentGroup(for:)`, so the two cannot put an agent under different
/// headings. The Mac's 144pt gutter is not here: a phone is 390 points wide and a
/// gutter that size would leave a column of text a hundred points across.
///
/// New session is in the toolbar, where it is in reach without scrolling however long
/// the page is, and opens a sheet of its own (029): the choices that go with starting
/// an agent do not belong over a list of the ones already working.
struct ProjectPageView: View {
    @Environment(RemoteModel.self) private var model
    @State private var showsArchived = false
    @State private var archivedShown = pageSize
    @State private var query = ""
    /// The groups folded on this device (#181), as the Mac keeps its own.
    @AppStorage(FoldedGroups.key) private var folded = FoldedGroups()
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
        .searchable(text: $query, prompt: "Search sessions or label:name")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.startingIn = model.selectedProject
                } label: {
                    Label("New session", systemImage: "plus")
                }
                .disabled(model.selectedProject == nil)
            }
        }
        .onChange(of: model.selectedProject) { archivedShown = pageSize }
        .task(id: model.selectedProject) {
            if let folder = model.selectedProject { await model.loadLabelVocabulary(in: folder) }
        }
        // Its workflows, pinned pages, Dashboard row and the cards' lease marks (#175).
        .shows([.workflows, .pins, .dashboards, .leases])
        .task(id: query.isEmpty ? "" : (model.selectedProject?.absoluteString ?? "")) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let folder = model.selectedProject else { return }
            await model.loadAllArchivedAgents(in: folder)
        }
        .sheet(isPresented: Binding(get: { model.startingIn != nil },
                                    set: { if !$0 { model.startingIn = nil } })) {
            if let project = model.startingIn {
                StartAgentView(project: project)
                    .paperSheet()
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

                // Above Sessions, worth a glance without opening (074 FR-032).
                if query.isEmpty, let folder = model.selectedProject {
                    DashboardRow(folder: folder)
                }

                // Then its pinned pages (#159), as the Mac lists them under the project.
                if query.isEmpty, let folder = model.selectedProject {
                    PinnedPageCards(folder: folder)
                }

                if !isEmpty {
                    SectionHeading(title: "Sessions")
                }

                // Pinned first, whatever their state (#180); they leave their groups below.
                let pinned = matching(pinnedAgents)
                if !pinned.isEmpty {
                    let isOpen = !query.isEmpty || !isFolded("pinned")
                    DisclosureHeading(title: "Pinned", count: pinned.count,
                                      unread: pinned.filter(\.showsUnread).count,
                                      tint: !isOpen && pinned.contains { model.work.group(of: $0) == .needsAttention }
                                          ? .attention : .none,
                                      isOpen: Binding(get: { isOpen }, set: { setFolded("pinned", !$0) }))
                    if isOpen {
                        ForEach(pinned) { agent in
                            AgentCard(agent: agent)
                        }
                    }
                }

                ForEach(AgentGroup.live, id: \.self) { group in
                    ForEach(group.headings(matching(unpinned(model.agents(group: group))))) { heading in
                        // Each group folds at its heading (#181); a search shows every match.
                        let isOpen = !query.isEmpty || !isFolded(group.rawValue)
                        DisclosureHeading(title: heading.title, count: heading.agents.count,
                                          unread: heading.agents.filter(\.showsUnread).count,
                                          tint: !isOpen && group == .needsAttention ? .attention : .none,
                                          isOpen: Binding(get: { isOpen }, set: { setFolded(group.rawValue, !$0) }))
                        if isOpen {
                            ForEach(heading.agents) { agent in
                                AgentCard(agent: agent)
                            }
                        }
                    }
                }

                archivedSection

                if !query.isEmpty, !hasMatches {
                    ContentUnavailableView("No matching sessions", systemImage: "magnifyingglass",
                                           description: Text("No session matches “\(query)”."))
                }

                WorkflowsSection()

                if isEmpty {
                    Text("Nothing here yet. Start a session with New session and it appears here.")
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
        // The cards' swipe to Archive (`AgentCard`).
        .swipeActionsContainer()
        .markedStale(model.isStale)
        // The archived page wanted, once it is open, and again when the count moves.
        .task(id: ArchivedAsk(project: model.selectedProject, isOpen: showsArchived,
                              shown: archivedShown, count: archivedCount)) {
            guard showsArchived, let folder = model.selectedProject else { return }
            await model.loadArchivedAgents(in: folder, limit: archivedShown)
        }
        .refreshable { await model.catchUp() }
    }

    private func isFolded(_ fold: String) -> Bool {
        guard let folder = model.selectedProject else { return false }
        return folded.contains(FoldedGroups.name(fold, in: folder))
    }

    private func setFolded(_ fold: String, _ isFolded: Bool) {
        guard let folder = model.selectedProject else { return }
        folded.set(FoldedGroups.name(fold, in: folder), folded: isFolded)
    }

    /// The project's pinned sessions held and not archived, in their order (#180).
    private var pinnedAgents: [Agent] {
        model.pinnedSessions(in: model.selectedProject).compactMap { model.work.agent($0) }
            .filter { $0.state != .archived }
    }

    /// A group's sessions without the pinned, which are drawn in Pinned.
    private func unpinned(_ agents: [Agent]) -> [Agent] {
        let pinned = Set(model.pinnedSessions(in: model.selectedProject))
        return pinned.isEmpty ? agents : agents.filter { !pinned.contains($0.id) }
    }

    private var isEmpty: Bool {
        AgentGroup.allCases.allSatisfy { model.agents(group: $0).isEmpty }
    }

    private func matching(_ agents: [Agent]) -> [Agent] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return agents }
        let matcher = SessionLabelQuery(query)
        return agents.filter(matcher.matches)
    }

    private var hasMatches: Bool {
        AgentGroup.allCases.contains { !matching(model.agents(group: $0)).isEmpty }
    }

    /// The archived agents fetched so far — none until the section is opened.
    private var archived: [Agent] { model.agents(group: .archived) }

    /// How many there are, from the Mac's count rather than from what has been fetched.
    private var archivedCount: Int {
        max(model.selectedSummary?.counts[.archived] ?? 0, archived.count)
    }

    /// Out of the way until it is wanted, ten at a time, as on the Mac, and behind the
    /// same chevron. None of it is fetched until it is opened: archived agents outnumber
    /// the live ones many times over and are almost never read.
    @ViewBuilder
    private var archivedSection: some View {
        if archivedCount > 0 {
            if query.isEmpty {
                DisclosureHeading(title: "Archived", count: archivedCount, isOpen: $showsArchived)
            } else if !matching(archived).isEmpty {
                GroupHeading(title: "Archived", count: matching(archived).count)
            }
            if showsArchived || !query.isEmpty {
                ForEach(query.isEmpty ? Array(archived.prefix(archivedShown)) : matching(archived)) { agent in
                    AgentCard(agent: agent)
                }
                if query.isEmpty, archivedCount > archivedShown {
                    Button("Show more") { archivedShown += pageSize }
                        .appText(.reading)
                        .padding(.top, 4)
                }
            }
        }
        // What has been retired from here (051): the list's last line, or the only one
        // when nothing archived is left.
        if showsArchived || archivedCount == 0,
           let line = RetirementWords.retiredLine(model.selectedSummary?.retiredCount) {
            Text(line)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
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
///
/// Given `isOpen`, it folds what is under it (#181), with a chevron and its count.
struct SectionHeading: View {
    let title: String
    var count: Int?
    var isOpen: Binding<Bool>?

    var body: some View {
        if let isOpen {
            Button {
                withAnimation(.snappy(duration: 0.18)) { isOpen.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                        .appText(.fine)
                    Text(title)
                    if let count {
                        Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appText(.reading).fontWeight(.semibold)
            .padding(.top, 18)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isOpen.wrappedValue ? "Expanded" : "Collapsed")
        } else {
            Text(title)
                .appText(.reading).fontWeight(.semibold)
                .padding(.top, 18)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A `GroupHeading` that opens and closes what is under it, for what is put away.
struct DisclosureHeading: View {
    let title: String
    let count: Int
    /// How many under it are unread (#70), said folded or not (#181).
    var unread = 0
    /// Attention on a folded Needs you, so folding it never hides that somebody waits.
    var tint: StateTint = .none
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
                    .foregroundStyle(tint.style(or: .tertiary))
                if unread > 0 {
                    Text("· \(unread) unread")
                        .monospacedDigit()
                }
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
    /// How many under it nobody has opened since they finished (#70), as the Mac says it.
    var unread = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            if unread > 0 {
                Text("· \(unread) unread")
                    .monospacedDigit()
            }
        }
        .appText(.fine).fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.top, 14)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// When the Archived section fetches: opened, paged, or its count moved.
private struct ArchivedAsk: Equatable {
    var project: URL?
    var isOpen: Bool
    var shown: Int
    var count: Int
}

/// Which groups of a project's page are folded on this device (#181): a session group by
/// its name, or Workflows, each for one project. Groups start open, so only the folded
/// are kept.
struct FoldedGroups: RawRepresentable, Equatable {
    static let key = "projects.foldedGroups"
    private(set) var names: Set<String> = []

    init() {}

    init?(rawValue: String) {
        names = Set(rawValue.split(separator: "\n").map(String.init))
    }

    var rawValue: String { names.sorted().joined(separator: "\n") }

    static func name(_ fold: String, in folder: URL) -> String {
        "\(fold):\(Project.standardize(folder).path)"
    }

    func contains(_ name: String) -> Bool { names.contains(name) }

    mutating func set(_ name: String, folded: Bool) {
        if folded { names.insert(name) } else { names.remove(name) }
    }
}
