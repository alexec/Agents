import AgentsKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var frame = SidebarFrame()
    @State private var sidebarStates = SidebarStates()
    @State private var webHolders = WebHolders()
    /// Which columns are showing. The projects stay put: moving between them is the
    /// ordinary thing to do here, and a list that hides itself when used is a list you
    /// have to keep fetching back.
    @State private var columns = NavigationSplitViewVisibility.all

    /// The agent being read, as a path of nothing or one.
    ///
    /// A chat is somewhere you go from the project and come back out of, rather than a
    /// column sitting beside it, so it is a push and the back button is the way home.
    private var openAgent: Binding<[UUID]> {
        Binding(get: { model.selection.map { [$0] } ?? [] },
                set: { model.selection = $0.last })
    }

    /// Put the file the selected agent asked about in front of the user.
    ///
    /// Only for the agent on screen. An agent working in another conversation keeps
    /// its request until that conversation is opened, rather than pulling the window
    /// away from what is being read: the file is the agent's suggestion, and the
    /// window is still the user's.
    private func showWhatWasAskedFor() {
        guard let agentID = model.selection,
              let file = model.takeFileToShow(for: agentID) else { return }
        let state = sidebarStates.state(for: agentID)
        state.folder = file.url.deletingLastPathComponent()
        state.openFile = file.url
        state.openLine = file.line
        frame.pane = .files
        frame.isOpen = true
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
        .task { await model.connect() }
        // An agent asking to be looked at is the one thing that opens this column by
        // itself. Here rather than in the sidebar, because the sidebar may be shut,
        // and shut means gone: there would be nothing listening.
        .onChange(of: model.filesToShow) { showWhatWasAskedFor() }
        .onChange(of: model.selection) { showWhatWasAskedFor() }
        .alert("That did not work",
               isPresented: Binding(get: { model.problem != nil },
                                    set: { if !$0 { model.dismissProblem() } })) {
            Button("OK") { model.dismissProblem() }
        } message: {
            Text(model.problem ?? "")
        }
    }
}
