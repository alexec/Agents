import AgentsKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Starting an agent is the detail pane, so "new" is "choose nothing".
    private var isStarting: Binding<Bool> {
        Binding(get: { model.selection == nil },
                set: { if $0 { model.selection = nil } })
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            AgentListView(selection: $model.selection, isStarting: isStarting)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            // One view either way: a new chat turns into the chat rather than
            // being replaced by it.
            ChatView()
        }
        .task { await model.connect() }
        .alert("That did not work",
               isPresented: Binding(get: { model.problem != nil },
                                    set: { if !$0 { model.dismissProblem() } })) {
            Button("OK") { model.dismissProblem() }
        } message: {
            Text(model.problem ?? "")
        }
    }
}
