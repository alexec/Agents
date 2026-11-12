import AgentsKitCore
import SwiftUI

/// What the command menu can ask the open chat to do (#4792): the chat's own sheets and
/// fields, which only the chat holds.
enum RemoteChatAsk: Equatable {
    case findInChat, openFile, prompts
}

/// The ⌘K command menu on the Remote (#4792), from the Mac's (#4787): the same view and the same
/// finder (`CommandMenuView`, `CommandFinder`), with the Remote's own items. ⌘K with an iPad's
/// keyboard opens it; on a phone with none it opens from the sidebar's search.
@MainActor
enum RemoteCommandMenu {
    typealias Action = CommandMenuAction

    /// The keys the Remote already has for the actions the menu lists, so a row says the key.
    enum Keys {
        static let commandMenu = KeyboardShortcut("k")
        static let findInChat = KeyboardShortcut("f")
        static let openFile = KeyboardShortcut("p")
        static let prompts = KeyboardShortcut("p", modifiers: [.command, .shift])
        static let terminal = KeyboardShortcut("`", modifiers: .control)
    }

    /// The actions that can be done now, from what is open: the chat's, the folder's, Work.
    static func actions(_ model: RemoteModel, openTerminal: (@MainActor () -> Void)?) -> [Action] {
        var actions: [Action] = []
        if let key = model.selectedKey ?? model.newSessionFolder {
            actions.append(Action("New Session", keywords: ["Start"]) { model.sidebarItem = .folder(key) })
        }
        if let agent = model.selectedAgent {
            if model.agent(agent.id, has: Capability.agentsFind1) {
                actions.append(Action("Find in Chat", key: Keys.findInChat) { model.chatAsk = .findInChat })
            }
            actions.append(Action("Open File…", key: Keys.openFile) { model.chatAsk = .openFile })
            actions.append(Action("Prompts", key: Keys.prompts) { model.chatAsk = .prompts })
            // With the list's keys (#4796), which work while the sidebar has the keyboard.
            actions.append(Action("Rename Session…", listKey: .rename) { model.askToRename(agent) })
            actions.append(Action("Archive Session", listKey: .archive) { Task { await model.archive(agent.id) } })
            if let request = model.work.laterRequest(askedBy: agent.id) {
                actions.append(Action(ListKey.laterWord, listKey: .later, keywords: ["Needs you"]) {
                    Task { await model.deferRequest(request, ListKey.laterTime) }
                })
            }
        }
        // Through the open folder's sessions, as j and k go (#4796).
        let order = model.sessionsInFront
        if let next = ListKey.step(from: model.selectedAgent?.id, in: order, forward: true) {
            actions.append(Action("Next Session", listKey: .next) { model.sidebarItem = .session(next) })
        }
        if let previous = ListKey.step(from: model.selectedAgent?.id, in: order, forward: false) {
            actions.append(Action("Previous Session", listKey: .previous) { model.sidebarItem = .session(previous) })
        }
        if let openTerminal {
            actions.append(Action("Folder Terminal", key: Keys.terminal, perform: openTerminal))
        }
        actions.append(Action("Issues", keywords: ["Work"]) { model.showWork(WorkPlace(kind: .issue)) })
        actions.append(Action("Pull Requests", keywords: ["Work", "PRs"]) { model.showWork(WorkPlace(kind: .pr)) })
        return actions
    }

    /// The menu's items: the open folder's sessions, the actions, each other folder's sessions,
    /// the folders, and the Work lists' issues and pull requests, the nearest first.
    static func items(_ model: RemoteModel, actions: [Action]) -> [CommandFinder.Item] {
        let servers = model.hostSections.map(\.id).filter { $0 != .mac }
        let folders = SidebarOrder.folders(model.folders, servers: servers)
        let here = model.selectedKey
        func sessions(_ summaries: [DaemonAPI.FolderSummary]) -> [CommandFinder.Item] {
            summaries.flatMap { summary in
                AgentGroup.live.flatMap { model.work.agents(in: summary.key, group: $0) }.map { agent in
                    CommandFinder.Item(id: "session:\(agent.id.uuidString)", kind: .session,
                                       title: agent.title ?? "Untitled", detail: summary.name,
                                       keywords: ["Find Session"])
                }
            }
        }
        let folderItems = folders.map { summary in
            CommandFinder.Item(id: "folder:\(folderID(summary.key))", kind: .folder, title: summary.name,
                               detail: servers.isEmpty ? "" : model.machineName(summary.host))
        }
        return sessions(folders.filter { $0.key == here }) + actions.map(\.item)
            + sessions(folders.filter { $0.key != here }) + folderItems
            + CommandMenuWork.items(model.workLists, .issue) + CommandMenuWork.items(model.workLists, .pr)
    }

    private static func folderID(_ key: FolderKey) -> String { "\(key.host)|\(key.folder.path)" }

    /// What choosing an item that is not an action does: open it.
    static func open(_ item: CommandFinder.Item, _ model: RemoteModel) {
        if let place = CommandMenuWork.place(of: item) {
            model.showWork(place)
            return
        }
        let (prefix, rest) = CommandMenuID.split(item.id)
        switch prefix {
        case "session":
            if let id = UUID(uuidString: rest) { model.sidebarItem = .session(id) }
        case "folder":
            if let summary = model.folders.first(where: { folderID($0.key) == rest }) {
                model.sidebarItem = .folder(summary.key)
            }
        default:
            break
        }
    }
}

/// The menu over the Remote's window while it is open, and ⌘K, which opens it, with a keyboard.
struct RemoteCommandMenuOverlay: ViewModifier {
    @Environment(RemoteModel.self) private var model
    /// Folder Terminal, when the folder open has one (#418).
    let openTerminal: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        content
            .background {
                // A button no one sees, so the key is there whatever has focus, as ⌘F is.
                Button(CommandMenuWords.menuItem) { model.commandMenu = model.commandMenu == nil ? "" : nil }
                    .keyboardShortcut(RemoteCommandMenu.Keys.commandMenu)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .overlay {
                if let term = model.commandMenu {
                    let actions = RemoteCommandMenu.actions(model, openTerminal: openTerminal)
                    CommandMenuView(items: RemoteCommandMenu.items(model, actions: actions),
                                    repos: CommandMenuWork.repos(model.workLists), term: term,
                                    choose: { [model] item in
                                        model.commandMenu = nil
                                        if let action = actions.first(where: { $0.item.id == item.id }) {
                                            action.perform()
                                        } else {
                                            RemoteCommandMenu.open(item, model)
                                        }
                                    },
                                    dismiss: { [model] in model.commandMenu = nil })
                }
            }
    }
}
