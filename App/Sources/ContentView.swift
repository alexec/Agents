import AgentsKitCore
import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// The app's, so the menu bar can reach them too. Passed in rather than set on the
    /// scene's content: see the note in `AgentsApp`.
    let requests: WindowRequests
    let frame: SidebarFrame
    /// The folder's own shell under the page (#418).
    let terminal: FolderTerminalFrame
    @State private var sidebarStates = SidebarStates()
    @State private var webHolders = WebHolders()
    /// Which columns are showing. The folders stay put: moving between them is the
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
        // An agent showing a page means the page (#67).
        if HTMLPageScope.isHTML(file.url) { state.htmlShowsSource = false }
        frame.pane = .files
        if !frame.isOpen { frame.open() }
    }

    /// A file chosen in Open File… (#415), open for editing in the session's Files pane.
    private func openFound(_ file: FileMention) {
        requests.showsFileSearch = false
        guard let agentID = model.selection else { return }
        let state = sidebarStates.state(for: agentID)
        state.folder = file.url.deletingLastPathComponent()
        state.openFile = file.url
        state.openLine = nil
        frame.pane = .files
        if !frame.isOpen { frame.open() }
    }

    /// Open File… over what is being read, while it is asked for and there is a session.
    @ViewBuilder
    private var fileSearch: some View {
        if requests.showsFileSearch, let agent = model.selectedAgent {
            FileSearch(place: agent.cwd.lastPathComponent,
                       search: { await model.findFiles($0, for: agent.id) },
                       choose: openFound,
                       dismiss: { requests.showsFileSearch = false })
        }
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
        // Its toggle is in the detail's toolbar.
    }

    /// The one sidebar (#145): Activity, the folders folded open on their sessions, and
    /// at its foot what this Mac and its hosts are doing.
    private var folders: some View {
        @Bindable var model = model
        return FolderListView(selection: $model.sidebarItem)
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
            // A server asked for a credential there is none of (043).
            .sheet(item: $model.tokenAsk) { ask in
                TokenAskCard(ask: ask, save: { secret in
                    let ok = await model.credentials.save(secret.reveal(), for: ask.runtimeID)
                    model.finishTokenAsk(saved: ok)
                }, cancel: { model.finishTokenAsk(saved: false) })
                .paperSheet()
            }
            // A server asking to borrow a sign-in (T091) is the window's one alert, below.
            // A known server with a new key: rebuilt, or not what it says (043).
            // Agents missing at start-up, offered once each (048). Closed any way at
            // all, what was missing counts as offered.
            // An export or import on its way, with Cancel (#2437).
            .sheet(item: $model.exportImport) { progress in
                ExportImportProgressView(progress: progress).paperSheet()
            }
            .sheet(isPresented: $model.isOfferingInstall,
                   onDismiss: { model.rememberInstallOffer() }) {
                InstallAgentsSheet().paperSheet()
            }
    }

    /// What the right-hand column shows: a page about all the work, a workflow, a
    /// pinned page, a chat, a new session, or — with nothing picked — what to do.
    @ViewBuilder
    private func detail(inPaneOf width: CGFloat) -> some View {
        if model.showsEvents {
            EventsView().paperGround()
        } else if model.showsResources {
            ResourcesView().paperGround()
        } else if model.showsRuntimes {
            RuntimesView().paperGround()
        } else if model.showsMCPServers {
            MCPServersView().paperGround()
        } else if model.showsWorktrees {
            WorktreesView().paperGround()
        } else if model.showsSpending {
            SpendingView().paperGround()
        } else if model.showsTokens {
            TokensView().paperGround()
        } else if model.showsTime {
            TimeView().paperGround()
        } else if model.showsMilestones {
            MilestonesView().paperGround()
        } else if let id = model.openWorkflow {
            // No files pane and no sidebar toggle: a workflow has no agent to have
            // asked about a file, so there would be nothing for either to show.
            WorkflowPage(workflowID: id).paperGround()
        } else if case .review(let id)? = model.folderPage, let key = model.selectedFolderKey {
            // A change waiting for an OK, on its own page (#1472).
            ReviewDestination(id: id, folder: key).paperGround()
        } else if model.folderPage == .mcpServers, let key = model.selectedFolderKey {
            // A folder's MCP servers, from its row in the sidebar (#753).
            MCPServersView(folder: key).paperGround()
        } else if let page = model.folderPage, let key = model.selectedFolderKey {
            // A folder's workflows or its archive, from its row in the sidebar (#495).
            FolderWorkPage(page: page, folder: key).paperGround()
        } else if let path = model.openPin, let key = model.selectedFolderKey, let summary = model.selectedFolderSummary {
            // One of the folder's pinned pages (#159), live, where the chat would be; or a
            // pinned view (#189), fed afresh.
            VStack(spacing: 0) {
                OfflineStrip(host: summary.host)
                DiskStrip(host: summary.host)
                // Or a server's list view (#2032), whose Hide is its Unpin.
                if let pin = model.work.pinOrView(path, in: key.folder), let view = pin.view {
                    PinnedViewPage(folder: key.folder, pin: pin, view: view,
                                   call: { method, params in try await model.client(for: key.host).call(method, params) },
                                   unpin: {
                                       if pin.isServerView {
                                           await model.setViewHidden(path, true, in: key)
                                       } else {
                                           await model.unpin(path, in: key)
                                       }
                                   },
                                   startAgent: { model.offerStart($0, in: key) },
                                   recipient: { model.recipient(of: $0, in: key) },
                                   sendTo: { id, text in await model.send(text, to: id) },
                                   connected: model.isConnected)
                        // One page per pin, so another pin gets its own store and place (#872).
                        .id(pin.path)
                } else {
                    PinnedPage(folder: key, path: path)
                }
            }
            .paperGround()
        } else if model.selection != nil {
            chat(inWindowOf: width)
        } else if model.composing {
            // A new session in the folder: the empty chat with its prompt (066).
            FolderAgentsView(selection: Binding(get: { model.selection },
                                                 set: { model.selection = $0 }))
                .paperGround()
        } else {
            NothingPickedPage().paperGround()
        }
    }

    /// The folder whose shell is under the page, while Control-` has it open (#418):
    /// the selected folder, with an agent chosen or none, but not under the pages
    /// about all the work, which are no folder's.
    private var folderForTerminal: DaemonAPI.FolderSummary? {
        guard terminal.isOpen, !model.showsEvents, !model.showsResources, !model.showsRuntimes,
              !model.showsMCPServers, !model.showsWorktrees,
              !model.showsSpending, !model.showsTokens, !model.showsTime, !model.showsMilestones, let folder = model.selectedFolderSummary, folder.exists else { return nil }
        return folder
    }

    /// The selected session, while the detail shows its chat: not while a page, a
    /// workflow, a folder page or a pin is open over it (#926). Opening a workflow
    /// keeps the selection, so Back and the sidebar still know the session.
    private var chatAgent: Agent? { showsChat ? model.selectedAgent : nil }

    /// Whether `detail` shows the chat: a session is selected and nothing above it in
    /// that chain is open.
    private var showsChat: Bool {
        model.selection != nil && !model.showsEvents && !model.showsResources
            && !model.showsRuntimes && !model.showsMCPServers && !model.showsWorktrees
            && !model.showsSpending && !model.showsTime && !model.showsMilestones && model.openWorkflow == nil
            && model.folderPage == nil && model.openPin == nil
    }

    /// The detail's toolbar: what a folder and its sessions are done with, in reach
    /// whichever of its pages is open (#97).
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // No New Session button (#375): the folder's New session row, ⌘N and the
        // folder menu start one.
        // Pin and Archive (#586), as the workflow page has them: the two things a session
        // is most often done with. Archive leaves the chat, as ⌥⌘⌫ does.
        if let agent = chatAgent {
            ToolbarItemGroup {
                let pinned = model.isPinned(agent)
                Button {
                    Task { await model.setPinned(agent, !pinned) }
                } label: {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                }
                .disabled(agent.state == .archived)
                .help(pinned ? "Take this session out of Pinned in the sidebar"
                             : "Keep this session in Pinned, at the top of the sidebar")
                // The title, edited where the window shows it (#751).
                RenameButton(agent: agent, place: .mainWindow)
                // The person's prompts, to go to one or branch from it (#1658). The Mac's
                // chat has no ··· menu, so here, beside Rename, and in the Session menu.
                Button {
                    requests.wantsPrompts = true
                } label: {
                    Label("Prompts", systemImage: "list.number")
                }
                .help("Show the prompts in this session (⇧⌘P)")
                if agent.state == .archived {
                    Button {
                        Task { await model.unarchive(agent.id) }
                    } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                    .help("Unarchive this session (⌥⌘⌫)")
                } else {
                    Button {
                        Task { await model.archive(agent.id, andLeave: true) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .help("Archive this session and leave it (⌥⌘⌫)")
                }
            }
        }
        if showsChat {
            ToolbarItem {
                SidebarToggle(windowWidth: frame.windowWidth)
            }
        }
        // The microphone is open for "Hey Agents" (#2420): said here as well as by the
        // system's orange dot, and a click stops it.
        if WakeListener.shared.isListening {
            ToolbarItem {
                Button {
                    WindowDefaults.store.set(false, forKey: WakeListener.onKey)
                    WakeListener.shared.update()
                } label: {
                    Label("Listening for “Hey Agents”", systemImage: "ear")
                }
                .help("Listening for “Hey Agents”. Click to stop; Settings ▸ Appearance ▸ Voice turns it on again.")
            }
        }
    }

    /// The window's title: the worktree this build came from, then whatever the detail
    /// is reading. The primary checkout is "main".
    private var title: String {
        AppCheckout.windowTitle(model.selectedAgent?.title ?? (model.composing ? model.selectedFolderSummary?.name : nil))
    }

    var body: some View {
        @Bindable var model = model
        // A sidebar and what is being read (#145). Picking a session shows its chat
        // beside the list rather than pushing it over the folder, so moving between
        // two chats is one click, and the list stays in sight.
        // Today's set-up, offered the move to a control plane, never moved on its own
        // (058, frame I). Above the columns, not an inset: a split view's columns run
        // under an inset and hide their first rows behind it.
        VStack(spacing: 0) {
        if model.controlPlaneAway { ControlAwayStrip() }
        // The organisation stopped all agent work, or this Mac follows no policy it can trust (#998).
        OrgPolicyStrip(state: model.policyState)
        Group {
            if model.needsFirstRun {
                // No control plane and nothing of the old way: one question, and no
                // sidebar or toolbar until it is answered (058, frame A).
                FirstRunView()
            } else if model.signIn.suspended {
                // The organisation turned this person's access off: only that (#1002, FR-029).
                SuspendedPage(device: "Mac")
            } else {
                // Two columns (#145): the one sidebar, then what is being read, with the
                // inspector beside a chat.
                NavigationSplitView(columnVisibility: $columns) {
                    folders
                } detail: {
                    GeometryReader { pane in
                        VStack(spacing: 0) {
                            detail(inPaneOf: pane.size.width)
                                .frame(maxHeight: .infinity)
                            if let folder = folderForTerminal {
                                FolderTerminalPanel(folder: folder, pageHeight: pane.size.height)
                            }
                        }
                    }
                    // The chat and the inspector share this column, not the window, so
                    // this is the width the inspector measures itself against.
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { frame.windowWidth = $0 }
                    .overlay { fileSearch }
                    .toolbar { detailToolbar }
                    .navigationTitle(title)
                    .navigationSubtitle(model.selectedAgent == nil ? "" : (model.selectedFolderSummary?.name ?? ""))
                }
            }
        }
        }
        .environment(frame)
        .environment(terminal)
        .environment(requests)
        .environment(sidebarStates)
        .environment(webHolders)
        // A link in Markdown text is drawn in the tint, and with none set macOS draws it in
        // the system's link blue rather than the app's accent (#156).
        .tint(Paper.accent)
        // A file a chat links to is on its host: that host opens it (058, US1). Links to
        // the web are the window's own.
        .environment(\.openURL, OpenURLAction { url in
            guard let fileURL = ChatLinkURL.fileURL(from: url) else { return .systemAction }
            model.open(fileURL, on: model.selectedFolderHost)
            return .handled
        })
        .task { await model.stayConnected() }
        // What opens a folder's own window from outside a view: a notification, the
        // Dock's menu (#1089).
        .onAppear {
            AgentsAppDelegate.model = model
            model.openFolderWindow = { [openWindow] in openWindow(id: FolderWindowScene.id, value: $0) }
            // "Hey Agents" (#2420): voice mode in the chat in front, else a new session in
            // the folder New Session would start in.
            WakeListener.shared.onWake = { [model, requests] words in
                NSApp.activate()
                if model.selectedAgent == nil, !model.composing {
                    guard let folder = model.newSessionFolder else {
                        NSSound.beep()
                        WakeListener.shared.update()
                        return
                    }
                    model.showFolder(folder)
                    requests.focusPrompt()
                }
                VoiceMode.shared.wake(in: model.composing ? nil : model.selectedAgent?.id, words: words)
            }
            WakeListener.shared.start()
        }
        // An agent asking to be looked at is the one thing that opens this column by
        // itself. Here rather than in the sidebar, because the sidebar may be shut,
        // and shut means gone: there would be nothing listening.
        .onChange(of: model.filesToShow) { showWhatWasAskedFor() }
        .onChange(of: model.selection) {
            // Open File… searches the session it was opened over.
            requests.showsFileSearch = false
            // A chat just started opens on the chat alone (#358); anything it asks
            // to show still opens the column, just below.
            if let id = model.selection, id == model.justStarted {
                model.justStarted = nil
                frame.isOpen = false
            }
            showWhatWasAskedFor()
        }
        // The window's one alert, held while it is open (#101): a reconnect clearing the
        // problem, or a second arriving, waits for its button rather than closing it.
        .heldAlert(\.title, item: { WindowAlert.wanted(by: model) }, dismiss: { $0.closed(in: model) }) { alert in
            switch alert {
            case .lend(let ask):
                Button("Allow") { model.finishSignInLendAsk(ask, allowed: true) }
                Button("Don’t Allow", role: .cancel) { model.finishSignInLendAsk(ask, allowed: false) }
            case .lendGit(let ask):
                Button("Allow") { model.answerGitLend(ask, allowed: true) }
                Button("Don’t Allow", role: .cancel) { model.answerGitLend(ask, allowed: false) }
            case .problem:
                Button("OK") {}
                    .keyboardShortcut(.defaultAction)
            case .folderGone(let ask):
                // The ways on (#119). What was typed goes with Continue; Cancel leaves it
                // in the bar.
                Button(MissingFolderWords.continueInFolder) {
                    Task { await model.continueInFolder(ask.agentID, text: ask.text, attachments: ask.attachments) }
                }
                .keyboardShortcut(.defaultAction)
                if model.work.agent(ask.agentID)?.mayRecreateWorktree == true {
                    Button(MissingFolderWords.recreateWorktree) { Task { await model.recreateWorktree(ask.agentID) } }
                }
                Button(MissingFolderWords.archive) { Task { await model.archive(ask.agentID) } }
                Button("Cancel", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
        // One folder's settings, over whatever the window is showing (066).
        .sheet(isPresented: Binding(get: { requests.folderSettings != nil },
                                    set: { if !$0 { requests.folderSettings = nil } })) {
            FolderSettingsSheet(pane: Binding(get: { requests.folderSettings },
                                               set: { requests.folderSettings = $0 }))
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
        // How the agents are, on the Dock tile's Blob (#1317), always (#2156). Set only when
        // the mood changes; the image changes with no animation.
        .onChange(of: model.iconMood, initial: true) { _, mood in
            DockMood.show(mood)
        }
    }
}

/// The detail with nothing picked (#145): what the sidebar is, and the keys through it.
private struct NothingPickedPage: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing selected", systemImage: "sidebar.left")
        } description: {
            Text("""
            Pick a session on the left to read it, or New Session at the top to \
            start one. ⌘N does the same.

            ↑ and ↓ move through the list, → and ← unfold and fold a folder, \
            and ⌘F finds a session.
            """)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the window's one alert is about (#101): a server asking to borrow a sign-in, or
/// something that could not be finished. One at a time, the ask first, since a server is
/// waiting on it.
enum WindowAlert: Identifiable {
    case lend(SignInLendAsk)
    case lendGit(GitLendAsk)
    case problem(AlertWords)
    case folderGone(FolderGoneAsk)

    var id: String {
        switch self {
        case .lend(let ask): "lend-\(ask.id)"
        case .lendGit(let ask): "lend-git-\(ask.id)"
        case .problem(let words): "problem-\(words.id)"
        case .folderGone(let ask): "folder-gone-\(ask.id)"
        }
    }

    var title: String {
        switch self {
        case .lend(let ask): "Let \(ask.label) use this Mac’s \(ask.runtimeName) sign-in?"
        case .lendGit(let ask): ask.title
        case .problem: "Could not finish that"
        case .folderGone: "This agent’s folder isn’t there"
        }
    }

    var message: String {
        switch self {
        case .lend(let ask):
            "Its agents will use \(ask.runtimeName) as you, through this Mac, whenever this Mac is awake. The sign-in itself stays on this Mac. You can stop it in Settings ▸ Machines."
        case .lendGit(let ask): ask.message
        case .problem(let words): words.text
        case .folderGone(let ask): ask.message + " What you typed is still in the prompt."
        }
    }

    @MainActor
    static func wanted(by model: AppModel) -> WindowAlert? {
        if let ask = model.signInLendAsk { return .lend(ask) }
        if let ask = model.gitLendAsk { return .lendGit(ask) }
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
        // Escape is Don’t Allow, which its cancel button has said.
        case .lendGit: break
        case .problem(let words): if model.problem == words.text { model.dismissProblem() }
        case .folderGone(let ask): if model.folderGone == ask { model.folderGone = nil }
        }
    }
}
