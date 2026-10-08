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
    /// Which column a phone shows: the detail whenever something is picked.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    /// The project's own shell is up (#418).
    @State private var showsProjectTerminal = false

    /// What is open over the project, in the order each was opened from the one before:
    /// a pinned page, a workflow, a conversation. The first is the detail's own page, the
    /// one the sidebar lights; the rest are pushed over it. With none, the project's page
    /// is a new session in it (#366).
    private var routes: [RemoteRoute] {
        let open = [model.openPin.map(RemoteRoute.page),
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
        // Where this device is, told to the Mac on every change (021).
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhase(phase) }
        // A tap on the Home-screen widget (068). The one place a URL is taken from
        // outside the app, so it is checked and dropped rather than acted on by shape.
        .onOpenURL { model.openedFromTheWidget($0) }
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
        case .start:
            if let folder = model.selectedProject {
                // Held open while it is on screen: the runtime behind its choices is let
                // go when it is not (029).
                StartAgentView(project: folder)
                    .paperGround()
                    .onAppear { model.startingIn = folder }
                    .onDisappear { if model.startingIn == folder { model.startingIn = nil } }
            }
        case .page(let path):
            if let folder = model.selectedProject {
                if let pin = model.pins(in: folder).first(where: { $0.path == path }), let view = pin.view {
                    // A pinned view (#189), fed afresh, through the host a chat's views use.
                    PinnedViewPage(folder: folder, pin: pin, view: view,
                                   call: { method, params in try await model.viewCall(method, params) },
                                   unpin: { await model.unpin(path, in: folder) })
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
