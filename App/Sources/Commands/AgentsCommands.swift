import AgentsKitCore
import AppKit
import SwiftUI

/// What the menu bar asks of the window, for the things that live in a view's own
/// state rather than on the model: a sheet the folder list opens, and the prompt
/// taking the keyboard.
///
/// There is one window (New Window is gone from File, and tabbing is off), so one of
/// these, made by the app and handed to both the menus and the window.
@MainActor
@Observable
final class WindowRequests {
    enum FolderSheet: Equatable {
        /// A folder, or a clone, on this Mac or on a server (#495: the File menu is the
        /// one way in now the sidebar's New folder menu has gone).
        case chooseFolder(MachineRef = .mac), clone(MachineRef = .mac), addMachine
    }

    /// Set by a menu item, taken (and cleared) by `FolderListView`, which owns the sheets.
    var folderSheet: FolderSheet?

    /// Set to put the keyboard in a new session's prompt, and cleared by the prompt that
    /// takes it. A flag rather than an event, because New Session from inside a chat
    /// asks before the folder page — and its prompt — exists.
    var wantsPromptFocus = false

    /// Set to put the keyboard in the sidebar's search field.
    var wantsSessionSearchFocus = false

    /// Set by Find in Chat (#1532), taken (and cleared) by the main window's chat, which
    /// shows its find bar.
    var wantsChatFind = false

    /// Set by Prompts (#1658), taken (and cleared) by the main window's chat, which shows
    /// its Prompts list.
    var wantsPrompts = false

    /// Open File… is up over the window (#415), searching the open session's folders.
    var showsFileSearch = false

    /// The Folder Settings pane showing, or nil while the sheet is shut (066). Set by
    /// the toolbar, the folder's context menu, the menu bar and the folder's banner,
    /// and taken down by the sheet's Done.
    var folderSettings: FolderSettingsPane?

    /// The folder whose Drop Box sheet is up (#231), or nil. Set by the folder's
    /// context menu, taken down by the sheet's Done.
    var dropboxFolder: FolderKey?

    /// The folder and host of the Send to ‹host›… sheet that is up (#1123), or nil. Set by
    /// the folder's context menu, taken down by the sheet.
    var sendToHost: SendToHostRequest?

    /// The folder and host of the Bring back from ‹host›… sheet that is up (#1473), or nil.
    var bringBackFromHost: BringBackFromHostRequest?

    func focusPrompt() { wantsPromptFocus = true }
    func focusSessionSearch() { wantsSessionSearchFocus = true }
}

/// The menu bar: every action the window offers on a button or a context menu, in
/// the place a Mac user looks for it, with a key.
///
/// Archive is ⌥⌘⌫ rather than ⌘⌫. A menu's key equivalent is seen before the text
/// field's, and ⌘⌫ is "delete to the start of the line" in the prompt, which is where
/// the keyboard nearly always is.
struct AgentsCommands: Commands {
    let model: AppModel
    let requests: WindowRequests
    let frame: SidebarFrame
    let terminal: FolderTerminalFrame

    /// The session in the key window when that is a window of its own (#826).
    @FocusedValue(\.poppedChat) private var popped
    /// The folder in the key window when that is a folder's own (#1089).
    @FocusedValue(\.folderWindow) private var folderWindow
    /// A Markdown page on screen in the key window (#1419), for View ▸ Zoom.
    @FocusedValue(\.pageZoom) private var pageZoom
    @Environment(\.openWindow) private var openWindow
    /// Whether the chat draws the agent's thoughts (#1725), turned on and off here (#2383).
    @AppStorage(ChatThoughts.showsKey, store: WindowDefaults.store) private var showsThoughts = ChatThoughts.showsAtFirst

    /// What the Session menu acts on: the key window's session, which is the main
    /// window's selection unless a session's (#826) or a folder's (#1089) own window is
    /// in front.
    private var sessionAgent: Agent? {
        if let popped { return model.work.agent(popped.id) }
        if let folderWindow {
            guard case .session(let id)? = folderWindow.pick else { return nil }
            return model.work.agent(id)
        }
        return model.selectedAgent
    }

