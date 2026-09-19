import AgentsKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var frame = SidebarFrame()
    @State private var sidebarStates = SidebarStates()
    @State private var webHolders = WebHolders()
    /// Which columns are showing.
    ///
    /// Picking a project puts the list of projects away: you chose one, so the screen
    /// belongs to it now. The sidebar button brings it back when you want another.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        GeometryReader { window in
            // Three columns: the folders, the project itself, and the conversation.
            NavigationSplitView(columnVisibility: $columns) {
                ProjectListView(selection: $model.selectedProject)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } content: {
                ProjectAgentsView(selection: $model.selection)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
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
        // Choosing a project is the end of needing the list of them.
        .onChange(of: model.selectedProject) { _, folder in
            guard folder != nil else { return }
            withAnimation { columns = .doubleColumn }
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
