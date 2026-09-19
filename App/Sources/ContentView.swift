import AgentsKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isStarting = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            AgentListView(selection: $model.selection, isStarting: $isStarting)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            if let agent = model.selectedAgent {
                TranscriptView(agent: agent)
            } else {
                ContentUnavailableView {
                    Label("No agent chosen", systemImage: "square.split.2x1")
                } description: {
                    Text("Pick one on the left, or start a new one.")
                }
            }
        }
        .task { await model.connect() }
        .sheet(isPresented: $isStarting) {
            StartAgentView()
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.problem != nil },
                                    set: { if !$0 { model.dismissProblem() } })) {
            Button("OK") { model.dismissProblem() }
        } message: {
            Text(model.problem ?? "")
        }
    }
}
