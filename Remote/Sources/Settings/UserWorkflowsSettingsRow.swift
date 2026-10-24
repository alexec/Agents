import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines ▸ Workflows: files in the person's workflow folder.
struct UserWorkflowsSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        SettingsPageLink("Workflows", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
            UserWorkflowsSettingsSection()
        }
    }
}

private struct UserWorkflowsSettingsSection: View {
    @Environment(RemoteModel.self) private var model
    @State private var newID = ""
    @State private var problem: String?

    var body: some View {
        Section {
            HStack {
                TextField("New workflow ID", text: $newID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") { add() }
                    .disabled(newID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(model.userWorkflows, id: \.workflow.workflowID) { summary in
                NavigationLink {
                    UserWorkflowEditor(summary: summary)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.workflow.name)
                        Text("~/.agents/workflows/\(summary.workflow.workflowID).md")
                            .appText(.fine).foregroundStyle(.secondary)
                    }
                }
            }
            if let problem { Text(problem).appText(.fine).tinted(.failure) }
        } header: {
            Text("Your workflows")
        } footer: {
            Text("These files are shared with your machines.")
        }
        .task { await model.refreshWorkflows() }
    }

    private func add() {
        let id = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard !model.userWorkflows.contains(where: { $0.workflow.workflowID == id }) else {
            problem = "A workflow with that ID already exists. Choose another ID."
            return
        }
        Task {
            let text = "---\non: manual\n---\n\nWrite what the agent should do.\n"
            problem = await model.writeUserWorkflow(id: id, content: text)
            if problem == nil { newID = "" }
        }
    }
}

private struct UserWorkflowEditor: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let summary: WorkflowSummary
    @State private var content: String
    @State private var problem: String?
    @State private var deletePrompt = false

    init(summary: WorkflowSummary) {
        self.summary = summary
        _content = State(initialValue: summary.content ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $content)
                    .appText(.code)
                    .frame(minHeight: 280)
                if let problem { Text(problem).appText(.fine).tinted(.failure) }
            } header: {
                Text("~/.agents/workflows/\(summary.workflow.workflowID).md")
            }
            Section {
                Button("Save") { save() }
                    .disabled(content == (summary.content ?? ""))
                Button("Delete Workflow", role: .destructive) { deletePrompt = true }
            }
        }
        .navigationTitle(summary.workflow.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this workflow?", isPresented: $deletePrompt, titleVisibility: .visible) {
            Button("Delete Workflow", role: .destructive) { delete() }
        }
    }

    private func save() {
        Task { problem = await model.writeUserWorkflow(id: summary.workflow.workflowID, content: content) }
    }

    private func delete() {
        Task {
            if await model.deleteWorkflow(summary) { dismiss() }
        }
    }
}
