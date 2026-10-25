import AgentsKitCore
import AppKit
import SwiftUI

/// The scene of a folder's own window (#1089): one per folder, restored at launch.
enum FolderWindowScene {
    /// The scene id (`AgentsApp`), and how `MainWindow` tells its windows from the main one.
    static let id = "folder"
}

/// What one folder's own window shows (#1089): its pick, and the inspector, shell and
/// sheets that are this window's and not the main window's. Held by the model while the
/// window is open, so a notification or the "elsewhere" button can open a session in it.
@MainActor @Observable
final class FolderWindowState {
    let key: FolderKey
    /// What its sidebar has picked: a session, the new session, a workflow or a page.
    var pick: SidebarItem?
    /// A session just started here: its chat opens without the inspector (#358).
    var justStarted: UUID?
    /// Its own inspector, kept for this folder's window (Alex, #1089).
    let frame: SidebarFrame
    let terminal = FolderTerminalFrame()
    let requests = WindowRequests()
    let states = SidebarStates()
    /// Its Browser panes' pages, kept as the main window keeps its own.
    let webHolders = WebHolders()
    @ObservationIgnored fileprivate var windows = 0

    init(key: FolderKey) {
        self.key = key
        frame = SidebarFrame(keyedBy: "folder.\(key.stored)")
    }

    func show(started id: UUID) {
        justStarted = id
        pick = .session(id)
    }
}

extension AppModel {
    /// A folder's window has opened (#1089).
    func openFolderWindowState(_ key: FolderKey) -> FolderWindowState {
        let window = folderWindows[key] ?? FolderWindowState(key: key)
        window.windows += 1
        if folderWindows[key] == nil { folderWindows[key] = window }
        return window
    }

    /// Its window has closed. The last one lets it go.
    func closeFolderWindowState(_ window: FolderWindowState) {
        window.windows -= 1
        guard window.windows <= 0, folderWindows[window.key] === window else { return }
        folderWindows[window.key] = nil
        if composingWindow == window.key { composingWindow = nil }
    }

    /// A session in its folder's own window, when one is open (#1089): what a
    /// notification and "elsewhere" do. False when there is none, for the main window.
    @discardableResult
    func showInFolderWindow(_ id: UUID) -> Bool {
        guard let agent = work.agent(id),
              let window = folderWindows[FolderKey(host: agent.host, folder: agent.folderPath)] else { return false }
        window.pick = .session(id)
        openFolderWindow?(window.key)
        return true
    }

    /// The sessions in other folders that need the person (#1089): what "elsewhere" counts.
    func needingYou(besides key: FolderKey) -> (count: Int, first: Agent?) {
        let others = liveFolders.map(\.key).filter { $0 != key }
        let on = SidebarSmartRow.on(off: WindowDefaults.store.string(forKey: SidebarSmartRow.offDefaultsKey)
            ?? SidebarSmartRow.offAtFirst)
        let first = SidebarSmartRow.needsYou.agents(in: work, folders: others, query: "", on: on).first
        return (SidebarSmartRow.needsYou.count(in: work, folders: others, on: on), first)
    }
}

