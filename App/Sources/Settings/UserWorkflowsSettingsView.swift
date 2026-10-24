import AgentsKitCore
import SwiftUI

/// Settings ▸ Workflows: the user's files in ~/.agents/workflows.
struct UserWorkflowsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    @State private var content = ""
    @State private var newID = ""
    @State private var problem: String?
    @State private var deletePrompt = false
    @State private var busy = false

    private var workflows: [WorkflowSummary] { model.userWorkflows.sorted { $0.workflow.name.localizedCaseInsensitiveCompare($1.workflow.name) == .orderedAscending } }
    private var selected: WorkflowSummary? { workflows.first { $0.workflow.workflowID == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    TextField("New workflow ID", text: $newID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { add() }
                        .disabled(busy || newID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                List(selection: $selectedID) {
                    ForEach(workflows, id: \.workflow.workflowID) { item in
                        Text(item.workflow.name).tag(Optional(item.workflow.workflowID))
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 245)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.refreshWorkflows(); selectFirst() }
        .onChange(of: selectedID) { _, id in
            content = workflows.first { $0.workflow.workflowID == id }?.content ?? ""
            problem = nil
        }
        .confirmationDialog("Delete this workflow?", isPresented: $deletePrompt, titleVisibility: .visible) {
            Button("Delete Workflow", role: .destructive) { delete() }
        } message: {
            Text("The file will be removed from your workflows folder.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.workflow.name).appText(.title).fontWeight(.semibold)
                        Text("~/.agents/workflows/\(selected.workflow.workflowID).md")
                            .appText(.code).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete") { deletePrompt = true }.disabled(busy)
                }
                TextEditor(text: $content)
                    .appText(.code)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Workflow file")
                HStack {
                    if let problem { Text(problem).appText(.fine).tinted(.failure).lineLimit(2) }
                    Spacer()
                    Button("Save") { save(selected.workflow.workflowID) }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(busy || content == (selected.content ?? ""))
                }
            }
            .padding(18)
        } else {
            ContentUnavailableView("No user workflows", systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                                   description: Text("Add a workflow to create a file in ~/.agents/workflows."))
        }
    }

    private func selectFirst() {
        if selectedID == nil { selectedID = workflows.first?.workflow.workflowID }
    }

    private func add() {
        let id = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard !workflows.contains(where: { $0.workflow.workflowID == id }) else {
            problem = "A workflow with that ID already exists. Choose another ID."
            return
        }
        let text = "---\non: manual\n---\n\nWrite what the agent should do.\n"
        Task {
            busy = true
            problem = await model.writeUserWorkflow(id: id, content: text)
            busy = false
            if problem == nil { newID = ""; selectedID = id; content = text }
        }
    }

    private func save(_ id: String) {
        Task {
            busy = true
            problem = await model.writeUserWorkflow(id: id, content: content)
            busy = false
        }
    }

    private func delete() {
        guard let selected else { return }
        Task {
            busy = true
            _ = await model.deleteWorkflow(selected)
            await model.refreshWorkflows()
            selectedID = workflows.first(where: { $0.workflow.workflowID != selected.workflow.workflowID })?.workflow.workflowID
            busy = false
        }
    }
}
