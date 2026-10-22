import AgentsKitCore
import SwiftUI
import UIKit

/// What one project shown on its own has picked (#1089): an iPad scene of its own, or an
/// iPhone's screen of only that project. Held by the model while it is open, so a
/// notification can open a session in it.
@MainActor @Observable
final class RemoteProjectState {
    let key: ProjectKey
    var pick: SidebarItem?
    @ObservationIgnored fileprivate var scenes = 0

    init(key: ProjectKey) { self.key = key }

    /// The scene a project opens in (`RemoteApp`).
    static let sceneID = "project"
}

extension RemoteModel {
    func openProjectState(_ key: ProjectKey) -> RemoteProjectState {
        let state = projectScenes[key] ?? RemoteProjectState(key: key)
        state.scenes += 1
        if projectScenes[key] == nil { projectScenes[key] = state }
        return state
    }

    func closeProjectState(_ state: RemoteProjectState) {
        state.scenes -= 1
        guard state.scenes <= 0, projectScenes[state.key] === state else { return }
        projectScenes[state.key] = nil
        if composingScene == state.key { composingScene = nil }
        startPagesMoved()
    }

    /// A session in its project's own scene or screen, when one is open (#1089): what a
    /// notification does. False when there is none, for the sidebar of every project.
    func showInProjectScene(_ id: UUID) -> Bool {
        guard let agent = work.agent(id),
              let state = projectScenes[ProjectKey(host: agent.host, folder: agent.projectFolder)] else { return false }
        state.pick = .session(id)
        if phoneProject != state.key { openProjectScene?(state.key) }
        return true
    }

    /// The sessions in other projects that need the person (#1089): what "elsewhere" counts.
    func needingYou(besides key: ProjectKey) -> (count: Int, first: Agent?) {
        let others = projects.map(\.key).filter { $0 != key }
        let on = SidebarSmartRow.on(off: UserDefaults.standard.string(forKey: SidebarSmartRow.offDefaultsKey)
            ?? SidebarSmartRow.offAtFirst)
        let first = SidebarSmartRow.needsYou.agents(in: work, projects: others, query: "", on: on).first
        return (SidebarSmartRow.needsYou.count(in: work, projects: others, on: on), first)
    }
}

/// A project on its own (#1089): a sidebar of only this project — New Session, its Pinned
/// and Needs You, its sessions, workflows and pages — and what it picks. In a scene of its
/// own on an iPad, beside the main one; on an iPhone, the screen, with ‹ All to go back.
/// The sidebar of every project is not touched by it.
struct RemoteProjectScene: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    let key: ProjectKey?
    /// ‹ All, on an iPhone: back to the sidebar of every project. None in a scene.
    var back: (() -> Void)? = nil
    @State private var state: RemoteProjectState?
    @State private var chat: PoppedChat?
    @State private var sceneID = UUID()

    private var summary: DaemonAPI.ProjectSummary? {
        key.flatMap { key in model.projects.first { $0.key == key } }
    }

    var body: some View {
        Group {
            if let state, let summary {
                RemoteProjectColumns(state: state, summary: summary, chat: chat, back: back)
            } else if key == nil || !model.projects.isEmpty {
                ContentUnavailableView("This project is not open", systemImage: "folder.badge.questionmark",
                                       description: Text("It has been archived or removed."))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Paper.ground)
        .task(id: key) {
            guard let key, state?.key != key else { return }
            if let state { model.closeProjectState(state) }
            state = model.openProjectState(key)
            model.openProjectScene = { [openWindow] in openWindow(id: RemoteProjectState.sceneID, value: $0) }
            // Restored on its own, with no main scene to start the link.
            if back == nil { Task { await model.connect() } }
        }
        .onChange(of: state?.pick) { _, pick in follow(pick) }
        .onChange(of: state != nil) { follow(state?.pick) }
        .onDisappear {
            if let chat { model.closePopout(chat) }
            chat = nil
            if let state { model.closeProjectState(state) }
            state = nil
        }
        .onKeyWindowChange { isKey in
            if let chat { model.popout(chat.id, isInFront: isKey) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if back == nil { model.scenePhase(phase, of: sceneID) }
        }
    }

    /// A session picked opens its own page of the transcript; anything else lets it go.
    private func follow(_ pick: SidebarItem?) {
        guard case .session(let id) = pick else {
            if let chat { model.closePopout(chat) }
            chat = nil
            return
        }
        guard chat?.id != id else { return }
        if let chat { model.closePopout(chat) }
        chat = model.openPopout(id)
    }
}

/// The project's sidebar and what it picked, as the main scene's split view: side by
/// side on an iPad, one screen at a time on an iPhone.
private struct RemoteProjectColumns: View {
    @Environment(RemoteModel.self) private var model
    let state: RemoteProjectState
    let summary: DaemonAPI.ProjectSummary
    let chat: PoppedChat?
    let back: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            RemoteProjectSidebar(state: state, summary: summary, back: back)
        } detail: {
            NavigationStack {
                detail
            }
            .id(state.pick)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.sceneProject, state.key)
        // Nothing left to show, as after Archive: back to the list on an iPhone (#2090).
        .onChange(of: state.pick) { _, pick in
            model.startPagesMoved()
            compactColumn = pick != nil ? .detail : .sidebar
        }
        // Back to the list on an iPhone puts the pick down, so the same row opens it
        // again (#2191), as the main scene's.
        .onChange(of: compactColumn) { _, column in
            if column == .sidebar, sizeClass == .compact { state.pick = nil }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.pick {
        case .session:
            if let chat {
                RemoteChatView()
                    .paperGround()
                    .environment(\.poppedChat, chat)
            }
        case .project:
            StartAgentView(project: summary.folder)
                .paperGround()
        case nil:
            // Only New Session opens the start page (#2090), as in the sidebar of every project.
            NothingPickedPage()
                .paperGround()
        default:
            ContentUnavailableView("Open it in All Projects", systemImage: "sidebar.left",
                                   description: Text("This page opens in the sidebar of every project."))
        }
    }
}

