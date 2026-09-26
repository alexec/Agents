import AgentsKit
import AppKit
import SwiftUI

/// What the menu bar asks of the window, for the things that live in a view's own
/// state rather than on the model: a sheet the project list opens, and the prompt
/// taking the keyboard.
///
/// There is one window (New Window is gone from File, and tabbing is off), so one of
/// these, made by the app and handed to both the menus and the window.
@MainActor
@Observable
final class WindowRequests {
    enum ProjectSheet {
        case chooseFolder, clone, addServer
    }

    /// Set by a menu item, taken (and cleared) by `ProjectListView`, which owns the sheets.
    var projectSheet: ProjectSheet?

    /// Set to put the keyboard in a new session's prompt, and cleared by the prompt that
    /// takes it. A flag rather than an event, because New Session from inside a chat
    /// asks before the project page — and its prompt — exists.
    var wantsPromptFocus = false

    func focusPrompt() { wantsPromptFocus = true }
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

    static let helpURL = URL(string: "https://alexec.github.io/Agents/")!

    var body: some Commands {
        // The standard Show/Hide Sidebar (⌃⌘S) for the projects column.
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Session") { newSession() }
                .keyboardShortcut("n")
                .disabled(model.selectedProjectSummary == nil)
            Button("New Session in a Worktree") { newSession(inWorktree: true) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model.selectedProjectSummary == nil || !model.draftWorktrees.canMakeNew)
            Divider()
            Button("Add Project Folder…") { requests.projectSheet = .chooseFolder }
                .keyboardShortcut("o")
            Button("Clone Repository…") { requests.projectSheet = .clone }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Add Server…") { requests.projectSheet = .addServer }
            Divider()
            Button("Show in Finder") { showInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(folderForFinder == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(frame.isOpen ? "Hide Inspector" : "Show Inspector") { toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.selectedAgent == nil || (!frame.isOpen && !inspectorFits))
            Divider()
            ForEach(Array(SidebarPane.allCases.enumerated()), id: \.element) { index, pane in
                Button(pane.title) { show(pane) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(model.selectedAgent == nil || !inspectorFits)
            }
            Divider()
            Button("Events") { model.showEvents() }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button("Resources") { model.showResources() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Spending") { model.showsSpending = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            // A menu item rather than a shortcut on the button. The button only
            // exists while you are scrolled away from the end, which is precisely
            // when a keyboard route is no help if it lives on the button.
            Button("Jump to Latest") { model.scrollToEnd() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.selectedAgent == nil)
            Divider()
        }

        CommandMenu("Session") {
            let agent = model.selectedAgent
            Button("Stop") { act { await model.stop($0.id) } }
                .keyboardShortcut(".")
                .disabled(agent.map { !model.canStop($0) } ?? true)
            // Title case, as menu items are; the button says it in a sentence.
            Button("Carry On") { act { await model.carryOn($0.id) } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(agent.map { !model.isBlocked($0) } ?? true)
            Button(agent?.parkAction.map(ParkWords.label) ?? ParkWords.label(.park)) { park() }
                .keyboardShortcut("p", modifiers: [.command, .control])
                .disabled(agent?.parkAction == nil)
            if agent?.state == .archived {
                Button("Bring Back") { act { await model.unarchive($0.id) } }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
            } else {
                Button("Archive") { archive() }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(agent == nil)
            }
            Divider()
            Button("Branch") { act { await model.fork($0.id) } }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(agent == nil || agent?.state == .archived)
        }

        CommandMenu("Go") {
            Button("Next Session") { step(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(sessionsHere.isEmpty)
            Button("Previous Session") { step(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(sessionsHere.isEmpty)
            Button("Next Needing Attention") { nextNeedingAttention() }
                .keyboardShortcut("j")
                .disabled(needingAttention.isEmpty)
            Divider()
            ForEach(Array(projectsInListOrder.prefix(9).enumerated()), id: \.element.key) { index, summary in
                Button(summary.name) { model.showProject(summary.key) }
                    // ⌃⌘ rather than ⌃ alone, which Mission Control takes for Spaces.
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
            }
        }

        CommandGroup(replacing: .help) {
            Button("Agents Help") { NSWorkspace.shared.open(Self.helpURL) }
                .keyboardShortcut("?")
        }
    }

    // MARK: File

    /// The project's page with the keyboard in its prompt, which is where a session starts.
    private func newSession(inWorktree: Bool = false) {
        guard let key = model.selectedProjectKey else { return }
        model.showProject(key)
        // Either way, so a plain New Session after a worktree one is back in the folder.
        model.draftWorktree = inWorktree ? .new : nil
        requests.focusPrompt()
    }

    /// The open chat's folder, or else the selected project's. Only on this Mac:
    /// a server's folder is not somewhere Finder can go.
    private var folderForFinder: URL? {
        if let agent = model.selectedAgent {
            return agent.host == .mac ? agent.cwd : nil
        }
        guard let summary = model.selectedProjectSummary, summary.host == .mac, summary.exists else { return nil }
        return summary.folder
    }

    private func showInFinder() {
        guard let folder = folderForFinder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: View

    private var inspectorFits: Bool { SidebarFrame.fits(inWindowOf: frame.windowWidth) }

    private func toggleInspector() {
        if frame.isOpen { frame.isOpen = false } else if inspectorFits { frame.open() }
    }

    private func show(_ pane: SidebarPane) {
        frame.pane = pane
        if !frame.isOpen, inspectorFits { frame.open() }
    }

    // MARK: Session

    private func act(_ work: @escaping (Agent) async -> Void) {
        guard let agent = model.selectedAgent else { return }
        Task { await work(agent) }
    }

    /// As the chat's own buttons do: Park and Archive go back to the project, because
    /// the person has said they are done with it for now; Unpark stays.
    private func park() {
        guard let agent = model.selectedAgent, let action = agent.parkAction else { return }
        Task {
            await model.perform(action, on: agent.id)
            if action == .park, model.selection == agent.id { model.selection = nil }
        }
    }

    private func archive() {
        guard let agent = model.selectedAgent, agent.state != .archived else { return }
        Task {
            await model.archive(agent.id)
            if model.selection == agent.id { model.selection = nil }
        }
    }

    // MARK: Go

    /// The project list's order: this Mac's projects, then each server's (037).
    private var projectsInListOrder: [DaemonAPI.ProjectSummary] {
        let live = model.liveProjects
        guard !model.hosts.isEmpty else { return live }
        return live.filter { $0.host == .mac }
            + model.hosts.hosts.all.flatMap { host in live.filter { $0.host == host.id } }
    }

    /// The selected project's live sessions, in the order its page draws them.
    private var sessionsHere: [UUID] {
        AgentGroup.live.flatMap { model.agents(in: model.selectedProjectKey, group: $0) }.map(\.id)
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

    /// Every session waiting on the person, project by project in the list's order.
    private var needingAttention: [UUID] {
        projectsInListOrder.flatMap { model.agents(in: $0.key, group: .needsAttention) }.map(\.id)
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
