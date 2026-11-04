import Foundation

/// New Session's two choices (#3279): the **project** first, then the machine it is **on**.
/// A project is the folders that name the same project (#2317); a folder that names none
/// is a project of its own. The Mac, the Remote and the web page (`newSessionProjects` in
/// `Web/src/model/projects.ts`) use the same rule.
public enum NewSessionProject {
    /// One project in the Project menu: its folders in the sidebar's order.
    public struct Choice: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let folders: [FolderKey]

        public init(id: String, name: String, folders: [FolderKey]) {
            self.id = id
            self.name = name
            self.folders = folders
        }

        /// A project with one folder hides the On row: it looks as a folder does today.
        public var hidesMachine: Bool { folders.count < 2 }
    }

    /// The id a folder's project goes by: its project's, or the folder's own when it names
    /// none, so two folders that name no project are never one project.
    public static func id(of folder: DaemonAPI.FolderSummary) -> String {
        folder.project.flatMap { $0.isEmpty ? nil : $0 } ?? "folder:\(folder.key.stored)"
    }

    /// The projects of `ordered` (the folders in the sidebar's order), each where its
    /// first folder is. A project is named by its first folder: clones share the name,
    /// and a project with one folder has that folder's name, as today.
    public static func choices(_ ordered: [DaemonAPI.FolderSummary]) -> [Choice] {
        var order: [String] = []
        var names: [String: String] = [:]
        var folders: [String: [FolderKey]] = [:]
        for folder in ordered {
            let id = id(of: folder)
            if folders[id] == nil {
                order.append(id)
                names[id] = folder.name
            }
            folders[id, default: []].append(folder.key)
        }
        return order.map { Choice(id: $0, name: names[$0] ?? "", folders: folders[$0] ?? []) }
    }

    /// The folder a project starts in when it is picked: the one on this machine when it
    /// has one, else the one last used in this project, else the first. `isHere` is false
    /// for every machine on the Remote and the web page, where "this machine" is the
    /// machine last used.
    public static func folder(in choice: Choice, isHere: (MachineRef) -> Bool, remembered: FolderKey?) -> FolderKey? {
        if let here = choice.folders.first(where: { isHere($0.host) }) { return here }
        if let remembered, choice.folders.contains(remembered) { return remembered }
        return choice.folders.first
    }

    /// The project `key` is in, of `choices`.
    public static func choice(of key: FolderKey?, in choices: [Choice]) -> Choice? {
        guard let key else { return nil }
        return choices.first { $0.folders.contains(key) }
    }
}
