import AgentsKitCore
import AppKit
import SwiftUI

/// The scene of a project's own window (#1089): one per project, restored at launch.
enum ProjectWindowScene {
    /// The scene id (`AgentsApp`), and how `MainWindow` tells its windows from the main one.
    static let id = "project"
}

/// What one project's own window shows (#1089): its pick, and the inspector, shell and
/// sheets that are this window's and not the main window's. Held by the model while the
/// window is open, so a notification or the "elsewhere" button can open a session in it.
@MainActor @Observable
final class ProjectWindowState {
    let key: ProjectKey
    /// What its sidebar has picked: a session, the new session, a workflow or a page.
    var pick: SidebarItem?
    /// A session just started here: its chat opens without the inspector (#358).
    var justStarted: UUID?
    /// Its own inspector, kept for this project's window (Alex, #1089).
    let frame: SidebarFrame
    let terminal = ProjectTerminalFrame()
    let requests = WindowRequests()
    let states = SidebarStates()
    /// Its Browser panes' pages, kept as the main window keeps its own.
    let webHolders = WebHolders()
    @ObservationIgnored fileprivate var windows = 0

    init(key: ProjectKey) {
        self.key = key
        frame = SidebarFrame(keyedBy: "project.\(key.stored)")
    }

    func show(started id: UUID) {
        justStarted = id
        pick = .session(id)
    }
}

extension AppModel {
    /// A project's window has opened (#1089).
    func openProjectWindowState(_ key: ProjectKey) -> ProjectWindowState {
        let window = projectWindows[key] ?? ProjectWindowState(key: key)
        window.windows += 1
        if projectWindows[key] == nil { projectWindows[key] = window }
        return window
    }

    /// Its window has closed. The last one lets it go.
    func closeProjectWindowState(_ window: ProjectWindowState) {
        window.windows -= 1
        guard window.windows <= 0, projectWindows[window.key] === window else { return }
        projectWindows[window.key] = nil
        if composingWindow == window.key { composingWindow = nil }
    }

    /// A session in its project's own window, when one is open (#1089): what a
    /// notification and "elsewhere" do. False when there is none, for the main window.
    @discardableResult
    func showInProjectWindow(_ id: UUID) -> Bool {
        guard let agent = work.agent(id),
              let window = projectWindows[ProjectKey(host: agent.host, folder: agent.projectFolder)] else { return false }
        window.pick = .session(id)
        openProjectWindow?(window.key)
        return true
    }

    /// The sessions in other projects that need the person (#1089): what "elsewhere" counts.
    func needingYou(besides key: ProjectKey) -> (count: Int, first: Agent?) {
        let others = liveProjects.map(\.key).filter { $0 != key }
        let on = SidebarSmartRow.on(off: WindowDefaults.store.string(forKey: SidebarSmartRow.offDefaultsKey)
            ?? SidebarSmartRow.offAtFirst)
        let first = SidebarSmartRow.needsYou.agents(in: work, projects: others, query: "", on: on).first
        return (SidebarSmartRow.needsYou.count(in: work, projects: others, on: on), first)
    }
}

