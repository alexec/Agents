import AgentsKitCore
import SwiftUI

/// What one project has archived, where the chat would be (#495): sessions and
/// workflows. It used to be folds inside the project's fold in the sidebar; one row there
/// now opens this, so the sidebar is never more than two levels deep.
///
/// The same rows as the sidebar's, in a list whose selection is the window's: a click
/// opens the workflow's page or the session's chat, as it did from the fold.
struct ProjectWorkPage: View {
    @Environment(AppModel.self) private var model
    let page: AppModel.ProjectPage
    let project: ProjectKey

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Text("Archived")
                .appText(.title)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            List(selection: $model.sidebarItem) {
                archive
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(model.work.project(project)?.name ?? "")
    }

    private var held: [WorkflowSummary] { model.workflows(in: project.folder) }

    @ViewBuilder
    private var archive: some View {
        let sessions = model.work.agents(in: project, group: .archived)
        let flows = held.filter(\.isArchived)
        Section("Sessions") {
            if sessions.isEmpty {
                Text("No archived sessions").foregroundStyle(.secondary)
            }
            ForEach(sessions) { agent in
                SessionSidebarRow(agent: agent)
            }
        }
        // A page of them while the page is open, let go when it closes (#165).
        .task(id: project) { await model.loadArchived(in: project) }
        .onDisappear { model.letGoOfArchived(in: project) }
        if !flows.isEmpty {
            Section("Workflows") {
                ForEach(flows, id: \.id) { summary in
                    WorkflowListRow(summary: summary, project: project)
                }
            }
        }
    }
}
