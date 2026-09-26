import AgentsKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// The app's, so the menu bar can reach them too. Passed in rather than set on the
    /// scene's content: see the note in `AgentsApp`.
    let requests: WindowRequests
    let frame: SidebarFrame
    @State private var sidebarStates = SidebarStates()
    @State private var webHolders = WebHolders()
    /// Which columns are showing. The projects stay put: moving between them is the
    /// ordinary thing to do here, and a list that hides itself when used is a list you
    /// have to keep fetching back.
    @State private var columns = NavigationSplitViewVisibility.all

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
        if !frame.isOpen { frame.open() }
    }

    /// A conversation and, when it is open and there is room, the sidebar beside it.
    private func chat(inWindowOf width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ChatView()
                .frame(maxWidth: .infinity)
            // Closed means absent, not hidden. Nothing of the sidebar runs while it is
            // shut: no folder watch, no web view, no shell attached (FR-006, SC-009).
            if frame.isOpen, SidebarFrame.fits(inWindowOf: width) {
                SidebarView(windowWidth: width)
                    .transition(.move(edge: .trailing))
            }
        }
        .paperGround()
        // What the chat does not need is how wide the sidebar opens (`SidebarFrame.open`).
        .onGeometryChange(for: Double.self) { $0.size.width } action: { frame.paneWidth = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SidebarToggle(windowWidth: width)
            }
        }
    }

    /// What the right-hand column shows: a page about all the work, a workflow, the
    /// chat picked in the middle column, or — with nothing picked — the project itself.
    @ViewBuilder
    private func detail(inPaneOf width: CGFloat) -> some View {
        if model.showsEvents {
            EventsView().paperGround()
        } else if model.showsResources {
            ResourcesView().paperGround()
        } else if model.showsSpending {
            SpendingView().paperGround()
        } else if let id = model.openWorkflow {
            // No files pane and no sidebar toggle: a workflow has no agent to have
            // asked about a file, so there would be nothing for either to show.
            WorkflowPage(workflowID: id).paperGround()
        } else if model.selection != nil {
            chat(inWindowOf: width)
        } else {
            // The project on its own: a new session, its pull requests, workflows and
            // worktrees. Its sessions are the middle column's.
            ProjectAgentsView(selection: Binding(get: { model.selection },
                                                 set: { model.selection = $0 }),
                              showsSessions: false)
                .paperGround()
        }
    }

    var body: some View {
        @Bindable var model = model
        // Three columns, the way Mail and Notes are laid out: the projects, the
        // sessions in the one picked, and what is being read. Picking a session shows
        // its chat beside the list rather than pushing it over the project, so moving
        // between two chats is one click, and the list stays in sight.
        NavigationSplitView(columnVisibility: $columns) {
            ProjectListView(selection: $model.sidebarItem)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                // A server asked for a credential there is none of (043).
                .sheet(item: $model.tokenAsk) { ask in TokenAskCard(ask: ask).paperSheet() }
                // A known server with a new key: rebuilt, or not what it says (043).
                .sheet(item: Binding(get: { model.hosts.rebuiltAsk },
                                     set: { model.hosts.rebuiltAsk = $0 })) { host in
                    RebuiltServerSheet(host: host).paperSheet()
                }
        } content: {
            SessionsColumn(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            GeometryReader { pane in
                detail(inPaneOf: pane.size.width)
            }
            // The chat and the inspector share this column now, not the window, so
            // this is the width the inspector measures itself against.
            .onGeometryChange(for: Double.self) { $0.size.width } action: { frame.windowWidth = $0 }
        }
        .environment(frame)
        .environment(requests)
        .environment(sidebarStates)
        .environment(webHolders)
        .task { await model.stayConnected() }
        // No tabs: the only way left to a second window, and a second window would be a
        // mirror of the first, because what is selected lives on the one model.
        .onAppear { NSWindow.allowsAutomaticWindowTabbing = false }
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
