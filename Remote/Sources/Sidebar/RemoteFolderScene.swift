import AgentsKitCore
import SwiftUI
import UIKit

/// What one folder shown on its own has picked (#1089): an iPad scene of its own, or an
/// iPhone's screen of only that folder. Held by the model while it is open, so a
/// notification can open a session in it.
@MainActor @Observable
final class RemoteFolderState {
    let key: FolderKey
    var pick: SidebarItem?
    @ObservationIgnored fileprivate var scenes = 0

    init(key: FolderKey) { self.key = key }

    /// The scene a folder opens in (`RemoteApp`).
    static let sceneID = "folder"
}

extension RemoteModel {
    func openFolderState(_ key: FolderKey) -> RemoteFolderState {
        let state = folderScenes[key] ?? RemoteFolderState(key: key)
        state.scenes += 1
        if folderScenes[key] == nil { folderScenes[key] = state }
        return state
    }

    func closeFolderState(_ state: RemoteFolderState) {
        state.scenes -= 1
        guard state.scenes <= 0, folderScenes[state.key] === state else { return }
        folderScenes[state.key] = nil
        if composingScene == state.key { composingScene = nil }
        startPagesMoved()
    }

    /// A session in its folder's own scene or screen, when one is open (#1089): what a
    /// notification does. False when there is none, for the sidebar of every folder.
    func showInFolderScene(_ id: UUID) -> Bool {
        guard let agent = work.agent(id),
              let state = folderScenes[FolderKey(host: agent.host, folder: agent.folderPath)] else { return false }
        state.pick = .session(id)
        if phoneFolder != state.key { openFolderScene?(state.key) }
        return true
    }

    /// The sessions in other folders that need the person (#1089): what "elsewhere" counts.
    func needingYou(besides key: FolderKey) -> (count: Int, first: Agent?) {
        let others = folders.map(\.key).filter { $0 != key }
        let on = SidebarSmartRow.on(off: UserDefaults.standard.string(forKey: SidebarSmartRow.offDefaultsKey)
            ?? SidebarSmartRow.offAtFirst)
        let first = SidebarSmartRow.needsYou.agents(in: work, folders: others, query: "", on: on).first
        return (SidebarSmartRow.needsYou.count(in: work, folders: others, on: on), first)
    }
}

/// A folder on its own (#1089): a sidebar of only this folder — New Session, its Pinned
/// and Needs You, its sessions, workflows and pages — and what it picks. In a scene of its
/// own on an iPad, beside the main one; on an iPhone, the screen, with ‹ All to go back.
/// The sidebar of every folder is not touched by it.
struct RemoteFolderScene: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    let key: FolderKey?
    /// ‹ All, on an iPhone: back to the sidebar of every folder. None in a scene.
    var back: (() -> Void)? = nil
    @State private var state: RemoteFolderState?
    @State private var chat: PoppedChat?
    @State private var sceneID = UUID()

    private var summary: DaemonAPI.FolderSummary? {
        key.flatMap { key in model.folders.first { $0.key == key } }
    }

    var body: some View {
        Group {
            if let state, let summary {
                RemoteFolderColumns(state: state, summary: summary, chat: chat, back: back)
            } else if key == nil || !model.folders.isEmpty {
                ContentUnavailableView("This folder is not open", systemImage: "folder.badge.questionmark",
                                       description: Text("It has been archived or removed."))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Paper.ground)
        .task(id: key) {
            guard let key, state?.key != key else { return }
            if let state { model.closeFolderState(state) }
            state = model.openFolderState(key)
            model.openFolderScene = { [openWindow] in openWindow(id: RemoteFolderState.sceneID, value: $0) }
            // Restored on its own, with no main scene to start the link.
            if back == nil { Task { await model.connect() } }
        }
        .onChange(of: state?.pick) { _, pick in follow(pick) }
        .onChange(of: state != nil) { follow(state?.pick) }
        .onDisappear {
            if let chat { model.closePopout(chat) }
            chat = nil
            if let state { model.closeFolderState(state) }
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

/// The folder's sidebar and what it picked, as the main scene's split view: side by
/// side on an iPad, one screen at a time on an iPhone.
private struct RemoteFolderColumns: View {
    @Environment(RemoteModel.self) private var model
    let state: RemoteFolderState
    let summary: DaemonAPI.FolderSummary
    let chat: PoppedChat?
    let back: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            RemoteFolderSidebar(state: state, summary: summary, back: back)
        } detail: {
            NavigationStack {
                detail
            }
            .id(state.pick)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.sceneFolder, state.key)
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
        case .folder:
            StartAgentView(folder: summary.folder.folder)
                .paperGround()
        case nil:
            // Only New Session opens the start page (#2090), as in the sidebar of every folder.
            NothingPickedPage()
                .paperGround()
        default:
            ContentUnavailableView("Open it in All Folders", systemImage: "sidebar.left",
                                   description: Text("This page opens in the sidebar of every folder."))
        }
    }
}

