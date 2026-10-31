import AgentsKitCore
import SwiftUI

/// A session's title being edited (#751), and where: its sidebar row, or the toolbar of
/// the window it is open in (#1452). A session can be open in more than one window at
/// once, and only the one the field is for shows it.
struct Renaming: Equatable {
    var id: UUID
    var place: Place = .row

    enum Place: Equatable {
        /// Its row in a sidebar.
        case row
        /// The main window's toolbar, over its chat.
        case mainWindow
        /// A folder's own window's toolbar (#1089).
        case folderWindow(FolderKey)
        /// The session's own window's toolbar (#826).
        case ownWindow
    }
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

/// A toolbar's Rename button, with the title's field in a popover under it (#751): the
/// main window's, a folder's own window's and a session's own window's, each with its
/// own place, so Session ▸ Rename… opens it in the window in front (#1452).
struct RenameButton: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let place: Renaming.Place

    private var renaming: Renaming { Renaming(id: agent.id, place: place) }

    var body: some View {
        Button {
            model.renaming = renaming
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(agent.state == .archived)
        .help("Give this session a title of your own, which the runtime's no longer replaces")
        .popover(isPresented: Binding(
            get: { model.renaming == renaming },
            set: { if !$0, model.renaming == renaming { model.renaming = nil } }),
                 arrowEdge: .bottom) {
            RenameField(agent: agent)
                .appText(.reading)
                .frame(width: 320)
                .padding(10)
        }
    }
}