/// A folder in a window of its own (#1089): a sidebar of only this folder, and what it
/// picks beside it, with the inspector and the folder's shell as the main window has
/// them. The main window is not touched by it.
struct FolderWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive
    /// The folder, as the window was opened with it and is restored with it.
    let key: FolderKey?
    @State private var window: FolderWindowState?
    /// The picked session's own page of its transcript, as a session's window has (#826).
    @State private var chat: PoppedChat?

    private var summary: DaemonAPI.FolderSummary? {
        key.flatMap { key in model.liveFolders.first { $0.key == key } }
    }

    var body: some View {
        Group {
            if let window, let summary {
                FolderWindowColumns(window: window, summary: summary, chat: chat)
            } else if key == nil || model.hasLoadedFolders {
                ContentUnavailableView("This folder is not open", systemImage: "folder.badge.questionmark",
                                       description: Text("It has been archived or removed. Close this window."))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .paperGround()
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(AppCheckout.windowTitle(summary?.name))
        .navigationSubtitle(summary.map(place) ?? "")
        .focusedSceneValue(\.folderWindow, window)
        .tint(Paper.accent)
        .task(id: key) {
            guard let key, window?.key != key else { return }
            if let window { model.closeFolderWindowState(window) }
            window = model.openFolderWindowState(key)
            model.openFolderWindow = { [openWindow] in openWindow(id: FolderWindowScene.id, value: $0) }
        }
        .onChange(of: window?.pick) { _, pick in follow(pick) }
        .onChange(of: window != nil) { follow(window?.pick) }
        .onChange(of: appearsActive, initial: true) {
            if let chat { model.popout(chat.id, isInFront: appearsActive) }
        }
        .onDisappear {
            if let chat { model.closePopout(chat) }
            chat = nil
            if let window { model.closeFolderWindowState(window) }
            window = nil
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
        let opened = model.openPopout(id)
        chat = opened
        model.popout(id, isInFront: appearsActive)
        // A chat just started opens on the chat alone (#358).
        if window?.justStarted == id {
            window?.justStarted = nil
            window?.frame.isOpen = false
        }
    }

    /// "this Mac", or the server's name: where the folder is.
    private func place(_ summary: DaemonAPI.FolderSummary) -> String {
        model.isOnThisMac(summary.host) ? "this Mac" : model.hosts.label(summary.host)
    }
}

/// The two columns of a folder's window: its sidebar and what is picked in it.
private struct FolderWindowColumns: View {
    @Environment(AppModel.self) private var model
    let window: FolderWindowState
    let summary: DaemonAPI.FolderSummary
    let chat: PoppedChat?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            FolderWindowSidebar(window: window, summary: summary)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            GeometryReader { pane in
                VStack(spacing: 0) {
                    detail(inPaneOf: pane.size.width)
                        .frame(maxHeight: .infinity)
                    if window.terminal.isOpen, summary.exists {
                        FolderTerminalPanel(folder: summary, pageHeight: pane.size.height)
                    }
                }
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { window.frame.windowWidth = $0 }
            .toolbar {
                FolderWindowToolbar(window: window, summary: summary, showsChat: chat != nil,
                                     agent: chat.flatMap { model.work.agent($0.id) })
            }
        }
        .environment(window.frame)
        .environment(window.terminal)
        .environment(window.requests)
        .environment(window.states)
        .environment(window.webHolders)
        .environment(\.windowFolder, window.key)
        .environment(\.windowOpen, WindowOpener(window: window))
        .environment(\.windowPick, window.pick)
        // A file a chat links to is on the folder's host, as in the main window.
        .environment(\.openURL, OpenURLAction { url in
            guard let fileURL = ChatLinkURL.fileURL(from: url) else { return .systemAction }
            model.open(fileURL, on: summary.host)
            return .handled
        })
        // The folder's settings, over this window (066).
        .sheet(isPresented: Binding(get: { window.requests.folderSettings != nil },
                                    set: { if !$0 { window.requests.folderSettings = nil } })) {
            FolderSettingsSheet(pane: Binding(get: { window.requests.folderSettings },
                                               set: { window.requests.folderSettings = $0 }))
                .environment(window.requests)
                .paperSheet()
        }
    }

    @ViewBuilder
    private func detail(inPaneOf width: CGFloat) -> some View {
        switch window.pick {
        case .session:
            if let chat {
                HStack(spacing: 0) {
                    ChatView()
                        .frame(maxWidth: .infinity)
                    if window.frame.isOpen, SidebarFrame.fits(inWindowOf: width) {
                        SidebarView(windowWidth: width)
                            .transition(.move(edge: .trailing))
                    }
                }
                .environment(\.poppedChat, chat)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { window.frame.paneWidth = $0 }
                .paperGround()
            }
        case .workflow(let id, _):
            WorkflowPage(workflowID: id).paperGround()
        case .archive(let key):
            FolderWorkPage(page: .archive, folder: key).paperGround()
        case .folderMCPServers(let key):
            MCPServersView(folder: key).paperGround()
        case .review(let id, let key):
            ReviewDestination(id: id, folder: key).paperGround()
        case .pin(let path, let key):
            // A pinned view, or a server's list view (#2032), as the main window draws it.
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
                               connected: model.isConnected)
                    .id(pin.path)
                    .paperGround()
            } else {
                PinnedPage(folder: key, path: path).paperGround()
            }
        default:
            // The folder itself, or nothing picked yet: a new session in it, the empty chat
            // with its prompt (066).
            FolderAgentsView(selection: Binding(get: { nil }, set: { id in id.map { window.pick = .session($0) } }))
                .paperGround()
        }
    }
}

/// A folder's window's sidebar (#1089): New Session, Pinned and Needs You of this
/// folder only, its sessions, workflows and pages, and Folder Settings… at the foot.
/// No Status, no Usage and no other folders: those are the main window's.
private struct FolderWindowSidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SidebarSmartRow.offDefaultsKey, store: WindowDefaults.store) private var smartOff = SidebarSmartRow.offAtFirst
    let window: FolderWindowState
    let summary: DaemonAPI.FolderSummary
    /// Its own folds: Sessions folded here leaves the main window's folder open.
    @State private var folds = SidebarFolds(defaults: WindowDefaults.store, scope: ".folderWindow")
    @State private var picked: Set<SidebarItem> = []
    @FocusState private var listFocused: Bool

    /// Pinned and Needs You, as Settings ▸ Sidebar has them on: Working and Unread are
    /// this folder's sessions, so they stay in its list (#1089).
    private var smartGroups: Set<SidebarSmartRow> {
        SidebarSmartRow.on(off: smartOff).intersection([.pinned, .needsYou])
    }

    var body: some View {
        List(selection: $picked) {
            Section {
                FolderNewSessionRow(folder: summary.key)
            }
            ForEach(SidebarSmartRow.allCases.filter(smartGroups.contains), id: \.self) { row in
                SmartFold(row: row, folders: [summary.key], folds: folds, query: "")
            }
            FolderFold(summary: summary, folds: folds, query: "", smartGroups: smartGroups, inWindow: true)
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .environment(\.sidebarPicks, SidebarPicks(items: picked, listFocused: listFocused))
        .environment(\.sidebarRowSize, .small)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    window.requests.folderSettings = .general
                } label: {
                    Label("Folder Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .appText(.supporting)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider() }
        }
        .onAppear { folds.set(summary.key, open: true) }
        .onChange(of: picked) { _, picks in
            if picks.count == 1, let pick = picks.first, window.pick != pick { window.pick = pick }
        }
        .onChange(of: window.pick, initial: true) { _, pick in
            if let pick, !picked.contains(pick) { picked = [pick] }
        }
    }
}

