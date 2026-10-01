import AgentsKit
import SwiftUI

/// Session labels as one tag input over the chat: type and a comma adds one, Delete
/// takes away the one at the cursor (`LabelTagField`).
struct SessionLabelEditor: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        LabelTagField(labels: agent.labels,
                      suggestions: model.labelSuggestions(in: agent.projectFolder, on: agent.host),
                      add: { values in Task { await model.setLabels(on: agent.id, add: values) } },
                      remove: { value in Task { await model.setLabels(on: agent.id, remove: [value]) } })
    }
}
