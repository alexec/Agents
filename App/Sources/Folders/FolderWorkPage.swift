import AgentsKitCore
import SwiftUI

/// What one folder has archived, where the chat would be (#495): sessions and
/// workflows. It used to be folds inside the folder's fold in the sidebar; one row there
/// now opens this, so the sidebar is never more than two levels deep.
///
/// The same rows as the sidebar's, in a list whose selection is the window's: a click
/// opens the workflow's page or the session's chat, as it did from the fold.
struct FolderWorkPage: View {
    @Environment(AppModel.self) private var model
    /// In a folder's own window, its pick and how it opens one (#1090).
    @Environment(\.windowOpen) private var windowOpen
    @Environment(\.windowPick) private var windowPick
    let page: AppModel.FolderPage
    let folder: FolderKey
    /// Whether the host answered the ask for this folder's archive: nil while it is on
    /// its way, so an empty list is not "none" before it is known (#664).
    @State private var answered: Bool?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Text("Archived")
                .appText(.title)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            List(selection: windowOpen.map { open in
                Binding(get: { windowPick }, set: { if let item = $0 { open(item) } })
            } ?? $model.sidebarItem) {
                archive
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(model.work.folder(folder)?.name ?? "")
    }

    private var held: [WorkflowSummary] { model.workflows(in: folder.folder) }

    @ViewBuilder
    private var archive: some View {
        let sessions = model.work.agents(in: folder, group: .archived)
        let flows = held.filter(\.isArchived)
        let total = max(model.work.folder(folder)?.counts[.archived] ?? 0, sessions.count)
        Section("Sessions") {
            ForEach(sessions) { agent in
                SessionSidebarRow(agent: agent)
            }
            if let note = ArchivedSessionsNote.note(shown: sessions.count, total: total, answered: answered,
                                                    hostOffline: model.hostUnreachable(folder.host)) {
                Text(note.text).foregroundStyle(.secondary)
            }
        }
        // A page of them while the page is open, let go when it closes (#165).
        .task(id: folder) {
            answered = nil
            answered = await model.loadArchived(in: folder)
        }
        .onDisappear { model.letGoOfArchived(in: folder) }
        if !flows.isEmpty {
            Section("Workflows") {
                ForEach(flows, id: \.id) { summary in
                    WorkflowListRow(summary: summary, folder: folder)
                }
            }
        }
    }
}
