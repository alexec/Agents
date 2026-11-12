import AgentsKitCore
import SwiftUI

/// A folder's archived sessions, where the chat would be (#495, #4448), from its Archived
/// Sessions row in the sidebar: the title in the title bar, a filter in the toolbar, the
/// sidebar's own rows in a section per day they were archived, and Load more at the foot.
///
/// The list's selection is the window's: a click opens the session's chat, and its row's
/// swipe, menu and keyboard are the sidebar's (Unarchive among them).
struct ArchivedSessionsPage: View {
    @Environment(AppModel.self) private var model
    /// In a folder's own window, its pick and how it opens one (#1090).
    @Environment(\.windowOpen) private var windowOpen
    @Environment(\.windowPick) private var windowPick
    let folder: FolderKey
    /// Whether the host answered the ask for this folder's archive: nil while it is on
    /// its way, so an empty list is not "none" before it is known (#664).
    @State private var answered: Bool?
    /// Whether the host answered the ask for the filter's words, nil while it is on its way.
    @State private var searched: Bool?
    @State private var filter = ""
    @State private var loadingMore = false

    private var words: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let held = model.work.agents(in: folder, group: .archived)
        let shown = words.isEmpty ? held : held.filter(SessionLabelQuery(words).matches)
        let state = ArchivedPage.state(held: shown.count, filtering: !words.isEmpty,
                                       answered: words.isEmpty ? answered : searched,
                                       hostOffline: model.hostUnreachable(folder.host))
        VStack(spacing: 0) {
            switch state {
            case .loading:
                ArchivedPlaceholderRows()
            case .hostSilent:
                ArchivedStaleStrip().frame(maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(ArchivedPage.Sessions.emptyTitle, icon: ArchivedPage.Sessions.systemImage,
                                       description: Text(ArchivedPage.Sessions.emptyLine))
            case .noMatch:
                ArchivedNoMatch(title: ArchivedPage.Sessions.noMatch) { filter = "" }
            case .rows(let stale):
                if stale { ArchivedStaleStrip() }
                list(shown, held: held.count).opacity(stale ? 0.55 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(ArchivedPage.Sessions.title)
        .navigationSubtitle(model.work.folder(folder)?.name ?? "")
        .searchable(text: $filter, prompt: ArchivedPage.filterPrompt)
        // A page of them while the page is open, let go when it closes (#165).
        .task(id: folder) {
            answered = nil
            answered = await model.loadArchived(in: folder)
        }
        // The host too, for the words, so one older than the page held is found (#4448).
        .task(id: words) {
            guard !words.isEmpty else { return }
            searched = nil
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searched = await model.searchArchived(in: folder, words: words)
        }
        .onDisappear { model.letGoOfArchived(in: folder) }
    }

    private func list(_ agents: [Agent], held: Int) -> some View {
        @Bindable var model = model
        let total = max(model.work.folder(folder)?.counts[.archived] ?? 0, held)
        return List(selection: windowOpen.map { open in
            Binding(get: { windowPick }, set: { if let item = $0 { open(item) } })
        } ?? $model.sidebarItem) {
            ForEach(ArchivedPage.days(agents)) { day in
                Section(day.title) {
                    ForEach(day.agents) { agent in
                        SessionSidebarRow(agent: agent, showsArchivedTime: true)
                    }
                }
            }
            if words.isEmpty {
                ArchivedFooter(words: ArchivedPage.footer(shown: held, total: total),
                               loadingMore: loadingMore,
                               loadMore: ArchivedPage.hasMore(shown: held, total: total) ? { loadMore(held: held) } : nil)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func loadMore(held: Int) {
        guard !loadingMore else { return }
        loadingMore = true
        Task {
            await model.loadArchived(in: folder, limit: ArchivedPage.nextLimit(held: held))
            loadingMore = false
        }
    }
}

/// A folder's archived workflows (#4448), from its Archived Workflows row: the same frame
/// as Archived Sessions, the sidebar's workflow rows by name, no day groups (a workflow has
/// no archive date) and no Load more (a folder's workflows are all held). A click opens the
/// workflow's page, where Unarchive is.
struct ArchivedWorkflowsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowOpen) private var windowOpen
    @Environment(\.windowPick) private var windowPick
    let folder: FolderKey
    @State private var filter = ""

    private var words: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var model = model
        let held = model.workflows(in: folder.folder).filter(\.isArchived)
            .sorted { $0.workflow.name.localizedStandardCompare($1.workflow.name) == .orderedAscending }
        let shown = words.isEmpty ? held : held.filter(SessionLabelQuery(words).matches)
        let state = ArchivedPage.state(held: shown.count, filtering: !words.isEmpty, answered: true,
                                       hostOffline: model.hostUnreachable(folder.host))
        VStack(spacing: 0) {
            switch state {
            case .loading:
                ArchivedPlaceholderRows()
            case .hostSilent:
                ArchivedStaleStrip().frame(maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(ArchivedPage.Workflows.emptyTitle, icon: ArchivedPage.Workflows.systemImage,
                                       description: Text(ArchivedPage.Workflows.emptyLine))
            case .noMatch:
                ArchivedNoMatch(title: ArchivedPage.Workflows.noMatch) { filter = "" }
            case .rows(let stale):
                if stale { ArchivedStaleStrip() }
                List(selection: windowOpen.map { open in
                    Binding(get: { windowPick }, set: { if let item = $0 { open(item) } })
                } ?? $model.sidebarItem) {
                    ForEach(shown, id: \.id) { summary in
                        WorkflowListRow(summary: summary, folder: folder)
                    }
                    if words.isEmpty {
                        ArchivedFooter(words: ArchivedPage.workflowCount(held.count), loadingMore: false, loadMore: nil)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .opacity(stale ? 0.55 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(ArchivedPage.Workflows.title)
        .navigationSubtitle(model.work.folder(folder)?.name ?? "")
        .searchable(text: $filter, prompt: ArchivedPage.filterPrompt)
    }
}

/// The foot of an Archived page: how many, and Load more while the host has more, a
/// spinner and "Loading more…" while it is asked.
private struct ArchivedFooter: View {
    let words: String
    let loadingMore: Bool
    let loadMore: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if loadingMore {
                ProgressView().controlSize(.small)
                Text(ArchivedPage.loadingMore)
            } else {
                Text(words)
                if let loadMore {
                    Text("·")
                    Button("Load more", action: loadMore)
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .foregroundStyle(.secondary)
        .padding(.top, 12)
        .selectionDisabled()
        .listRowSeparator(.hidden)
    }
}

/// Its machine is not answering: over the rows last read, or alone with none.
private struct ArchivedStaleStrip: View {
    var body: some View {
        PaneBanner(tone: .neutral, symbol: MessageTone.offlineSymbol, ArchivedPage.staleStrip)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }
}

/// A filter that matched none: the words stay in the field, and Clear empties it.
private struct ArchivedNoMatch: View {
    let title: String
    let clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, icon: "magnifyingglass")
        } actions: {
            Button("Clear", action: clear)
        }
    }
}

/// Rows the shape of the real ones while the host is asked (#664): never "none" before
/// it has said.
private struct ArchivedPlaceholderRows: View {
    var body: some View {
        List {
            Section("Today") {
                ForEach(0..<6, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Image(icon: ArchivedPage.Sessions.systemImage)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(index.isMultiple(of: 2) ? "An archived session's title" : "A shorter title")
                            Text("The last line it said, in grey").appText(.fine)
                        }
                        Spacer()
                        Text("2 h ago").appText(.fine)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .redacted(reason: .placeholder)
        .phaseAnimator([1.0, 0.45]) { content, opacity in
            content.opacity(opacity)
        } animation: { _ in .easeInOut(duration: 0.9) }
        .allowsHitTesting(false)
        .accessibilityLabel(ArchivedPage.loading)
    }
}
