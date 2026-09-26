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

    /// The real Mac, found on the network it is on, unless `-fake` says otherwise.
    ///
    /// Nothing above this line knows which it got. That was the point of making the
    /// fake a `DaemonLink` rather than a fake model: the whole app moved from canned
    /// data to a live daemon by changing what it is handed.
    ///
    /// The fake is kept for the layout work — it holds a question waiting and a
    /// conversation long enough to page, neither of which a real Mac reliably has when
    /// somebody wants to look at a screen.
    ///
    /// The real one is two links (046): the Mac's own network when the phone is on it,
    /// and the relay through iCloud when it is not.
    @State private var model = RemoteModel(
        link: ProcessInfo.processInfo.arguments.contains("-fake")
            ? FakeDaemon()
            : AwayLink(device: RemoteModel.deviceID,
                       key: try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup)))

    var body: some Scene {
        WindowGroup {
            RemoteView()
                .background(Paper.ground)
                .environment(model)
                .task { push.received = { [model] userInfo in await model.receivedPush(userInfo) } }
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

    /// What is pushed over the project: a workflow's page, a conversation, or a
    /// conversation opened from a workflow's page, which goes back to it. A chat is
    /// somewhere you go from the project and come back out of, not a third column.
    private var path: Binding<[RemoteRoute]> {
        Binding(get: {
                    [model.openWorkflow.map(RemoteRoute.workflow), model.selection.map(RemoteRoute.agent)]
                        .compactMap { $0 }
                },
                set: { routes in
                    model.openWorkflow = routes.lazy.compactMap(\.workflowID).first
                    model.selection = routes.compactMap(\.agentID).last
                })
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ProjectListView(selection: $model.selectedProject)
        } detail: {
            NavigationStack(path: path) {
                ProjectPageView()
                    .paperGround()
                    .navigationDestination(for: RemoteRoute.self) { route in
                        switch route {
                        case .agent: RemoteChatView().paperGround()
                        case .workflow(let id): WorkflowPage(workflowID: id).paperGround()
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Where this device is, told to the Mac on every change (021).
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhase(phase) }
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
    }
}

/// Somewhere to go from the project page.
enum RemoteRoute: Hashable {
    case workflow(Workflow.ID)
    case agent(UUID)

    var workflowID: Workflow.ID? {
        if case .workflow(let id) = self { return id }
        return nil
    }

    var agentID: UUID? {
        if case .agent(let id) = self { return id }
        return nil
    }
}
