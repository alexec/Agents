import AgentsKitCore
import SwiftUI

/// A session's title being edited (#751), and where: its sidebar row, or the toolbar.
struct Renaming: Equatable {
    var id: UUID
    var inToolbar: Bool = false
}

/// The title as a field, in place of the text (#751): Return keeps it, Escape or
/// leaving it puts the title back as it was. Emptied, the runtime names the session again.
struct RenameField: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var text: String
    @FocusState private var focused: Bool

    init(agent: Agent) {
        self.agent = agent
        _text = State(initialValue: agent.title ?? "")
    }

    var body: some View {
        TextField("Title", text: $text, prompt: Text(agent.titleFromRuntime ?? "Untitled"))
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { keep() }
            .onExitCommand { model.renaming = nil }
            .onChange(of: focused) { _, now in if !now { model.renaming = nil } }
            .onAppear { focused = true }
            .help("Return renames it; an empty title gives the runtime's back. Escape cancels.")
    }

    private func keep() {
        let id = agent.id
        let title = text
        model.renaming = nil
        // Return on the title as it was renames nothing, and leaves the runtime naming it.
        guard Agent.cleanedTitle(title) != agent.title else { return }
        Task { await model.rename(id, to: title) }
    }
}
