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

    /// The agent being read, as a path of nothing or one.
    ///
    /// A chat is somewhere you go from the project and come back out of, rather than a
    /// column sitting beside it, so it is a push and the back button is the way home.
    private var openAgent: Binding<[UUID]> {
        Binding(get: { model.selection.map { [$0] } ?? [] },
                set: { model.selection = $0.last })
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { window in
            // Two columns: the projects, and the project.
            NavigationSplitView(columnVisibility: $columns) {
                ProjectListView(selection: $model.selectedProject)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } detail: {
                NavigationStack(path: openAgent) {
                    ProjectAgentsView(selection: $model.selection)
                        .navigationDestination(for: UUID.self) { _ in
                            HStack(spacing: 0) {
                                ChatView()
                                    .frame(maxWidth: .infinity)
                                // Closed means absent, not hidden. Nothing of the
                                // sidebar runs while it is shut: no folder watch, no
                                // web view, no shell attached (FR-006, SC-009).
                                if frame.isOpen,
                                   SidebarFrame.fits(inWindowOf: window.size.width) {
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
            }
        }
        .environment(frame)
        .environment(sidebarStates)
        .environment(webHolders)
        // Choosing a project is the end of needing the list of them.
        .onChange(of: model.selectedProject) { _, folder in
            guard folder != nil else { return }
            withAnimation { columns = .detailOnly }
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
