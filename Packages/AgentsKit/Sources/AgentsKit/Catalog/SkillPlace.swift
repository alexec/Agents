import Foundation

/// Where a destination is on disk (059, data-model.md "Destination"): its skills folder,
/// its lock, and where something replaced or removed there is put.
struct SkillPlace: Sendable, Equatable {
    var destination: DaemonAPI.SkillDestination
    /// `~/.agents/skills` or `<folder>/.agents/skills`.
    var skills: URL
    var lockKind: SkillLock.Kind
    var lock: URL
    /// The project or worktree folder, for a project destination.
    var folder: URL?
    /// Where a replaced or removed skill goes. Nil is the person's real Trash, which only
    /// the ordinary daemon uses: a scratch root or a test has a folder of its own, so a walk
    /// never leaves anything in the person's Trash (research R9).
    var trash: URL?

    /// - `personalHome`: `StoreLocations.personalHome`; nil for a scratch root with none named.
    /// - `usesRealTrash`: the ordinary root with the real home.
    /// - `isProject`: whether a folder is a project on this Mac, or a worktree of one.
    static func resolve(_ destination: DaemonAPI.SkillDestination, personalHome: URL?, root: URL,
                        usesRealTrash: Bool, environment: [String: String],
                        isProject: (URL) -> Bool) throws -> SkillPlace {
        let trash = usesRealTrash ? nil : root.appending(path: "trash")
        switch destination {
        case .personal:
            guard let home = personalHome else { throw DaemonAPI.CatalogError.noPersonalHome }
            return SkillPlace(destination: destination, skills: home.appending(path: ".agents/skills"),
                              lockKind: .personal, lock: SkillLock.personalURL(home: home, environment: environment),
                              folder: nil, trash: trash)
        case .project(let path):
            let folder = URL(filePath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  isProject(folder) else {
                throw DaemonAPI.CatalogError.notAProject(path: path)
            }
            return SkillPlace(destination: .project(folder: folder.path),
                              skills: folder.appending(path: "\(DotAgents.folder)/skills"),
                              lockKind: .project, lock: SkillLock.projectURL(folder: folder), folder: folder, trash: trash)
        }
    }

    /// The lock entry naming the skill in folder `name`, and the key it is under. The CLI
    /// keys by the skill's own name and folders it by `sanitizeName`, which are nearly always
    /// the same; where they differ, the key whose folder this is counts.
    func managedEntry(folderName name: String, in lock: SkillLock) -> (key: String, entry: SkillLock.Entry)? {
        if let e = lock.entry(name) { return (name, e) }
        for key in lock.names where SkillFile.folderName(key) == name {
            if let e = lock.entry(key) { return (key, e) }
        }
        return nil
    }
}
