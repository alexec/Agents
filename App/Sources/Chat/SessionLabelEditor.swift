import AgentsKitCore
import SwiftUI

/// Session labels as one tag input beside the worktree, above the prompt: a comma adds one, Delete
/// takes away the one at the cursor (`LabelTagField`).
struct SessionLabelEditor: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        LabelTagField(labels: agent.labels,
                      suggestions: model.labelSuggestions(in: agent.projectFolder, on: agent.host),
                      add: { values in Task { await model.setLabels(on: agent.id, add: values) } },
                      remove: { value in Task { await model.setLabels(on: agent.id, remove: [value]) } })
            // Read again when this session's labels change, whoever changed them.
            .task(id: Ask(project: ProjectKey(host: agent.host, folder: agent.projectFolder),
                          labels: agent.labels.map(\.value))) {
                await model.loadLabelVocabulary(in: agent.projectFolder, on: agent.host)
            }
    }

    private struct Ask: Hashable {
        var project: ProjectKey
        var labels: [String]
    }
}
