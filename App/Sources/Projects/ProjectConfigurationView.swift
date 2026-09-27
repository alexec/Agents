import AgentsKit
import SwiftUI

/// Settings carried by one project. The project overview stays focused on its work;
/// skills are managed here, in the same folder that its agents read.
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

                if model.selectedProjectKey?.host == .mac {
                    ProjectSkillsSection(folder: folder)
                } else {
                    SectionHeading(title: "Skills")
                    Text("Project skills on servers are not available yet.")
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
