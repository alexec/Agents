import AgentsKitCore
import SwiftUI
import UIKit

/// The remote: the same app, laid out for the screen it is on.
///
/// Scene-based from the first commit, with no `UIApplicationDelegate` anywhere, because
/// iOS 27 will not launch an app without the UIScene lifecycle and nothing about a
/// layout can be judged until it launches.
@main
struct RemoteApp: App {
    /// For pushes only. See `PushDelegate`.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push

    /// The real control plane, unless `-fake` says otherwise.
    ///
    /// Nothing above this line knows which it got. That was the point of making the
    /// fake a `DaemonLink` rather than a fake model: the whole app moved from canned
    /// data to a live daemon by changing what it is handed.
    ///
    /// The fake is kept for the layout work — it holds a question waiting and a
    /// conversation long enough to page, neither of which a real Mac reliably has when
    /// somebody wants to look at a screen.
    ///
    /// The real one is the control plane this phone paired with (058, US5): its address,
    /// and the relay through iCloud when the address cannot be reached. Until it pairs,
    /// there is nothing to reach.
    @State private var model = RemoteModel(link: RemoteApp.link())

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // The walk simulator's socket (#1182), for run-app's `walk.py remote`; only with -walk.
        WalkServer.startIfWalking()
        #endif
    }

    static func link() -> any DaemonLink {
        if ProcessInfo.processInfo.arguments.contains("-fake") { return FakeDaemon() }
        return RemoteControl.link() ?? NotPairedLink()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // The organisation turned this person's access off: only that (#1002, FR-029),
                // in place of the screens, so VoiceOver reaches nothing under it and their
                // sheets close (#2439).
                if model.signIn.suspended {
                    SuspendedPage(device: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
                } else {
                    RemoteView()
                }
            }
                .background(Paper.ground)
                // Undo after Archive (#1534), for a few seconds, over the foot of whatever shows.
                .modifier(ArchiveUndoOverlay())
                .environment(model)
                // A new model on a new link once the phone pairs with a control plane.
                .id(ObjectIdentifier(model))
                .task {
                    push.received = { [model] userInfo in await model.receivedPush(userInfo) }
                    push.registered = { [model] token in model.pushTokenArrived(token) }
                }
                #if DEBUG && targetEnvironment(simulator)
                // The walk simulator pairs with a scratch control plane's code (#1287): its
                // Paste control takes no press but a finger's. Only with -walk.
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    guard args.contains("-walk"), let at = args.firstIndex(of: "-pair"), at + 1 < args.count,
                          !model.pairedWithControlPlane, RemoteControl.link() == nil else { return }
                    await model.pair(scanned: args[at + 1])
                }
                // A link as a widget row or a banner opens it (#1367), without the system's
                // "Open in Agents?" that `simctl openurl` raises and no walk can press.
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    guard args.contains("-walk"), let at = args.firstIndex(of: "-open"), at + 1 < args.count,
                          let url = URL(string: args[at + 1]) else { return }
                    model.openedFromTheWidget(url)
                }
                // A folder alone (#2191), as its heading's long press opens it: a menu no walk
                // can open. Named as its heading is, once the folders have come.
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    guard args.contains("-walk"), let at = args.firstIndex(of: "-alone"), at + 1 < args.count else { return }
                    for _ in 0..<50 {
                        if let folder = model.folders.first(where: { $0.name == args[at + 1] }) {
                            model.phoneFolder = folder.key
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                #endif
                .onChange(of: model.pairedWithControlPlane) { _, paired in
                    guard paired else { return }
                    // The old pairing's connections end with it rather than dialling on (#175).
                    let old = model
                    model = RemoteModel(link: RemoteApp.link())
                    Task { await old.stop() }
                }
                // Forget This iPhone (#344): an unpaired model, so nothing of the old
                // pairing stays on screen, and the one thing offered is a new code.
                .onChange(of: model.forgotItself) { _, forgot in
                    guard forgot else { return }
                    let old = model
                    model = RemoteModel(link: RemoteApp.link())
                    Task { await old.stop() }
                }
        }
        // The widget kept true with the app shut and no push coming (#1046).
        .backgroundTask(.appRefresh(RemoteModel.widgetRefreshTask)) { [model] in
            RemoteModel.scheduleWidgetRefresh()
            await model.refreshInBackground()
        }

        // A session in a scene of its own on an iPad (#888), from a row's menu or a drag
        // out of the sidebar. One scene per session: opening one already open brings it
        // forward. The drag is the only thing this scene handles from outside.
        WindowGroup(id: PoppedChat.sceneID, for: UUID.self) { $id in
            PoppedChatScene(id: $id)
                .environment(model)
        }
        .handlesExternalEvents(matching: [PoppedChat.activityType])

        // A folder in a scene of its own on an iPad (#1089), from its heading's menu. One
        // scene per folder: opening one already open brings it forward.
        WindowGroup(id: RemoteFolderState.sceneID, for: FolderKey.self) { $key in
            RemoteFolderScene(key: key)
                .environment(model)
        }
    }
}

