import AgentsKit
import AppKit
import SwiftUI

/// A project's standing arrangements, under the project page's Workflows tab.
struct WorkflowsSection: View {
    @Environment(AppModel.self) private var model
    let folder: URL?
    @Binding var selection: UUID?

    /// Put away by the person, and kept out of the count, the pause-all switch and
    /// the list itself. An agent may write a workflow without asking now, so this is
    /// the reply: it goes under a heading you have to open, and it never runs.
    @AppStorage("showsArchivedWorkflows") private var showsArchived = false

    private var workflows: [WorkflowSummary] {
        model.workflows(in: folder).filter { !$0.isArchived }
    }
    private var archived: [WorkflowSummary] {
        model.workflows(in: folder).filter(\.isArchived)
    }
    /// The ceiling worth naming, if any: the one something here has actually hit,
    /// otherwise this project's own once it is full.
    private var limitToName: WorkflowLimit? {
        if let hit = workflows.compactMap(\.overLimit).first { return hit }
        return workflows.count >= WorkflowLimit.project.allowed ? .project : nil
    }

    var body: some View {
        if folder != nil {
            if workflows.isEmpty {
                if archived.isEmpty { empty } else { allArchived }
            } else {
                ForEach(workflows) { summary in
                    // Put away the way an agent's card is: two fingers to the left.
                    WorkflowRow(summary: summary, selection: $selection)
                        .swipeToArchive { await model.setWorkflowArchived(summary, true) }
                }
            }
            if let limit = limitToName { limitNote(limit) }
            if !archived.isEmpty {
                archivedHeading
                if showsArchived {
                    ForEach(archived) { summary in
                        WorkflowRow(summary: summary, selection: $selection)
                    }
                }
            }
        }
    }

    /// Why the next one an agent is asked for will be refused, said before it is
    /// rather than after. A ceiling nobody can see is a ceiling somebody walks into.
    private func limitNote(_ limit: WorkflowLimit) -> some View {
        Text(workflows.contains { $0.overLimit != nil }
             ? """
                \(limit.sentence). The ones past that are listed and will not run until \
                something is archived or removed.
                """
             : """
                \(limit.sentence) — as many as it may. Archive one to make room for another.
                """)
            .appText(.fine)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .padding(.leading, 2)
    }

    /// The put-away ones, behind one tap. Shown at all because archiving is not
    /// deleting: the files are still in the project, and a page that pretended
    /// otherwise would leave somebody hunting for a workflow it had hidden.
    private var archivedHeading: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { showsArchived.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsArchived ? "chevron.down" : "chevron.right")
                    .appText(.fine)
                Text("Archived")
                Text("\(archived.count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appText(.fine).fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.top, 10)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }

    /// Everything this project has is put away. Said rather than left as a gap, so the
    /// page does not read as though the workflows were lost.
    private var allArchived: some View {
        Text("Nothing running. This project's workflows are all archived.")
            .appText(.reading)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No workflows")
                .appText(.reading)
                .foregroundStyle(.secondary)
            Text("Ask an agent to add one, or put a Markdown file in .agents/workflows.")
                .appText(.fine)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("How to set up a workflow") {
                NSWorkspace.shared.open(Self.workflowHelpURL)
            }
            .buttonStyle(.link)
            .appText(.fine)
        }
        .padding(.vertical, 6)
    }

    private static let workflowHelpURL =
        URL(string: "https://alexec.github.io/Agents/how-to/set-up-a-workflow/")!
}
