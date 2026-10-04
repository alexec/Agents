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
        }
    }
}

/// The three levels: projects, the project, the conversation.
///
/// A split view with two columns and a push, which is what the Mac shipped and what a
/// phone wants anyway. On a wide iPad the projects column stays beside the project; on
/// a phone it collapses and the same three levels are reached one at a time, each with
/// a way back.
struct RemoteView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// Which column a phone shows. Set to the project whenever one is chosen, so a tap
    /// on a project always opens it, whatever the list's selection was left at.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    /// What is pushed over the project: a workflow's page, a conversation, or a
    /// conversation opened from a workflow's page, which goes back to it. A chat is
    /// somewhere you go from the project and come back out of, not a third column.
    private var path: Binding<[RemoteRoute]> {
        Binding(get: {
                    [model.openDashboard ? RemoteRoute.dashboard : nil, model.openPin.map(RemoteRoute.page),
                     model.openWorkflow.map(RemoteRoute.workflow), model.selection.map(RemoteRoute.agent)]
                        .compactMap { $0 }
                },
                set: { routes in
                    model.openDashboard = routes.contains(.dashboard)
                    model.openPin = routes.lazy.compactMap(\.pinPath).first
                    model.openWorkflow = routes.lazy.compactMap(\.workflowID).first
                    model.selection = routes.compactMap(\.agentID).last
                })
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            ProjectListView(selection: $model.selectedProject, compactColumn: $compactColumn)
        } detail: {
            NavigationStack(path: path) {
                ProjectPageView()
                    .paperGround()
                    .navigationDestination(for: RemoteRoute.self) { route in
                        switch route {
                        case .agent(let id):
                            // Retired (051): nothing left to chat with, only who it was.
                            if model.selectedAgent == nil, let gone = model.work.tombstones[id] {
                                RetiredAgentPage(tombstone: gone).paperGround()
                            } else {
                                RemoteChatView().paperGround()
                                    .task(id: id) { await model.lookUpRetired(id) }
                            }
                        case .workflow(let id): WorkflowPage(workflowID: id).paperGround()
                        case .dashboard: DashboardPage().paperGround()
                        case .page(let path):
                            if let folder = model.selectedProject {
                                PinnedPage(folder: folder, path: path).paperGround()
                            }
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // A project opened for the person (a banner, a start) is shown, not only chosen.
        .onChange(of: model.selectedProject) { _, folder in
            if folder != nil { compactColumn = .detail }
        }
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
}

/// Somewhere to go from the project page.
enum RemoteRoute: Hashable {
    case workflow(Workflow.ID)
    case agent(UUID)
    /// The project's Dashboard (074).
    case dashboard
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