/// The project's own sidebar (#1089): no Status, no Usage and no other projects.
private struct RemoteProjectSidebar: View {
    @Environment(RemoteModel.self) private var model
    @AppStorage(SidebarSmartRow.offDefaultsKey) private var smartOff = SidebarSmartRow.offAtFirst
    let state: RemoteProjectState
    let summary: DaemonAPI.ProjectSummary
    let back: (() -> Void)?
    /// Its own folds: Sessions folded here leaves the main sidebar's project open.
    @State private var folds = SidebarFolds(scope: ".projectScene")

    /// Pinned and Needs You, as Settings ▸ Sidebar has them on: Working and Unread are
    /// this project's sessions, so they stay in its list.
    private var groups: Set<SidebarSmartRow> {
        SidebarSmartRow.on(off: smartOff).intersection([.pinned, .needsYou])
    }

    private var label: String { SidebarOrder.label(summary) { model.hostLabel($0) } }

    var body: some View {
        // A list clears its selection by itself while rows come and go, as an archived
        // session's does, and that must not empty the detail (#2090), as `RemoteSidebar`'s.
        List(selection: Binding(get: { state.pick }, set: { if let pick = $0 { state.pick = pick } })) {
            Section {
                Label("New Session", systemImage: "square.and.pencil")
                    .appText(.supporting)
                    .tag(SidebarItem.project(summary.key))
            }
            ForEach(SidebarSmartRow.allCases.filter(groups.contains), id: \.self) { row in
                RemoteSmartFold(row: row, projects: [summary], folds: folds, query: "", groups: groups)
            }
            RemoteProjectFold(summary: summary, folds: folds, query: "", label: label,
                              smartGroups: groups, inScene: true)
            ElsewhereRow(key: summary.key, back: back)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        .navigationTitle(label)
        .toolbar {
            if let back {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: back) {
                        Label("All", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("All projects")
                }
            }
        }
        .shows([.workflows, .pins, .leases])
        .onAppear { folds.set(summary.key, open: true) }
    }
}

/// "✋ N elsewhere" (#1089): sessions in other projects need the person. A tap goes to the
/// first, in the sidebar of every project.
private struct ElsewhereRow: View {
    @Environment(RemoteModel.self) private var model
    let key: ProjectKey
    let back: (() -> Void)?

    var body: some View {
        let elsewhere = model.needingYou(besides: key)
        if elsewhere.count > 0, let first = elsewhere.first {
            Section {
                Button {
                    back?()
                    model.open(first.id)
                } label: {
                    Text("✋ \(elsewhere.count) elsewhere")
                        .appText(.supporting)
                }
                .accessibilityHint("Goes to a session in another project that needs you")
            }
        }
    }
}

/// The project alone (#1089), from its heading's menu: a scene of its own where the
/// device has more than one, the screen on an iPhone.
struct OpenProjectButton: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    let key: ProjectKey

    var body: some View {
        if supportsMultipleWindows {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openWindow(id: RemoteProjectState.sceneID, value: key)
            }
        } else {
            Button("Open Project Alone", systemImage: "rectangle.portrait") {
                model.phoneProject = key
            }
        }
    }
}

extension EnvironmentValues {
    /// The project shown on its own here (#1089); nil in the sidebar of every project.
    @Entry var sceneProject: ProjectKey? = nil
}
