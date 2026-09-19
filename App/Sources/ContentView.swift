import AgentsKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var frame = SidebarFrame()
    @State private var sidebarStates = SidebarStates()
    /// Starting an agent is the detail pane, so "new" is "choose nothing".
    private var isStarting: Binding<Bool> {
        Binding(get: { model.selection == nil },
                set: { if $0 { model.selection = nil } })
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { window in
            NavigationSplitView {
                AgentListView(selection: $model.selection, isStarting: isStarting)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
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