/// The Mac's layout, for the screen it is on (#226): its one sidebar, and what the
/// sidebar picked beside it.
///
/// On an iPad the sidebar stays beside the detail, as the Mac's does; on an iPhone the
/// split view collapses, the sidebar is the screen the app opens on, and a pick is pushed
/// over it with a way back. What is opened from the detail — a workflow's run — is
/// pushed over it in turn.
struct RemoteView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow
    /// Which column a phone shows: the detail whenever something is picked.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    /// The folder's own shell is up (#418).
    @State private var showsFolderTerminal = false
    /// This scene, among the app's, for where the person is (021, #888).
    @State private var sceneID = UUID()

    /// What is open over the folder, in the order each was opened from the one before:
    /// a pinned page, a workflow, a conversation. The first is the detail's own page, the
    /// one the sidebar lights; the rest are pushed over it. With none, a new session in the
    /// folder when one was asked for (#366), else nothing (#2090).
    private var routes: [RemoteRoute] {
        let open = [model.openArchive ? RemoteRoute.archive : nil, model.openMCPServers ? RemoteRoute.mcpServers : nil,
                    model.openPin.map(RemoteRoute.page),
                    model.openWorkflow.map(RemoteRoute.workflow), model.selection.map(RemoteRoute.agent),
                    model.openReview.map(RemoteRoute.review)]
            .compactMap { $0 }
        // A folder with nothing open over it starts a session (#366): its New session row (#375).
        // Only when asked for: leaving a session does not open one (#2090).
        if open.isEmpty, model.selectedFolder != nil, model.composing { return [.start] }
        return open
    }

    private var pushed: Binding<[RemoteRoute]> {
        Binding(get: { Array(routes.dropFirst()) },
                set: { more in
                    guard let root = routes.first else { return }
                    let all = [root] + more
                    model.openArchive = all.contains(.archive)
                    model.openMCPServers = all.contains(.mcpServers)
                    model.openPin = all.lazy.compactMap(\.pinPath).first
                    model.openWorkflow = all.lazy.compactMap(\.workflowID).first
                    model.selection = all.compactMap(\.agentID).last
                    model.openReview = all.lazy.compactMap(\.reviewID).first
                })
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            RemoteSidebar()
        } detail: {
            NavigationStack(path: pushed) {
                Group {
                    if let root = routes.first {
                        page(root)
                    } else if let activity = model.openActivity {
                        activityPage(activity)
                    } else {
                        NothingPickedPage()
                    }
                }
                .navigationDestination(for: RemoteRoute.self) { page($0) }
            }
            // The detail's own page changes with the pick, so nothing pushed over the
            // last one is left on top of the next (#226).
            .id(model.sidebarItem)
        }
        .navigationSplitViewStyle(.balanced)
        // A folder shown alone on an iPhone (#1089), over every folder, with ‹ All.
        .modifier(PhoneFolderCover())
        // A milestone just earned (#984), on the iPad: once, until closed or opened.
        .overlay(alignment: .bottomTrailing) {
            if let milestone = model.milestoneCard {
                MilestoneCard(milestone: milestone,
                              open: { model.dismissMilestone(milestone); model.sidebarItem = .milestones },
                              dismiss: { model.dismissMilestone(milestone) })
                    .frame(maxWidth: 320)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(20)
            }
        }
        // Something picked, here or from a banner, a widget or a start, is shown; back to
        // the list on a phone puts it down, so the same row opens it again.
        // Nothing left to show, as after Archive: back to the list it came from (#2090).
        .onChange(of: model.sidebarItem) { _, item in
            model.startPagesMoved()
            if item != nil {
                compactColumn = .detail
            } else if sizeClass == .compact, model.openActivity == nil {
                compactColumn = .sidebar
            }
        }
        .onChange(of: compactColumn) { _, column in
            if column == .sidebar, sizeClass == .compact { model.sidebarItem = nil }
        }
        .task(id: model.selectedFolder) {
            if let folder = model.selectedFolder { await model.loadLabelVocabulary(in: folder) }
        }
        .sheet(isPresented: $showsFolderTerminal) {
            if let folder = model.selectedFolder {
                FolderTerminalSheet(folder: folder)
                    .environment(model)
            }
        }
        // A server asked for a key on a send, with no start page to ask over (#344).
        .tokenAskSheet(model, shown: model.startingIn == nil)
        // A host's git asked to use a Mac's git access (#1122).
        .alert(model.gitLendAsk?.title ?? "", isPresented: Binding(get: { model.gitLendAsk != nil }, set: { _ in }),
               presenting: model.gitLendAsk) { ask in
            Button("Allow") { Task { await model.answerGitLend(ask, allowed: true) } }
            Button("Don’t Allow", role: .cancel) { Task { await model.answerGitLend(ask, allowed: false) } }
        } message: { ask in
            Text(ask.message)
        }
        // Where this device is, told to the Mac on every change (021).
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhase(phase, of: sceneID) }
        // A tap on the Home-screen widget (068). The one place a URL is taken from
        // outside the app, so it is checked and dropped rather than acted on by shape.
        .onOpenURL { model.openedFromTheWidget($0) }
        // A session dragged out of the sidebar that came here rather than to a scene of
        // its own (#888): it goes on to one.
        .onContinueUserActivity(PoppedChat.activityType) { activity in
            if let id = PoppedChat.agentID(in: activity) { openWindow(id: PoppedChat.sceneID, value: id) }
        }
        .task {
            await model.connect()
#if DEBUG
            await model.openFromLaunchArguments()
#endif
        }
        .alert("That did not work",
               isPresented: Binding(get: { model.problem != nil },
                                    set: { if !$0 { model.dismissProblem() } })) {
            Button("OK") { model.dismissProblem() }
        } message: {
            Text(model.problem ?? "")
        }
        // Delete from a session's menu (#398), asked here: the menu is gone by now.
        .confirmationDialog(DeletionWords.confirmTitle(model.askingToDelete?.title),
                            isPresented: Binding(get: { model.askingToDelete != nil },
                                                 set: { if !$0 { model.askingToDelete = nil } }),
                            titleVisibility: .visible, presenting: model.askingToDelete) { agent in
            Button("Delete", role: .destructive) { Task { await model.delete(agent.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(DeletionWords.confirmMessage)
        }
        // Rename… from a session's menu or the chat's ··· (#751), asked here as Delete… is.
        .alert("Rename Session",
               isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }),
               presenting: model.renaming) { agent in
            TextField(agent.titleFromRuntime ?? "Title", text: $model.renameText)
            Button("Rename") {
                let title = model.renameText
                guard Agent.cleanedTitle(title) != agent.title else { return }
                Task { await model.rename(agent.id, to: title) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("An empty title gives the session the runtime's name again.")
        }
        // Archive… on a folder's long press (#668), named as its row is.
        .confirmationDialog(FolderArchiveWords.confirmTitle(model.askingToArchiveFolder.map { summary in
                                SidebarOrder.label(summary) { model.hostLabel($0) } } ?? ""),
                            isPresented: Binding(get: { model.askingToArchiveFolder != nil },
                                                 set: { if !$0 { model.askingToArchiveFolder = nil } }),
                            titleVisibility: .visible, presenting: model.askingToArchiveFolder) { summary in
            Button("Archive") { Task { await model.archiveFolder(summary) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(FolderArchiveWords.confirmMessage)
        }
        // Delete… on an archived folder (#677), asked here as a session's is.
        .confirmationDialog(DeletionWords.folderConfirmTitle(model.askingToDeleteFolder.map { summary in
                                SidebarOrder.label(summary) { model.hostLabel($0) } } ?? ""),
                            isPresented: Binding(get: { model.askingToDeleteFolder != nil },
                                                 set: { if !$0 { model.askingToDeleteFolder = nil } }),
                            titleVisibility: .visible, presenting: model.askingToDeleteFolder) { summary in
            Button("Delete", role: .destructive) { Task { await model.deleteFolder(summary) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(DeletionWords.folderConfirmMessage)
        }
        // A send refused because the folder has gone (#119), with the ways on.
        .alert("This agent’s folder isn’t there",
               isPresented: Binding(get: { model.folderGone != nil && model.problem == nil },
                                    set: { if !$0 { model.folderGone = nil } }),
               presenting: model.folderGone) { ask in
            Button(MissingFolderWords.continueInFolder) {
                Task { await model.continueInFolder(ask.agentID, text: ask.text, attachments: ask.attachments) }
            }
            if model.work.agent(ask.agentID)?.mayRecreateWorktree == true {
                Button(MissingFolderWords.recreateWorktree) { Task { await model.recreateWorktree(ask.agentID) } }
            }
            Button(MissingFolderWords.archive, role: .destructive) { Task { await model.archive(ask.agentID) } }
            Button("Cancel", role: .cancel) {}
        } message: { ask in
            Text(ask.message + " What you typed is still there.")
        }
    }

    /// A page of the folder, with the way to the folder's own shell (#418) on it:
    /// Control-` from an iPad's keyboard, as on the Mac.
    private func page(_ route: RemoteRoute) -> some View {
        let folder = model.selectedFolder
        let opensTerminal = folder != nil
        // On a chat it is in the chat's ··· menu: one menu in the bar, not two (#2808).
        let isChat = if case .agent = route { true } else { false }
        return pageContent(route)
            .environment(\.openFolderTerminal, folder.flatMap { folder in
                isChat ? OpenFolderTerminal(folder: folder) { showsFolderTerminal = true } : nil
            })
            .background {
                if opensTerminal, isChat {
                    Button("Folder Terminal") { showsFolderTerminal = true }
                        .keyboardShortcut("`", modifiers: .control)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .toolbar {
                if opensTerminal, !isChat {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            showsFolderTerminal = true
                        } label: {
                            Label("Folder Terminal", systemImage: "apple.terminal")
                        }
                        .keyboardShortcut("`", modifiers: .control)
                    }
                }
            }
    }

    @ViewBuilder
    private func pageContent(_ route: RemoteRoute) -> some View {
        switch route {
        case .agent:
            RemoteChatView().paperGround()
        case .workflow(let id): WorkflowPage(workflowID: id).paperGround()
        case .review(let id):
            if let summary = model.selectedSummary {
                RemoteReviewDestination(id: id, folder: summary.key).paperGround()
            }
        case .archive:
            if let summary = model.selectedSummary {
                ArchivePage(folder: summary.key).paperGround()
            }
        case .mcpServers:
            if let summary = model.selectedSummary {
                MCPServersListView(folder: summary.key).paperGround()
            }
        case .start:
            if let folder = model.selectedFolder {
                // Held open while it is on screen: the runtime behind its choices is let
                // go when it is not (029).
                StartAgentView(folder: folder)
                    .paperGround()
            }
        case .page(let path):
            if let folder = model.selectedFolder {
                if let pin = model.work.pinOrView(path, in: folder), let view = pin.view {
                    // A pinned view (#189), or a server's list view (#2032), fed afresh,
                    // through the host a chat's views use.
                    PinnedViewPage(folder: folder, pin: pin, view: view,
                                   call: { method, params in try await model.viewCall(method, params) },
                                   unpin: {
                                       if pin.isServerView {
                                           await model.setViewHidden(path, true, in: folder)
                                       } else {
                                           await model.unpin(path, in: folder)
                                       }
                                   },
                                   startAgent: { start in
                                       guard let key = model.work.folder(folder)?.key else {
                                           return "This folder isn’t one the phone knows."
                                       }
                                       return model.offerStart(start, in: key)
                                   },
                                   recipient: { message in
                                       model.work.folder(folder).flatMap { model.recipient(of: message, in: $0.key) }
                                   },
                                   sendTo: { id, text in await model.send(text, to: id) },
                                   connected: model.isConnected)
                        // One page per pin, so another pin gets its own store and place (#872).
                        .id(pin.path)
                        .paperGround()
                } else {
                    PinnedPage(folder: folder, path: path).paperGround()
                }
            }
        }
    }

    @ViewBuilder
    private func activityPage(_ item: SidebarItem) -> some View {
        switch item {
        case .events: EventsListView().paperGround()
        case .resources: ResourcesListView().paperGround()
        case .runtimes: RuntimesView().paperGround()
        case .mcpServers: MCPServersListView().paperGround()
        case .tokens: TokensView().paperGround()
        case .time: TimeView().paperGround()
        case .milestones: MilestonesView().paperGround()
        case .worktrees: WorktreesListView().paperGround()
        default: TotalsView().paperGround()
        }
    }
}

/// Somewhere to go over the folder: the detail's own page, or one pushed over it.
enum RemoteRoute: Hashable {
    case workflow(Workflow.ID)
    case agent(UUID)
    /// A new session in the folder (#366): its page when nothing is open over it.
    case start
    /// One of the folder's pinned pages (#159), by its path in the folder.
    case page(String)
    /// What the folder has archived (#495, #498), from its Archived row in the sidebar.
    case archive
    /// The folder's MCP servers (#753), from its MCP Servers row in the sidebar.
    case mcpServers
    /// A change waiting for an OK, on its Review page (#1472), by its `Approval.id`.
    case review(String)

    var reviewID: String? {
        if case .review(let id) = self { return id }
        return nil
    }

    var pinPath: String? {
        if case .page(let path) = self { return path }
        return nil
    }

    var workflowID: Workflow.ID? {
        if case .workflow(let id) = self { return id }
        return nil
    }

    var agentID: UUID? {
        if case .agent(let id) = self { return id }
        return nil
    }
}

/// The folder an iPhone shows alone (#1089), as the cover's item.
private struct PhoneFolder: Identifiable {
    let key: FolderKey
    var id: String { key.stored }
}

/// The folder an iPhone shows alone (#1089), over every folder, with ‹ All.
private struct PhoneFolderCover: ViewModifier {
    @Environment(RemoteModel.self) private var model

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(get: { model.phoneFolder.map(PhoneFolder.init) },
                                              set: { model.phoneFolder = $0?.key })) { folder in
            RemoteFolderScene(key: folder.key, back: { model.phoneFolder = nil })
                .environment(model)
        }
    }
}

/// Undo after Archive (#1534) over the foot of the scene, on the scene's root: RemoteView's
/// own chain is at the type checker's limit.
private struct ArchiveUndoOverlay: ViewModifier {
    @Environment(RemoteModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let undo = model.archiveUndo {
                    ArchiveUndoStrip(undo: undo,
                                     perform: { Task { await model.undoArchive() } },
                                     dismiss: { model.dismissArchiveUndo(undo) })
                        .frame(maxWidth: 480)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                        .padding(.bottom, 12)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.archiveUndo?.id)
    }
}

/// The detail with nothing picked (#2090): what the Mac's window says, in the Remote's words.
/// Leaving a session comes here on an iPad, and never to New session.
struct NothingPickedPage: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing selected", systemImage: "sidebar.left")
        } description: {
            Text("Pick a session to read it, or New Session to start one.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
