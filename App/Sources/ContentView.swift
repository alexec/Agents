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

    /// What is open on top of the project page: a conversation, or a workflow.
    enum Page: Hashable {
        case agent(UUID)
        /// `Workflow.id` — the folder's path and the file's name, so two projects with
        /// a workflow of the same name cannot collide.
        case workflow(String)
    }

    /// What is being read, as a path of nothing or one.
    ///
    /// A chat is somewhere you go from the project and come back out of, rather than a
    /// column sitting beside it, so it is a push and the back button is the way home.
    /// A workflow is the same kind of thing — you open one to read it and you leave —
    /// so it is the same kind of push, onto the same stack.
    ///
    /// **Read in `body`, not inside the binding's getter.** Observation registers what
    /// a body actually reads while it runs, and a getter handed to `NavigationStack` is
    /// run later and elsewhere. `selection` survived that because the body reads it in
    /// three other places anyway; `openWorkflow` has nowhere else, so a getter was all
    /// it had, and setting the field redrew nothing and opened nothing.
    private var pages: [Page] {
        if let id = model.openWorkflow { return [.workflow(id)] }
        return model.selection.map { [.agent($0)] } ?? []
    }

    /// Where navigation writes back to. The only place either field is set from the
    /// stack, which is what keeps the two exclusive: no path through here leaves both.
    private func show(_ page: Page?) {
        switch page {
        case .agent(let id): model.selection = id; model.openWorkflow = nil
        case .workflow(let id): model.openWorkflow = id; model.selection = nil
        case nil: model.selection = nil; model.openWorkflow = nil
        }
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

    var body: some View {
        @Bindable var model = model
        GeometryReader { window in
            // Two columns: the projects, and the project.
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
            } detail: {
                // Spending is a page here rather than a window of its own, so closing
                // it is picking a project again and the window keeps its place. It
                // sits outside the conversation stack deliberately: a chat is pushed
                // from a project and popped back to it, and the bill is not on that
                // path.
                if model.showsEvents {
                    EventsView()
                        .paperGround()
                } else if model.showsResources {
                    ResourcesView()
                        .paperGround()
                } else if model.showsSpending {
                    SpendingView()
                        .paperGround()
                } else {
                    // `pages` is read here, in the body, so that opening a workflow
                    // invalidates it. See the note on `pages`.
                    let path = pages
                    // Written back only while this stack's project is still the one
                    // picked: the stack being replaced (see `.id` below) pops itself on
                    // the way out, and that pop would close the chat just opened.
                    let key = model.selectedProjectKey
                    NavigationStack(path: Binding(get: { path }, set: { pages in
                        guard model.selectedProjectKey == key else { return }
                        show(pages.last)
                    })) {
                        ProjectAgentsView(selection: $model.selection)
                            .paperGround()
                            .navigationDestination(for: Page.self) { page in
                                switch page {
                                case .agent:
                                    chat(inWindowOf: window.size.width)
                                // No files pane and no sidebar toggle: a workflow has
                                // no agent to have asked about a file, so there would
                                // be nothing for either to show.
                                case .workflow(let id):
                                    WorkflowPage(workflowID: id)
                                        .paperGround()
                                }
                            }
                    }
                    // One stack per project. Opening a chat in another project (Go ▸
                    // Next Needing Attention, a banner, Resources) changes the project and
                    // the chat at once; a stack kept across that shows the new project's
                    // page and never pushes the chat. A fresh one starts on the path.
                    .id(model.selectedProjectKey)
                }
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { frame.windowWidth = $0 }
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
