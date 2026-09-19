import AgentsKit
import SwiftUI

/// An agent wants to add, change or remove a workflow, and is waiting on an answer.
///
/// Three decisions are in this one view, and each is the opposite of what the
/// surrounding code does for its own tools.
///
/// It leads with the trigger **in words**, from the same renderer the project-page row
/// uses, so the thing that was approved and the thing seen a week later cannot drift.
/// Not YAML, not a path, not a diff — none of which answer the only question being
/// asked, which is what will run and when.
///
/// It shows the prompt **in full**. Approving a workflow is approving what an agent
/// will be told, unattended, every weekday morning. Behind a disclosure, the safe
/// action would be the uninformed one.
///
/// And there is no *always allow*, deliberately, unlike every other permission in this
/// app: an agent with blanket approval to write workflows could write a workflow that
/// writes workflows.
struct WorkflowConfirmationView: View {
    @Environment(AppModel.self) private var model
    let confirmation: DaemonAPI.WorkflowConfirmation

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                Text(headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(Workflow.defaultName(for: confirmation.workflowID))
                        .font(.subheadline.weight(.semibold))

                    Text(confirmation.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    if !confirmation.prompt.isEmpty {
                        Divider()
                        Text(confirmation.prompt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                // True, and not what the decision turns on, so it sits at the bottom
                // and small.
                Text("\(WorkflowFile.folderName)/\(confirmation.workflowID).md")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Don't") { answer(false) }
                        .buttonStyle(.glass)
                    Button(confirmLabel) { answer(true) }
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 144)
    }

    private var agentName: String {
        model.agents.first { $0.id == confirmation.agentID }?.title ?? "An agent"
    }

    private var headline: String {
        switch confirmation.action {
        case .create: return "\(agentName) wants to add a workflow"
        case .update: return "\(agentName) wants to change a workflow"
        case .remove: return "\(agentName) wants to remove a workflow"
        }
    }

    private var confirmLabel: String {
        switch confirmation.action {
        case .create: return "Add it"
        case .update: return "Change it"
        case .remove: return "Remove it"
        }
    }

    private func answer(_ allow: Bool) {
        Task { await model.answerWorkflowConfirmation(confirmation, allow: allow) }
    }
}
