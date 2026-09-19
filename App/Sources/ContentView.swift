import AgentsKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var frame = SidebarFrame()
    @State private var sidebarStates = SidebarStates()
    @State private var webHolders = WebHolders()
    /// Starting an agent is the detail pane, so "new" is "choose nothing".
    private var isStarting: Binding<Bool> {
        Binding(get: { model.selection == nil },
                set: { if $0 { model.selection = nil } })
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { window in
            // Three columns: the folders, the agents in the chosen folder, and the
            // conversation. A project and an agent stay chosen at the same time, which
            // is what lets the panel be glanceable while work is in flight.
            NavigationSplitView {
                ProjectListView(selection: $model.selectedProject, isStarting: isStarting)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } content: {
                ProjectAgentsView(selection: $model.selection, isStarting: isStarting)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 460)
            } detail: {
                HStack(spacing: 0) {
                    // One view either way: a new chat turns into the chat rather than
                    // being replaced by it.
                    ChatView()
                        .frame(maxWidth: .infinity)
                    // Closed means absent, not hidden. Nothing of the sidebar runs
                    // while it is shut: no folder watch, no web view, no shell
                    // attached (FR-006, SC-009).
                    if frame.isOpen, SidebarFrame.fits(inWindowOf: window.size.width) {
                        SidebarView(windowWidth: window.size.width)
                            .transition(.move(edge: .trailing))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SidebarToggle(windowWidth: window.size.width)
                    }
                }
            }
        }
        .environment(frame)
        .environment(sidebarStates)
        .environment(webHolders)
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