/// New Session at the top of a folder's window: in this folder, with no menu of others.
private struct FolderNewSessionRow: View {
    @Environment(WindowRequests.self) private var requests
    let folder: FolderKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .sidebarMark(Paper.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text("New Session")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { requests.focusPrompt() })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New Session")
        .sidebarInk(.folder(folder))
        .tag(SidebarItem.folder(folder))
    }
}

/// A folder's window's toolbar: "✋ N elsewhere" while another folder's session needs
/// the person, Rename for the session shown (#1452), the folder's shell, and the
/// inspector beside a chat.
private struct FolderWindowToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let window: FolderWindowState
    let summary: DaemonAPI.FolderSummary
    let showsChat: Bool
    /// The session whose chat the window shows.
    let agent: Agent?

    var body: some ToolbarContent {
        ToolbarItemGroup {
            let elsewhere = model.needingYou(besides: summary.key)
            if elsewhere.count > 0 {
                Button {
                    guard let agent = elsewhere.first else { return }
                    // In its own folder's window when that is open, else the main window.
                    if !model.showInFolderWindow(agent.id) { model.showInMainWindow(agent.id, opening: openWindow) }
                } label: {
                    Label("✋ \(elsewhere.count) elsewhere", systemImage: "hand.raised")
                        .labelStyle(.titleOnly)
                }
                .help("Sessions in other folders need you. Go to the first.")
            }
            // Here, not only in the main window's, so Session ▸ Rename… has a field in
            // this window (#1452).
            if showsChat, let agent {
                RenameButton(agent: agent, place: .folderWindow(window.key))
            }
            Button {
                window.terminal.toggle()
            } label: {
                Label("Shell", systemImage: "apple.terminal")
            }
            .disabled(!summary.exists)
            .help("The folder's own shell (⌃`)")
            if showsChat {
                SidebarToggle(windowWidth: window.frame.windowWidth)
            }
        }
    }
}

extension EnvironmentValues {
    /// The folder whose own window this is (#1089); nil in the main window.
    @Entry var windowFolder: FolderKey? = nil
    /// How a folder's own window opens what is picked on its pages (#1090): a session, or
    /// nil for the folder itself. Nil in the main window, whose selection does it.
    @Entry var windowOpen: WindowOpener? = nil
    /// What a folder's own window has picked (#1090), for its pages' lists to light.
    @Entry var windowPick: SidebarItem? = nil
}

extension FocusedValues {
    /// The key window's folder, when that is a folder's own window (#1089): what the
    /// menus act on then, rather than the main window's.
    @Entry var folderWindow: FolderWindowState?
}

/// The Dock's menu (#1089): each folder, to open in a window of its own; no window tabs (#2384).
final class AgentsAppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, handed over when the app starts.
    @MainActor static weak var model: AppModel?

    /// No tabs: the only way left to a second window, and a second window would be a
    /// mirror of the first, because what is selected lives on the one model. Before the
    /// launch finishes, when AppKit puts its tab items in the View menu; turned off later,
    /// they left a blank row at its end (#2384).
    @MainActor func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @MainActor func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = Self.model, model.openFolderWindow != nil else { return nil }
        let menu = NSMenu()
        let folders = SidebarOrder.folders(model.liveFolders, servers: model.hosts.servers)
        for summary in folders {
            let item = NSMenuItem(title: SidebarOrder.label(summary) { model.hosts.label($0) },
                                  action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = summary.key.stored
            menu.addItem(item)
        }
        return menu
    }

    @MainActor @objc private func open(_ item: NSMenuItem) {
        guard let stored = item.representedObject as? String, let key = FolderKey(stored: stored) else { return }
        NSApp.activate()
        Self.model?.openFolderWindow?(key)
    }
}

/// How a folder's own window opens what its pages pick (#1090): one per window, the same
/// while the window is, so the views that read it are not drawn again for nothing.
@MainActor
struct WindowOpener: Equatable {
    let window: FolderWindowState

    /// A session, a workflow or a page in this window; nil for the folder itself.
    func callAsFunction(_ item: SidebarItem?) {
        window.pick = item ?? .folder(window.key)
    }

    nonisolated static func == (a: WindowOpener, b: WindowOpener) -> Bool { a.window === b.window }
}