    /// The key window's inspector, shell and sheets: a folder's window has its own.
    private var keyFrame: SidebarFrame { folderWindow?.frame ?? frame }
    private var keyTerminal: FolderTerminalFrame { folderWindow?.terminal ?? terminal }
    private var keyRequests: WindowRequests { folderWindow?.requests ?? requests }
    /// The key window's folder: a folder's own window's, or the main window's selected one.
    private var keyFolder: DaemonAPI.FolderSummary? {
        guard let folderWindow else { return model.selectedFolderSummary }
        return model.liveFolders.first { $0.key == folderWindow.key }
    }

    var body: some Commands {
        // The standard Show/Hide Sidebar (⌃⌘S) for the folders column.
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Session") { newSession() }
                .keyboardShortcut("n")
                .disabled(keyFolder == nil)
            Button("New Session in a Worktree") { newSession(inWorktree: true) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(keyFolder == nil || !model.draftWorktrees.canMakeNew)
            Divider()
            Button("Add Folder…") { requests.folderSheet = .chooseFolder() }
                .keyboardShortcut("o")
            Button("Clone Folder from Git URL…") { requests.folderSheet = .clone() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            // On a server (037).
            if !model.hosts.servers.isEmpty {
                Menu("Add Folder On") {
                    ForEach(model.hosts.servers, id: \.self) { host in
                        Button(model.hosts.label(host)) { requests.folderSheet = .chooseFolder(host) }
                            .disabled(model.hostUnreachable(host))
                    }
                }
                Menu("Clone Folder On") {
                    ForEach(model.hosts.servers, id: \.self) { host in
                        Button(model.hosts.label(host)) { requests.folderSheet = .clone(host) }
                            .disabled(model.hostUnreachable(host))
                    }
                }
            }
            // As Settings ▸ Machines has it (#2755); a machine joins a control plane, so
            // with none (the window is at first run) there is nothing to add it to.
            Button(AddMachine.Words.menuItem) { requests.folderSheet = .addMachine }
                .keyboardShortcut("o", modifiers: [.command, .control])
                .disabled(model.needsFirstRun)
            Divider()
            Button("Show in Finder") { showInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(folderForFinder == nil)
            Button("Folder Settings…") { keyRequests.folderSettings = .general }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .disabled(keyFolder == nil)
        }

        // A Markdown page's text (#1419), as Safari and Preview have it. ⌘0 is Actual
        // Size while a page is in front, and Agents (All Folders) otherwise.
        CommandGroup(after: .toolbar) {
            Button("Actual Size") { pageZoom?.actualSize() }
                .keyboardShortcut(pageZoom == nil ? nil : KeyboardShortcut("0"))
                .disabled(pageZoom?.isActualSize ?? true)
            Button("Zoom In") { pageZoom?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!(pageZoom?.canZoomIn ?? false))
            Button("Zoom Out") { pageZoom?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!(pageZoom?.canZoomOut ?? false))
            Divider()
        }

        CommandGroup(after: .sidebar) {
            Button(keyFrame.isOpen ? "Hide Inspector" : "Show Inspector") { toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(sessionAgent == nil || popped != nil || (!keyFrame.isOpen && !inspectorFits))
            Divider()
            ForEach(Array(SidebarPane.allCases.enumerated()), id: \.element) { index, pane in
                Button(pane.title) { show(pane) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    // Off while a question card is up: ⌘1…n answer that card instead. A
                    // session's own window has no inspector (#826).
                    .disabled(sessionAgent == nil || !inspectorFits || answeringCard || popped != nil)
            }
            // The folder's own shell (#418), the editor's key for a terminal. ⌘J,
            // the usual panel key, is Next Needing Attention.
            Button(keyTerminal.isOpen ? "Hide Folder Terminal" : "Folder Terminal") { keyTerminal.toggle() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(!keyTerminal.isOpen && keyFolder?.exists != true)
            Divider()
            Button("Events") { model.showEvents() }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button("Resources") { model.showResources() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Runtimes") { model.showRuntimes() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Connectors") { model.showsMCPServers = true }
            Button("Worktrees") { model.showsWorktrees = true }
            Button("Work") { model.showsWork = true }
            Button("Cost") { model.showsSpending = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Lineage") { model.showLineage() }
            Button("Tokens") { model.showsTokens = true }
            Button("Time") { model.showsTime = true }
            Button("Milestones") { model.showsMilestones = true }
            // Agents as a web page on this Mac, found from here (#109).
            Button("Open in Browser") { openInBrowser() }
                .disabled(model.controlPlaneHosts == nil)
            Divider()
            // A menu item rather than a shortcut on the button. The button only
            // exists while you are scrolled away from the end, which is precisely
            // when a keyboard route is no help if it lives on the button.
            Button("Jump to Latest") { if let popped { popped.scrollToEnd() } else { model.scrollToEnd() } }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(sessionAgent == nil)
            // Next to the chat, not in Settings (#2383); no key, as none is clearly right.
            Button(ChatThoughts.menuTitle(showsThoughts: showsThoughts)) { showsThoughts.toggle() }
                .help(ChatThoughts.menuHelp)
            Divider()
            // In the main window's open chat, ⌘F finds in it (#1532), and Find Session
            // takes ⌥⌘F; with no chat open, ⌘F is Find Session as before.
            // On a host too old to find (#1748) it is greyed and keeps ⌘F, so the key never
            // moves the focus out of a chat to Find Session (#1867).
            let find = ChatFindItem.of(
                chatOpen: popped == nil && folderWindow == nil && model.selectedAgent != nil,
                hostFinds: model.agent(model.selectedAgent?.id, has: Capability.agentsFind1))
            Button("Find in Chat") { requests.wantsChatFind = true }
                .keyboardShortcut(find.isShown ? KeyboardShortcut("f") : nil)
                .disabled(!find.isEnabled)
                .help(find == .needsUpdate ? UpdateWords.hostNeedsUpdate : "Find words in this chat's prompts and replies")
            Button("Find Session") { requests.focusSessionSearch() }
                .keyboardShortcut(find.isShown ? KeyboardShortcut("f", modifiers: [.command, .option]) : KeyboardShortcut("f"))
                .disabled(model.selectedFolderSummary == nil)
        }

        CommandMenu("Session") {
            let agent = sessionAgent
            // Held while something is already on its way to it (#87).
            let acting = agent.flatMap { model.acting($0.id) } != nil
            Button("Stop") { act { await model.stop($0.id) } }
                .keyboardShortcut(".")
                .disabled(agent.map { !model.canStop($0) } ?? true || acting)
            // Title case, as menu items are; the button says it in a sentence.
            Button("Carry On") { act { await model.carryOn($0.id) } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(agent.map { !model.isBlocked($0) } ?? true)
            // Undo after Archive (#1534): ⌘Z while the strip offers it, and only then, so a
            // text field's own Undo is the key's the rest of the time.
            if model.archiveUndo != nil {
                Button("Undo Archive") { Task { await model.undoArchive() } }
                    .keyboardShortcut("z")
            }
            if agent?.state == .archived {
                Button("Unarchive") { act { await model.unarchive($0.id) } }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
            } else {
                Button("Archive") { archive() }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(agent == nil || acting)
            }
            // At the top of its folder whatever its state (#180).
            let pinned = agent.map(model.isPinned) ?? false
            Button(pinned ? "Unpin" : "Pin") {
                guard let agent else { return }
                Task { await model.setPinned(agent, !pinned) }
            }
            .disabled(agent == nil || agent?.state == .archived)
            // No push, banner or Mac notification for it, and still in Needs You (#2003).
            let muted = agent?.isMuted ?? false
            Button(MuteWords.label(muted: muted)) { act { await model.setMuted($0.id, !muted) } }
                .help(MuteWords.help(muted: muted))
                .disabled(agent.map { !model.canMute($0) } ?? true)
            // The person's title (#751), edited in the key window's toolbar.
            Button("Rename…") { rename() }
            .disabled(agent == nil || agent?.state == .archived)
            // The words selected in a reply, into the prompt as a quote (#1553). The reply's
            // own menu is the text's, so the key is the way to it there.
            Button("Quote in Prompt") {
                guard let agent, let words = ChatSelection.text() else { NSSound.beep(); return }
                model.offeredQuote = PromptOffer(agentID: agent.id, words: words)
            }
            .keyboardShortcut("'", modifiers: [.command, .shift])
            .disabled(agent == nil || agent?.state == .archived)
            // The person's prompts in the main window's chat, to go to one or branch from it
            // (#1658). ⇧⌘P is free: Print is gone, and ⌘P is Open File….
            Button("Prompts") { requests.wantsPrompts = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(popped != nil || folderWindow != nil || model.selectedAgent == nil)
            Divider()
            Button("Branch") { act { await model.fork($0.id) } }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(agent == nil || agent?.state == .archived)
            Divider()
            // Beside the main window or on another screen (#826). Its own window is
            // already one. ⇧ since ⌥⌘O opens the folder's window (#1089).
            Button("Open in New Window") {
                guard let agent else { return }
                openWindow(id: MainWindow.poppedSceneID, value: agent.id)
            }
            .keyboardShortcut("o", modifiers: [.command, .option, .shift])
            .disabled(agent == nil || popped != nil)
        }

        // The main window, and a folder's own (#1089). The windows open are listed
        // below these by the system, by title.
        CommandGroup(before: .windowList) {
            Button("Agents (All Folders)") { model.bringMainWindowForward(opening: openWindow) }
                .keyboardShortcut(pageZoom == nil ? KeyboardShortcut("0") : nil)
            Button("Open Folder in New Window") {
                guard let key = model.selectedFolderKey else { return }
                openWindow(id: FolderWindowScene.id, value: key)
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(folderWindow != nil || model.selectedFolderKey == nil)
            Menu("Open Folder Window") {
                ForEach(foldersInListOrder, id: \.key) { summary in
                    Button(SidebarOrder.label(summary) { model.hosts.label($0) }) {
                        openWindow(id: FolderWindowScene.id, value: summary.key)
                    }
                }
            }
            .disabled(foldersInListOrder.isEmpty)
            Divider()
        }

        CommandMenu("Go") {
            // ⌘P, as in every editor: the session's files by name (#415).
            Button("Open File…") { requests.showsFileSearch = true }
                .keyboardShortcut("p")
                .disabled(model.selectedAgent == nil)
            Divider()
            Button("Next Session") { step(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(sessionsHere.isEmpty)
            Button("Previous Session") { step(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(sessionsHere.isEmpty)
            Button("Next Needing Attention") { nextNeedingAttention() }
                .keyboardShortcut("j")
                // Each folder's count, not the list itself: the menu bar is drawn again
                // whenever what it reads changes, and the list reads every session (#165).
                .disabled(!foldersInListOrder.contains { model.work.shelf($0.key).toVisit > 0 })
                .help("Needs you")
            Divider()
            ForEach(Array(foldersInListOrder.prefix(9).enumerated()), id: \.element.key) { index, summary in
                Button(summary.name) { model.showFolder(summary.key) }
                    // ⌃⌘ rather than ⌃ alone, which Mission Control takes for Spaces.
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
            }
        }

        // A source file's completion (#1688), named in a menu. As the system's own ⌥Esc, it
        // goes to the text view's delegate first, which asks the language server; a plain
        // `complete:` action would skip it.
        CommandGroup(after: .textEditing) {
            Button("Complete") {
                let complete = #selector(NSResponder.complete(_:))
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
                    text.doCommand(by: complete)
                } else {
                    NSApp.sendAction(complete, to: nil, from: nil)
                }
            }
            .keyboardShortcut(.escape, modifiers: .option)
        }

        // ⌘P is Open File…; there is nothing here to print.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .help) {
            Button("Agents Help") { NSWorkspace.shared.open(HelpSite.url) }  // store-ok: a web page
                .keyboardShortcut("?")
        }
    }

    // MARK: File

    /// The page in the default browser, paired in the same step the first time; or why not,
    /// in an alert, rather than a page that isn't there.
    private func openInBrowser() {
        guard let control = ControlConfig.endpoint.flatMap({ ControlSettingsModel(endpoint: $0) }) else { return }
        Task {
            let why = await control.openInBrowser()
            control.stop()
            guard let why else { return }
            let alert = NSAlert()
            alert.messageText = "Agents can’t open in a browser"
            alert.informativeText = why
            alert.runModal()
        }
    }

    /// In the key window: a folder's own window opens its new session (#1513), as its
    /// New Session row does; the main window composes in its selected folder.
    private func newSession(inWorktree: Bool = false) {
        if let folderWindow {
            folderWindow.pick = .folder(folderWindow.key)
        } else {
            guard model.selectedFolderKey != nil else { return }
            model.composing = true
        }
        // Either way, so a plain New Session after a worktree one is back in the folder.
        model.draftWorktree = inWorktree ? .new : nil
        keyRequests.focusPrompt()
    }

    /// The open chat's folder, or else the selected folder's. Only on this Mac:
    /// a server's folder is not somewhere Finder can go.
    private var folderForFinder: (URL, MachineRef)? {
        if let agent = model.selectedAgent {
            return model.isOnThisMac(agent.host) ? (agent.cwd, agent.host) : nil
        }
        guard let summary = model.selectedFolderSummary, model.isOnThisMac(summary.host), summary.exists else { return nil }
        return (summary.folder.folder, summary.host)
    }

    private func showInFinder() {
        guard let (folder, host) = folderForFinder else { return }
        model.reveal(folder, on: host)
    }

    // MARK: View

    private var inspectorFits: Bool { SidebarFrame.fits(inWindowOf: keyFrame.windowWidth) }

    private func toggleInspector() {
        let frame = keyFrame
        if frame.isOpen { frame.isOpen = false } else if inspectorFits { frame.open() }
    }

    private func show(_ pane: SidebarPane) {
        let frame = keyFrame
        frame.pane = pane
        if !frame.isOpen, inspectorFits { frame.open() }
    }

    // MARK: Session

    private func act(_ work: @escaping (Agent) async -> Void) {
        guard let agent = sessionAgent else { return }
        Task { await work(agent) }
    }

    /// Session ▸ Rename…: the title's field in the key window's toolbar, and only that
    /// window's (#1452). In the main window a workflow can be open over the chat with the
    /// session still selected (#926); the field is in the chat's toolbar, so back to it.
    private func rename() {
        guard let agent = sessionAgent, agent.state != .archived else { return }
        if popped != nil {
            model.renaming = Renaming(id: agent.id, place: .ownWindow)
        } else if let folderWindow {
            model.renaming = Renaming(id: agent.id, place: .folderWindow(folderWindow.key))
        } else {
            model.openWorkflow = nil
            model.renaming = Renaming(id: agent.id, place: .mainWindow)
        }
    }

    private func archive() {
        guard let agent = sessionAgent, agent.state != .archived else { return }
        Task { await model.archive(agent.id, andLeave: true) }
    }

    // MARK: Go

    /// A permission or elicitation card is on the open chat: ⌘1…n belong to its
    /// answers, not to the inspector panes.
    private var answeringCard: Bool {
        !model.permissionsForSelection.isEmpty || model.elicitationForSelection != nil
    }

    /// The folder list's order: this Mac's folders, then each server's (037).
    private var foldersInListOrder: [DaemonAPI.FolderSummary] {
        let live = model.liveFolders
        guard !model.hosts.isEmpty else { return live }
        return live.filter { $0.host == .mac }
            + model.hosts.servers.flatMap { host in live.filter { $0.host == host } }
    }

    /// The selected folder's live sessions, in the order its page draws them.
    private var sessionsHere: [UUID] {
        AgentGroup.live.flatMap { model.agents(in: model.selectedFolderKey, group: $0) }.map(\.id)
    }

    private func step(by offset: Int) {
        let ids = sessionsHere
        guard !ids.isEmpty else { return }
        let next: Int
        if let current = model.selection, let at = ids.firstIndex(of: current) {
            next = (at + offset + ids.count) % ids.count
        } else {
            next = offset > 0 ? 0 : ids.count - 1
        }
        model.openAgent(ids[next])
    }

    /// Every session needing the person, folder by folder in the list's order, and
    /// after each folder's Needs you, its unread finishes (#70).
    private var needingAttention: [UUID] {
        foldersInListOrder.flatMap { summary in
            model.agents(in: summary.key, group: .needsAttention)
                + AgentGroup.live.filter { $0 != .needsAttention }
                    .flatMap { model.agents(in: summary.key, group: $0) }
                    .filter(\.showsUnread)
        }.map(\.id)
    }

    /// The one after the chat that is open, round to the first; so pressing it again
    /// and again visits each in turn.
    private func nextNeedingAttention() {
        let ids = needingAttention
        guard !ids.isEmpty else { return }
        let next = model.selection.flatMap { ids.firstIndex(of: $0) }.map { ($0 + 1) % ids.count } ?? 0
        model.openAgent(ids[next])
    }
}
