import AgentsKitCore
import SwiftUI

/// What one project has archived (#498), the window's `ProjectWorkPage`: sessions and
/// workflows. They used to be folds inside the project's fold in the sidebar; one row
/// there now opens this, so the sidebar is never more than two levels deep (#495).
///
/// The sidebar's own rows, each pushing its chat or page over this one, with their
/// swipes and long press: Bring Back among them.
struct ArchivePage: View {
    @Environment(RemoteModel.self) private var model
    let project: ProjectKey
    /// Whether the host answered the ask for this project's archive: nil while it is on
    /// its way, so an empty list is not "none" before it is known (#664).
    @State private var answered: Bool?

    var body: some View {
        let sessions = model.work.agents(in: project, group: .archived)
        let flows = model.work.workflows(in: project.folder).filter(\.isArchived)
        let summary = model.work.project(project)
        let total = max(summary?.counts[.archived] ?? 0, sessions.count)
        List {
            Section("Sessions") {
                ForEach(sessions) { agent in
                    NavigationLink(value: RemoteRoute.agent(agent.id)) {
                        SidebarSessionRow(agent: agent)
                    }
                }
                if let note = ArchivedSessionsNote.note(shown: sessions.count, total: total, answered: answered,
                                                        hostOffline: model.isStale(on: project.host)) {
                    Text(note.text).foregroundStyle(.secondary)
                }
            }
            if !flows.isEmpty {
                Section("Workflows") {
                    ForEach(flows) { summary in
                        NavigationLink(value: RemoteRoute.workflow(summary.id)) {
                            SidebarWorkflowRow(summary: summary, project: project)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        // Named for the project, as the window's and the web's are (#664).
        .navigationTitle(summary.map { "\($0.name): Archived" } ?? "Archived")
        // A page of them while the page is open, let go when it closes (#165): not when a
        // chat is only pushed over it.
        .task(id: project) {
            answered = nil
            answered = await model.loadArchived(in: project)
        }
        .onDisappear {
            if !model.openArchive || model.selectedProject != project.folder {
                model.letGoOfArchived(in: project.folder)
            }
        }
    }
}
