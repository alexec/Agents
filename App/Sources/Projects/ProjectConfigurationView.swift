import AgentsKit
import SwiftUI

/// Settings carried by one project. The project overview stays focused on its work;
/// skills are managed here, in the same folder that its agents read, and the worktrees
/// the app has made in it.
struct ProjectConfigurationView: View {
    @Environment(AppModel.self) private var model
    let folder: URL?
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: close) {
                    Label("Project", systemImage: "chevron.left")
                }
                .buttonStyle(.paper)
                .padding(.bottom, 20)

                Text("Configuration")
                    .appText(.title).fontWeight(.semibold)
                Text(model.selectedProjectSummary?.name ?? "Project")
                    .appText(.supporting).foregroundStyle(.secondary)

                if let folder, model.selectedProjectKey?.host == .mac {
                    AgentsSetupView(place: .project(folder))
                        .padding(.top, 8)
                    // Worktrees the app made here, which outlive the agents in them (030).
                    SectionHeading(title: "Worktrees")
                    WorktreesSection(folder: folder)
                } else {
                    SectionHeading(title: "Configuration")
                    Text("Project configuration on a server is not available yet.")
                        .appText(.supporting).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .chatColumn()
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .navigationTitle("Configuration — \(model.selectedProjectSummary?.name ?? "Project")")
    }
}