/// A project in a window of its own (#1089): a sidebar of only this project, and what it
/// picks beside it, with the inspector and the project's shell as the main window has
/// them. The main window is not touched by it.
struct ProjectWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive
    /// The project, as the window was opened with it and is restored with it.
    let key: ProjectKey?
    @State private var window: ProjectWindowState?
    /// The picked session's own page of its transcript, as a session's window has (#826).
    @State private var chat: PoppedChat?

    private var summary: DaemonAPI.ProjectSummary? {
        key.flatMap { key in model.liveProjects.first { $0.key == key } }
    }

    var body: some View {
        Group {
            if let window, let summary {
                ProjectWindowColumns(window: window, summary: summary, chat: chat)
            } else if key == nil || model.hasLoadedProjects {
                ContentUnavailableView("This project is not open", systemImage: "folder.badge.questionmark",
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
        .focusedSceneValue(\.projectWindow, window)
        .tint(Paper.accent)
        .task(id: key) {
            guard let key, window?.key != key else { return }
            if let window { model.closeProjectWindowState(window) }
            window = model.openProjectWindowState(key)
            model.openProjectWindow = { [openWindow] in openWindow(id: ProjectWindowScene.id, value: $0) }
        }
        .onChange(of: window?.pick) { _, pick in follow(pick) }
        .onChange(of: window != nil) { follow(window?.pick) }
        .onChange(of: appearsActive, initial: true) {
            if let chat { model.popout(chat.id, isInFront: appearsActive) }
        }
        .onDisappear {
            if let chat { model.closePopout(chat) }
            chat = nil
            if let window { model.closeProjectWindowState(window) }
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

    /// "this Mac", or the server's name: where the project is.
    private func place(_ summary: DaemonAPI.ProjectSummary) -> String {
        model.isOnThisMac(summary.host) ? "this Mac" : model.hosts.label(summary.host)
    }
}

/// The two columns of a project's window: its sidebar and what is picked in it.
private struct ProjectWindowColumns: View {
    @Environment(AppModel.self) private var model
    let window: ProjectWindowState
    let summary: DaemonAPI.ProjectSummary
    let chat: PoppedChat?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ProjectWindowSidebar(window: window, summary: summary)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            GeometryReader { pane in
                VStack(spacing: 0) {
                    detail(inPaneOf: pane.size.width)
                        .frame(maxHeight: .infinity)
                    if window.terminal.isOpen, summary.exists {
                        ProjectTerminalPanel(project: summary, pageHeight: pane.size.height)
                    }
                }
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { window.frame.windowWidth = $0 }
            .toolbar {
                ProjectWindowToolbar(window: window, summary: summary, showsChat: chat != nil,
                                     agent: chat.flatMap { model.work.agent($0.id) })
            }
        }
        .environment(window.frame)
        .environment(window.terminal)
        .environment(window.requests)
        .environment(window.states)
        .environment(window.webHolders)
        .environment(\.windowProject, window.key)
        .environment(\.windowOpen, WindowOpener(window: window))
        .environment(\.windowPick, window.pick)
        // A file a chat links to is on the project's host, as in the main window.
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL else { return .systemAction }
            model.open(url, on: summary.host)
            return .handled
        })
        // The project's settings, over this window (066).
        .sheet(isPresented: Binding(get: { window.requests.projectSettings != nil },
                                    set: { if !$0 { window.requests.projectSettings = nil } })) {
            ProjectSettingsSheet(pane: Binding(get: { window.requests.projectSettings },
                                               set: { window.requests.projectSettings = $0 }))
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
            ProjectWorkPage(page: .archive, project: key).paperGround()
        case .projectMCPServers(let key):
            MCPServersView(project: key).paperGround()
        case .review(let id, let key):
            ReviewDestination(id: id, project: key).paperGround()
        case .pin(let path, let key):
            PinnedPage(project: key, path: path).paperGround()
        default:
            // The project itself, or nothing picked yet: a new session in it, the empty chat
            // with its prompt (066).
            ProjectAgentsView(selection: Binding(get: { nil }, set: { id in id.map { window.pick = .session($0) } }))
                .paperGround()
        }
    }
}

/// A project's window's sidebar (#1089): New Session, Pinned and Needs You of this
/// project only, its sessions, workflows and pages, and Project Settings… at the foot.
/// No Status, no Usage and no other projects: those are the main window's.
private struct ProjectWindowSidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SidebarSmartRow.offDefaultsKey, store: WindowDefaults.store) private var smartOff = SidebarSmartRow.offAtFirst
    let window: ProjectWindowState
    let summary: DaemonAPI.ProjectSummary
    /// Its own folds: Sessions folded here leaves the main window's project open.
    @State private var folds = SidebarFolds(defaults: WindowDefaults.store, scope: ".projectWindow")
    @State private var picked: Set<SidebarItem> = []
    @FocusState private var listFocused: Bool

    /// Pinned and Needs You, as Settings ▸ Sidebar has them on: Working and Unread are
    /// this project's sessions, so they stay in its list (#1089).
    private var smartGroups: Set<SidebarSmartRow> {
        SidebarSmartRow.on(off: smartOff).intersection([.pinned, .needsYou])
    }

    var body: some View {
        List(selection: $picked) {
            Section {
                ProjectNewSessionRow(project: summary.key)
            }
            ForEach(SidebarSmartRow.allCases.filter(smartGroups.contains), id: \.self) { row in
                SmartFold(row: row, projects: [summary.key], folds: folds, query: "")
            }
            ProjectFold(summary: summary, folds: folds, query: "", smartGroups: smartGroups, inWindow: true)
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
                    window.requests.projectSettings = .general
                } label: {
                    Label("Project Settings…", systemImage: "gearshape")
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

/// New Session at the top of a project's window: in this project, with no menu of others.
private struct ProjectNewSessionRow: View {
    @Environment(WindowRequests.self) private var requests
    let project: ProjectKey

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
        .sidebarInk(.project(project))
        .tag(SidebarItem.project(project))
    }
}

/// A project's window's toolbar: "✋ N elsewhere" while another project's session needs
/// the person, Rename for the session shown (#1452), the project's shell, and the
/// inspector beside a chat.
private struct ProjectWindowToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let window: ProjectWindowState
    let summary: DaemonAPI.ProjectSummary
    let showsChat: Bool
    /// The session whose chat the window shows.
    let agent: Agent?

    var body: some ToolbarContent {
        ToolbarItemGroup {
            let elsewhere = model.needingYou(besides: summary.key)
            if elsewhere.count > 0 {
                Button {
                    guard let agent = elsewhere.first else { return }
                    // In its own project's window when that is open, else the main window.
                    if !model.showInProjectWindow(agent.id) { model.showInMainWindow(agent.id, opening: openWindow) }
                } label: {
                    Label("✋ \(elsewhere.count) elsewhere", systemImage: "hand.raised")
                        .labelStyle(.titleOnly)
                }
                .help("Sessions in other projects need you. Go to the first.")
            }
            // Here, not only in the main window's, so Session ▸ Rename… has a field in
            // this window (#1452).
            if showsChat, let agent {
                RenameButton(agent: agent, place: .projectWindow(window.key))
            }
            Button {
                window.terminal.toggle()
            } label: {
                Label("Shell", systemImage: "apple.terminal")
            }
            .disabled(!summary.exists)
            .help("The project's own shell (⌃`)")
            if showsChat {
                SidebarToggle(windowWidth: window.frame.windowWidth)
            }
        }
    }
}

