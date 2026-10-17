import AgentsKitCore
import SwiftUI

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
            RemoteView()
                .background(Paper.ground)
                .environment(model)
                // A new model on a new link once the phone pairs with a control plane.
                .id(ObjectIdentifier(model))
                .task { push.received = { [model] userInfo in await model.receivedPush(userInfo) } }
                #if DEBUG && targetEnvironment(simulator)
                // The walk simulator pairs with a scratch control plane's code (#1287): its
                // Paste control takes no press but a finger's. Only with -walk.
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    guard args.contains("-walk"), let at = args.firstIndex(of: "-pair"), at + 1 < args.count,
                          !model.pairedWithControlPlane, RemoteControl.link() == nil else { return }
                    await model.pair(scanned: args[at + 1])
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

        // A project in a scene of its own on an iPad (#1089), from its heading's menu. One
        // scene per project: opening one already open brings it forward.
        WindowGroup(id: RemoteProjectState.sceneID, for: ProjectKey.self) { $key in
            RemoteProjectScene(key: key)
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
    /// The project's own shell is up (#418).
    @State private var showsProjectTerminal = false
    /// This scene, among the app's, for where the person is (021, #888).
    @State private var sceneID = UUID()

    /// What is open over the project, in the order each was opened from the one before:
    /// a pinned page, a workflow, a conversation. The first is the detail's own page, the
    /// one the sidebar lights; the rest are pushed over it. With none, the project's page
    /// is a new session in it (#366).
    private var routes: [RemoteRoute] {
        let open = [model.openArchive ? RemoteRoute.archive : nil, model.openMCPServers ? RemoteRoute.mcpServers : nil,
                    model.openPin.map(RemoteRoute.page),
                    model.openWorkflow.map(RemoteRoute.workflow), model.selection.map(RemoteRoute.agent)]
            .compactMap { $0 }
        // A project with nothing open over it starts a session (#366): its New session row (#375).
        if open.isEmpty, model.selectedProject != nil { return [.start] }
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
                        ContentUnavailableView("Nothing open", systemImage: "sidebar.left",
                                               description: Text("Pick a session, a workflow or a project."))
                    }
                }
                .navigationDestination(for: RemoteRoute.self) { page($0) }
            }
            // The detail's own page changes with the pick, so nothing pushed over the
            // last one is left on top of the next (#226).
            .id(model.sidebarItem)
        }
        .navigationSplitViewStyle(.balanced)
        // A project shown alone on an iPhone (#1089), over every project, with ‹ All.
        .modifier(PhoneProjectCover())
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
        .onChange(of: model.sidebarItem) { _, item in
            if item != nil { compactColumn = .detail }
        }
        .onChange(of: compactColumn) { _, column in
            if column == .sidebar, sizeClass == .compact { model.sidebarItem = nil }
        }
        .task(id: model.selectedProject) {
            if let folder = model.selectedProject { await model.loadLabelVocabulary(in: folder) }
        }
        .sheet(isPresented: $showsProjectTerminal) {
            if let folder = model.selectedProject {
                ProjectTerminalSheet(folder: folder)
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
        // Archive… on a project's long press (#668), named as its row is.
        .confirmationDialog(ProjectArchiveWords.confirmTitle(model.askingToArchiveProject.map { summary in
                                SidebarOrder.label(summary) { model.hostLabel($0) } } ?? ""),
                            isPresented: Binding(get: { model.askingToArchiveProject != nil },
                                                 set: { if !$0 { model.askingToArchiveProject = nil } }),
                            titleVisibility: .visible, presenting: model.askingToArchiveProject) { summary in
            Button("Archive") { Task { await model.archiveProject(summary) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(ProjectArchiveWords.confirmMessage)
        }
        // Delete… on an archived project (#677), asked here as a session's is.
        .confirmationDialog(DeletionWords.projectConfirmTitle(model.askingToDeleteProject.map { summary in
                                SidebarOrder.label(summary) { model.hostLabel($0) } } ?? ""),
                            isPresented: Binding(get: { model.askingToDeleteProject != nil },
                                                 set: { if !$0 { model.askingToDeleteProject = nil } }),
                            titleVisibility: .visible, presenting: model.askingToDeleteProject) { summary in
            Button("Delete", role: .destructive) { Task { await model.deleteProject(summary) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(DeletionWords.projectConfirmMessage)
        }
        // A send refused because the folder has gone (#119), with the ways on.
        .alert("This agent’s folder isn’t there",
               isPresented: Binding(get: { model.folderGone != nil && model.problem == nil },
                                    set: { if !$0 { model.folderGone = nil } }),
               presenting: model.folderGone) { ask in
            Button(MissingFolderWords.continueInProject) {
                Task { await model.continueInProject(ask.agentID, text: ask.text, attachments: ask.attachments) }
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

    /// A page of the project, with the way to the project's own shell (#418) on it:
    /// Control-` from an iPad's keyboard, as on the Mac.
    private func page(_ route: RemoteRoute) -> some View {
        pageContent(route)
            .toolbar {
                if model.selectedProject != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            showsProjectTerminal = true
                        } label: {
                            Label("Project Terminal", systemImage: "apple.terminal")
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
        case .archive:
            if let summary = model.selectedSummary {
                ArchivePage(project: summary.key).paperGround()
            }
        case .mcpServers:
            if let summary = model.selectedSummary {
                MCPServersListView(project: summary.key).paperGround()
            }
        case .start:
            if let folder = model.selectedProject {
                // Held open while it is on screen: the runtime behind its choices is let
                // go when it is not (029).
                StartAgentView(project: folder)
                    .paperGround()
            }
        case .page(let path):
            if let folder = model.selectedProject {
                if let pin = model.pins(in: folder).first(where: { $0.path == path }), let view = pin.view {
                    // A pinned view (#189), fed afresh, through the host a chat's views use.
                    PinnedViewPage(folder: folder, pin: pin, view: view,
                                   call: { method, params in try await model.viewCall(method, params) },
                                   unpin: { await model.unpin(path, in: folder) },
                                   startAgent: { start in
                                       guard let key = model.work.project(folder)?.key else {
                                           return "This project isn’t one the phone knows."
                                       }
                                       return model.offerStart(start, in: key)
                                   },
                                   recipient: { message in
                                       model.work.project(folder).flatMap { model.recipient(of: message, in: $0.key) }
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

/// Somewhere to go over the project: the detail's own page, or one pushed over it.
enum RemoteRoute: Hashable {
    case workflow(Workflow.ID)
    case agent(UUID)
    /// A new session in the project (#366): its page when nothing is open over it.
    case start
    /// One of the project's pinned pages (#159), by its path in the project.
    case page(String)
    /// What the project has archived (#495, #498), from its Archived row in the sidebar.
    case archive
    /// The project's MCP servers (#753), from its MCP Servers row in the sidebar.
    case mcpServers

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

/// The project an iPhone shows alone (#1089), as the cover's item.
private struct PhoneProject: Identifiable {
    let key: ProjectKey
    var id: String { key.stored }
}

/// The project an iPhone shows alone (#1089), over every project, with ‹ All.
private struct PhoneProjectCover: ViewModifier {
    @Environment(RemoteModel.self) private var model

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(get: { model.phoneProject.map(PhoneProject.init) },
                                              set: { model.phoneProject = $0?.key })) { project in
            RemoteProjectScene(key: project.key, back: { model.phoneProject = nil })
                .environment(model)
        }
    }
}
