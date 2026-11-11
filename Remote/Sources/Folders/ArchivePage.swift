import AgentsKitCore
import SwiftUI

/// What one folder has archived (#498), the window's `ArchivedSessionsPage`: sessions and
/// workflows. They used to be folds inside the folder's fold in the sidebar; one row
/// there now opens this, so the sidebar is never more than two levels deep (#495).
///
/// The sidebar's own rows, each pushing its chat or page over this one, with their
/// swipes and long press: Unarchive among them.
struct ArchivePage: View {
    @Environment(RemoteModel.self) private var model
    let folder: FolderKey
    /// Whether the host answered the ask for this folder's archive: nil while it is on
    /// its way, so an empty list is not "none" before it is known (#664).
    @State private var answered: Bool?

    var body: some View {
        let sessions = model.work.agents(in: folder, group: .archived)
        let flows = model.work.workflows(in: folder.folder).filter(\.isArchived)
        let summary = model.work.folder(folder)
        let total = max(summary?.counts[.archived] ?? 0, sessions.count)
        List {
            Section("Sessions") {
                ForEach(sessions) { agent in
                    NavigationLink(value: RemoteRoute.agent(agent.id)) {
                        SidebarSessionRow(agent: agent)
                    }
                }
                if let note = note(shown: sessions.count, total: total) {
                    Text(note).foregroundStyle(.secondary)
                }
            }
            if !flows.isEmpty {
                Section("Workflows") {
                    ForEach(flows) { summary in
                        NavigationLink(value: RemoteRoute.workflow(summary.id)) {
                            SidebarWorkflowRow(summary: summary, folder: folder)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        // Named for the folder, as the window's and the web's are (#664).
        .navigationTitle(summary.map { "\($0.name): Archived" } ?? "Archived")
        // A page of them while the page is open, let go when it closes (#165): not when a
        // chat is only pushed over it.
        .task(id: folder) {
            answered = nil
            answered = await model.loadArchived(in: folder)
        }
        .onDisappear {
            if !model.openArchive || model.selectedKey != folder {
                model.letGoOfArchived(in: folder.folder)
            }
        }
    }

    /// The line under the sessions, in the words the Mac's Archived Sessions page uses (#4448),
    /// until the Remote has the two pages (#4452).
    private func note(shown: Int, total: Int) -> String? {
        switch ArchivedPage.state(held: shown, filtering: false, answered: answered,
                                  hostOffline: model.isStale(on: folder.host)) {
        case .loading: ArchivedPage.loading
        case .hostSilent: ArchivedPage.staleStrip
        case .empty, .noMatch: ArchivedPage.Sessions.emptyTitle
        case .rows: ArchivedPage.hasMore(shown: shown, total: total) ? ArchivedPage.footer(shown: shown, total: total) : nil
        }
    }
}
