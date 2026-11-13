import AgentsKitCore
import SwiftUI

/// The keys of the menu bar's items that the command menu lists too, in one place, so the
/// shortcut a row shows is the menu's own.
enum MenuKeys {
    static let commandMenu = KeyboardShortcut("k")
    static let newSession = KeyboardShortcut("n")
    static let newWorktreeSession = KeyboardShortcut("n", modifiers: [.command, .option])
    static let addFolder = KeyboardShortcut("o")
    static let cloneFolder = KeyboardShortcut("o", modifiers: [.command, .shift])
    /// New App… (#5132): Let's build your idea, again.
    static let newApp = KeyboardShortcut("a", modifiers: [.command, .shift])
    static let findInChat = KeyboardShortcut("f")
    /// Find Session stays on ⌥⌘F for one release, then goes: ⌘K finds sessions (#4787).
    static let findSession = KeyboardShortcut("f", modifiers: [.command, .option])
    static let inspector = KeyboardShortcut("i", modifiers: [.command, .option])
    static let terminal = KeyboardShortcut("`", modifiers: .control)
    static let events = KeyboardShortcut("e", modifiers: [.command, .option])
    static let resources = KeyboardShortcut("l", modifiers: [.command, .option])
    static let runtimes = KeyboardShortcut("r", modifiers: [.command, .option])
    static let cost = KeyboardShortcut("s", modifiers: [.command, .option])
    static let stop = KeyboardShortcut(".")
    static let archive = KeyboardShortcut(.delete, modifiers: [.command, .option])
    static let prompts = KeyboardShortcut("p", modifiers: [.command, .shift])
    static let branch = KeyboardShortcut("b", modifiers: [.command, .option])
    static let openFile = KeyboardShortcut("p")
    static let nextNeedingAttention = KeyboardShortcut("j")
    static let nextSession = KeyboardShortcut(.downArrow, modifiers: [.command, .option])
    static let previousSession = KeyboardShortcut(.upArrow, modifiers: [.command, .option])

    /// A folder's key in Go, ⌃⌘1 to ⌃⌘9, by its place in the list; nil after the ninth.
    static func folder(at index: Int) -> KeyboardShortcut? {
        guard (0..<9).contains(index) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
    }
}

/// The command menu's items on the Mac: the actions the menu bar gave, then the sessions, the
/// folders and the Work lists' issues and pull requests, the nearest first.
@MainActor
enum CommandMenuItems {
    static func items(_ model: AppModel, actions: [CommandMenuAction]) -> [CommandFinder.Item] {
        let folders = model.foldersInListOrder
        let here = model.selectedFolderKey
        func sessions(_ summaries: [DaemonAPI.FolderSummary]) -> [CommandFinder.Item] {
            summaries.flatMap { summary in
                AgentGroup.live.flatMap { model.agents(in: summary.key, group: $0) }.map { agent in
                    CommandFinder.Item(id: "session:\(agent.id.uuidString)", kind: .session,
                                     title: agent.title ?? "Untitled", detail: summary.name,
                                     keywords: ["Find Session"])
                }
            }
        }
        let folderItems = folders.enumerated().map { index, summary in
            CommandFinder.Item(id: "folder:\(folderID(summary.key))", kind: .folder,
                             title: summary.name,
                             detail: model.hosts.isEmpty ? "" : model.hosts.label(summary.host),
                             shortcut: MenuKeys.folder(at: index)?.glyphs ?? "")
        }
        // The open folder's sessions first, then the actions, then each other folder's sessions.
        return sessions(folders.filter { $0.key == here }) + actions.map(\.item)
            + sessions(folders.filter { $0.key != here }) + folderItems
            + workItems(model, .issue) + workItems(model, .pr)
    }

    private static func folderID(_ key: FolderKey) -> String { "\(key.host)|\(key.folder.path)" }

    static func workItems(_ model: AppModel, _ kind: WorkList.Kind) -> [CommandFinder.Item] {
        CommandMenuWork.items(model.workLists, kind)
    }

    static func repos(_ model: AppModel) -> [String] { CommandMenuWork.repos(model.workLists) }

    /// What choosing an item that is not an action does: open it.
    static func open(_ item: CommandFinder.Item, _ model: AppModel) {
        if let place = CommandMenuWork.place(of: item) {
            model.showWork(place)
            return
        }
        let (prefix, rest) = CommandMenuID.split(item.id)
        switch prefix {
        case "session":
            if let id = UUID(uuidString: rest) { model.openAgent(id) }
        case "folder":
            if let summary = model.foldersInListOrder.first(where: { folderID($0.key) == rest }) {
                model.showFolder(summary.key)
            }
        default:
            break
        }
    }
}

extension AppModel {
    /// The folder list's order: this Mac's folders, then each server's (037).
    var foldersInListOrder: [DaemonAPI.FolderSummary] {
        let live = liveFolders
        guard !hosts.isEmpty else { return live }
        return live.filter { $0.host == .mac }
            + hosts.servers.flatMap { host in live.filter { $0.host == host } }
    }
}
