import AgentsKitCore
import SwiftUI

/// The remote: the same app, laid out for the screen it is on.
///
/// Scene-based from the first commit, with no `UIApplicationDelegate` anywhere, because
/// iOS 27 will not launch an app without the UIScene lifecycle and nothing about a
/// layout can be judged until it launches.
@main
struct RemoteApp: App {
    /// A fake Mac, until the bridge lands. Everything above this line is the real
    /// client over the real protocol; only what carries the bytes is pretend.
    @State private var model = RemoteModel(link: FakeDaemon())

    var body: some Scene {
        WindowGroup {
            RemoteView()
                .environment(model)
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

    /// The conversation, as a path of nothing or one. A chat is somewhere you go from
    /// the project and come back out of, not a third column.
    private var openAgent: Binding<[UUID]> {
        Binding(get: { model.selection.map { [$0] } ?? [] },
                set: { model.selection = $0.last })
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ProjectListView(selection: $model.selectedProject)
        } detail: {
            NavigationStack(path: openAgent) {
                ProjectPageView()
                    .navigationDestination(for: UUID.self) { _ in RemoteChatView() }
            }
        }
        .navigationSplitViewStyle(.balanced)
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