extension EnvironmentValues {
    /// The project whose own window this is (#1089); nil in the main window.
    @Entry var windowProject: ProjectKey? = nil
    /// How a project's own window opens what is picked on its pages (#1090): a session, or
    /// nil for the project itself. Nil in the main window, whose selection does it.
    @Entry var windowOpen: WindowOpener? = nil
    /// What a project's own window has picked (#1090), for its pages' lists to light.
    @Entry var windowPick: SidebarItem? = nil
}

extension FocusedValues {
    /// The key window's project, when that is a project's own window (#1089): what the
    /// menus act on then, rather than the main window's.
    @Entry var projectWindow: ProjectWindowState?
}

/// The Dock's menu (#1089): each project, to open in a window of its own.
final class AgentsAppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, handed over when the app starts.
    @MainActor static weak var model: AppModel?

    @MainActor func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = Self.model, model.openProjectWindow != nil else { return nil }
        let menu = NSMenu()
        let projects = SidebarOrder.projects(model.liveProjects, servers: model.hosts.servers)
        for summary in projects {
            let item = NSMenuItem(title: SidebarOrder.label(summary) { model.hosts.label($0) },
                                  action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = summary.key.stored
            menu.addItem(item)
        }
        return menu
    }

    @MainActor @objc private func open(_ item: NSMenuItem) {
        guard let stored = item.representedObject as? String, let key = ProjectKey(stored: stored) else { return }
        NSApp.activate()
        Self.model?.openProjectWindow?(key)
    }
}

/// How a project's own window opens what its pages pick (#1090): one per window, the same
/// while the window is, so the views that read it are not drawn again for nothing.
@MainActor
struct WindowOpener: Equatable {
    let window: ProjectWindowState

    /// A session, a workflow or a page in this window; nil for the project itself.
    func callAsFunction(_ item: SidebarItem?) {
        window.pick = item ?? .project(window.key)
    }

    nonisolated static func == (a: WindowOpener, b: WindowOpener) -> Bool { a.window === b.window }
}
