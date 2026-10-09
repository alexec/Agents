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

    var body: some View {
        let sessions = model.work.agents(in: project, group: .archived)
        let flows = model.work.workflows(in: project.folder).filter(\.isArchived)
        List {
            Section("Sessions") {
                if sessions.isEmpty {
                    Text("No archived sessions").foregroundStyle(.secondary)
                }
                ForEach(sessions) { agent in
                    NavigationLink(value: RemoteRoute.agent(agent.id)) {
                        SidebarSessionRow(agent: agent)
                    }
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
        .navigationTitle("Archived")
        // A page of them while the page is open, let go when it closes (#165): not when a
        // chat is only pushed over it.
        .task(id: project) { await model.loadArchived(in: project.folder) }
        .onDisappear {
            if !model.openArchive || model.selectedProject != project.folder {
                model.letGoOfArchived(in: project.folder)
            }
        }
    }
}
