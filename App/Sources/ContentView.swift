import AgentsKitCore
import AppKit
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
    @State private var offeringMove = false

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
        // An agent showing a page means the page (#67).
        if HTMLPageScope.isHTML(file.url) { state.htmlShowsSource = false }
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
        // Its toggle is in the sessions column's toolbar, after the search field.
    }

    private var isShowingActivity: Bool {
        model.showsEvents || model.showsResources || model.showsRuntimes || model.showsSpending
    }

    /// The projects column, the same in both layouts.
    private var projects: some View {
        @Bindable var model = model
        return ProjectListView(selection: $model.sidebarItem)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            // A server asked for a credential there is none of (043).
            .sheet(item: $model.tokenAsk) { ask in TokenAskCard(ask: ask).paperSheet() }
            // A server asking to borrow a sign-in (T091) is the window's one alert, below.
            // A known server with a new key: rebuilt, or not what it says (043).
            // Agents missing at start-up, offered once each (048). Closed any way at
            // all, what was missing counts as offered.
            .sheet(isPresented: $model.isOfferingInstall,
                   onDismiss: { model.rememberInstallOffer() }) {
                InstallAgentsSheet().paperSheet()
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
        } else if model.showsRuntimes {
            RuntimesView().paperGround()
        } else if model.showsSpending {
            SpendingView().paperGround()
        } else if let id = model.openWorkflow {
            // No files pane and no sidebar toggle: a workflow has no agent to have
            // asked about a file, so there would be nothing for either to show.
            WorkflowPage(workflowID: id).paperGround()
        } else if let id = model.selection, model.selectedAgent == nil, let gone = model.retiredTombstone(id) {
            // Retired (051): nothing left to chat with, only who it was.
            RetiredAgentPage(tombstone: gone, startedBy: model.retiredStarterLabel(gone)).paperGround()
        } else if model.selection != nil {
            chat(inWindowOf: width)
                // Every route to an agent by id comes here — a workflow's run, a pull
                // request's agent, a menu. One the window has no agent for may have been
                // retired (051): asked once, and the page above shows when it has been.
                .task(id: model.selection) {
                    if let id = model.selection, model.selectedAgent == nil { _ = await model.tombstone(for: id) }
                }
        } else {
            // The project on its own: a new session. Its sessions and workflows are the
            // middle column's, and its settings a sheet.
            ProjectAgentsView(selection: Binding(get: { model.selection },
                                                 set: { model.selection = $0 }))
                .paperGround()
        }
    }

    var body: some View {
        @Bindable var model = model
        // Three columns, the way Mail and Notes are laid out: the projects, the
        // sessions in the one picked, and what is being read. Picking a session shows
        // its chat beside the list rather than pushing it over the project, so moving
        // between two chats is one click, and the list stays in sight.
        // Today's set-up, offered the move to a control plane, never moved on its own
        // (058, frame I). Above the columns, not an inset: a split view's columns run
        // under an inset and hide their first rows behind it.
        VStack(spacing: 0) {
        if model.controlPlaneAway { ControlAwayStrip() }
        Group {
            if model.needsFirstRun {
                // No control plane and nothing of the old way: one question, and no
                // sidebar or toolbar until it is answered (058, frame A).
                FirstRunView()
            } else if isShowingActivity {
                // Events, Resources and Spending are about all of the work, so the
                // sessions of one project have no place beside them: two columns.
                NavigationSplitView(columnVisibility: $columns) {
                    projects
                } detail: {
                    detail(inPaneOf: 0)
                }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    projects
                } content: {
                    SessionsColumn(selection: $model.selection)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                } detail: {
                    GeometryReader { pane in
                        detail(inPaneOf: pane.size.width)
                    }
                    // The chat and the inspector share this column now, not the window,
                    // so this is the width the inspector measures itself against.
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { frame.windowWidth = $0 }
                }
            }
        }
        }
        .environment(frame)
        .environment(requests)
        .environment(sidebarStates)
        .environment(webHolders)
        // A file a chat links to is on its host: that host opens it (058, US1). Links to
        // the web are the window's own.
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL else { return .systemAction }
            model.open(url, on: model.selectedProjectHost)
            return .handled
        })
        .task { await model.stayConnected() }
        // No tabs: the only way left to a second window, and a second window would be a
        // mirror of the first, because what is selected lives on the one model.
        .onAppear { NSWindow.allowsAutomaticWindowTabbing = false }
        // An agent asking to be looked at is the one thing that opens this column by
        // itself. Here rather than in the sidebar, because the sidebar may be shut,
        // and shut means gone: there would be nothing listening.
        .onChange(of: model.filesToShow) { showWhatWasAskedFor() }
        .onChange(of: model.selection) { showWhatWasAskedFor() }
        // The window's one alert, held while it is open (#101): a reconnect clearing the
        // problem, or a second arriving, waits for its button rather than closing it.
        .heldAlert(\.title, item: { WindowAlert.wanted(by: model) }, dismiss: { $0.closed(in: model) }) { alert in
            switch alert {
            case .lend(let ask):
                Button("Allow") { model.finishSignInLendAsk(ask, allowed: true) }
                Button("Don’t Allow", role: .cancel) { model.finishSignInLendAsk(ask, allowed: false) }
            case .problem:
                Button("OK") {}
                    .keyboardShortcut(.defaultAction)
            case .folderGone(let ask):
                // The ways on (#119). What was typed goes with Continue; Cancel leaves it
                // in the bar.
                Button(MissingFolderWords.continueInProject) {
                    Task { await model.continueInProject(ask.agentID, text: ask.text, attachments: ask.attachments) }
                }
                .keyboardShortcut(.defaultAction)
                if model.agents.first(where: { $0.id == ask.agentID })?.mayRecreateWorktree == true {
                    Button(MissingFolderWords.recreateWorktree) { Task { await model.recreateWorktree(ask.agentID) } }
                }
                Button(MissingFolderWords.archive) { Task { await model.archive(ask.agentID) } }
                Button("Cancel", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
        // One project's settings, over whatever the window is showing (066).
        .sheet(isPresented: Binding(get: { requests.projectSettings != nil },
                                    set: { if !$0 { requests.projectSettings = nil } })) {
            ProjectSettingsSheet(pane: Binding(get: { requests.projectSettings },
                                               set: { requests.projectSettings = $0 }))
                .environment(requests)
                .paperSheet()
        }
        // An agent that needs its runtime signed in gets the sign-in, not an error.
        .sheet(isPresented: Binding(get: { model.signInRuntimeID != nil },
                                    set: { if !$0 { model.putAwaySignIn() } })) {
            if let runtimeID = model.signInRuntimeID {
                RuntimeAccountView(runtimeID: runtimeID)
                    .paperSheet()
            }
        }
        // How many sessions need a person, on the Dock — Needs attention and Blocked.
        .onChange(of: model.needsPersonCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }
}

/// What the window's one alert is about (#101): a server asking to borrow a sign-in, or
/// something that could not be finished. One at a time, the ask first, since a server is
/// waiting on it.
enum WindowAlert: Identifiable {
    case lend(SignInLendAsk)
    case problem(AlertWords)
    case folderGone(FolderGoneAsk)

    var id: String {
        switch self {
        case .lend(let ask): "lend-\(ask.id)"
        case .problem(let words): "problem-\(words.id)"
        case .folderGone(let ask): "folder-gone-\(ask.id)"
        }
    }

    var title: String {
        switch self {
        case .lend(let ask): "Let \(ask.label) use this Mac’s \(ask.runtimeName) sign-in?"
        case .problem: "Could not finish that"
        case .folderGone: "This agent’s folder isn’t there"
        }
    }

    var message: String {
        switch self {
        case .lend(let ask):
            "Its agents will use \(ask.runtimeName) as you, through this Mac, whenever this Mac is awake. The sign-in itself stays on this Mac. You can stop it in Settings ▸ Control plane ▸ Hosts."
        case .problem(let words): words.text
        case .folderGone(let ask): ask.message + " What you typed is still in the prompt."
        }
    }

    @MainActor
    static func wanted(by model: AppModel) -> WindowAlert? {
        if let ask = model.signInLendAsk { return .lend(ask) }
        if let ask = model.folderGone { return .folderGone(ask) }
        return model.problem.map { .problem(AlertWords(text: $0)) }
    }

    /// Closed, by its button or by Escape (its cancel button). A problem the model has
    /// moved on from is not the model's to forget again.
    @MainActor
    func closed(in model: AppModel) {
        switch self {
        // Its buttons answer it, Escape as Don’t Allow, and only once: its answer is a
        // continuation, so nothing here answers it again.
        case .lend: break
        case .problem(let words): if model.problem == words.text { model.dismissProblem() }
        case .folderGone(let ask): if model.folderGone == ask { model.folderGone = nil }
        }
    }
}
