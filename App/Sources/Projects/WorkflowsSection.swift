import AgentsKit
import SwiftUI

/// A project's standing arrangements, under the agents working on it.
///
/// Below rather than above, because you come to a project page to see what is
/// happening, and workflows are what will happen. Putting them first would push what
/// needs you under the fold on any project with a few of them.
struct WorkflowsSection: View {
    @Environment(AppModel.self) private var model
    let folder: URL?
    @Binding var selection: UUID?

    private var workflows: [WorkflowSummary] { model.workflows(in: folder) }
    private var allPaused: Bool {
        !workflows.isEmpty && workflows.allSatisfy(\.isPaused)
    }

    var body: some View {
        if folder != nil {
            heading
            if workflows.isEmpty {
                empty
            } else {
                ForEach(workflows) { summary in
                    WorkflowRow(summary: summary, selection: $selection)
                }
            }
        }
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Text("Workflows")
            Text("\(workflows.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            if let folder, !workflows.isEmpty {
                // One switch for the lot. With approval happening when a workflow is
                // written, this is the only way to stop one that is misbehaving short
                // of deleting its file.
                Button(allPaused ? "Resume all" : "Pause all") {
                    Task { await model.setProjectWorkflowsPaused(folder, !allPaused) }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.top, 14)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }

    /// Names where the files live, because that is the one fact nobody can guess, and
    /// both routes to a first workflow.
    private var empty: some View {
        Text("""
            No workflows yet. A workflow is a prompt that runs itself — on a schedule, \
            or when an agent finishes. Ask an agent to set one up, or write one into \
            \(WorkflowFile.folderName).
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }
}