/// The folder's own sidebar (#1089): no Status, no Usage and no other folders.
private struct RemoteFolderSidebar: View {
    @Environment(RemoteModel.self) private var model
    @AppStorage(SidebarSmartRow.offDefaultsKey) private var smartOff = SidebarSmartRow.offAtFirst
    let state: RemoteFolderState
    let summary: DaemonAPI.FolderSummary
    let back: (() -> Void)?
    /// Its own folds: Sessions folded here leaves the main sidebar's folder open.
    @State private var folds = SidebarFolds(scope: ".folderScene")

    /// Pinned and Needs You, as Settings ▸ Sidebar has them on: Working and Unread are
    /// this folder's sessions, so they stay in its list.
    private var groups: Set<SidebarSmartRow> {
        SidebarSmartRow.on(off: smartOff).intersection([.pinned, .needsYou])
    }

    private var label: String { SidebarOrder.label(summary) { model.hostLabel($0) } }

    var body: some View {
        // A list clears its selection by itself while rows come and go, as an archived
        // session's does, and that must not empty the detail (#2090), as `RemoteSidebar`'s.
        List(selection: Binding(get: { state.pick }, set: { pick in
            guard let pick else { return }
            state.pick = pick
            // Its New Session is the next one at the top of every folder's sidebar too (#2160).
            if case .folder(let key) = pick { model.rememberNewSessionFolder(key) }
        })) {
            Section {
                Label("New Session", systemImage: "square.and.pencil")
                    .appText(.supporting)
                    .tag(SidebarItem.folder(summary.key))
            }
            ForEach(SidebarSmartRow.allCases.filter(groups.contains), id: \.self) { row in
                RemoteSmartFold(row: row, folders: [summary], folds: folds, query: "", groups: groups)
            }
            RemoteFolderFold(summary: summary, folds: folds, query: "", label: label,
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
                    .accessibilityLabel("All folders")
                }
            }
        }
        .shows([.workflows, .pins, .leases])
        .onAppear { folds.set(summary.key, open: true) }
    }
}

/// "✋ N elsewhere" (#1089): sessions in other folders need the person. A tap goes to the
/// first, in the sidebar of every folder.
private struct ElsewhereRow: View {
    @Environment(RemoteModel.self) private var model
    let key: FolderKey
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
                .accessibilityHint("Goes to a session in another folder that needs you")
            }
        }
    }
}

/// The folder alone (#1089), from its heading's menu: a scene of its own where the
/// device has more than one, the screen on an iPhone.
struct OpenFolderButton: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    let key: FolderKey

    var body: some View {
        if supportsMultipleWindows {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openWindow(id: RemoteFolderState.sceneID, value: key)
            }
        } else {
            Button("Open Folder Alone", systemImage: "rectangle.portrait") {
                model.phoneFolder = key
            }
        }
    }
}

extension EnvironmentValues {
    /// The folder shown on its own here (#1089); nil in the sidebar of every folder.
    @Entry var sceneFolder: FolderKey? = nil
}
