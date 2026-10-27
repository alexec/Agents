import Foundation

/// Projects (#2317, specs/2317-projects): what people work on, the record on the control
/// plane that folders join. A folder names its project's id in `.agents/folder.json`.
public extension DaemonAPI {
    /// A project, in `projects/list` and as `projects/set` answers.
    struct Project: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var owner: String
        /// Its folders as their machines last said them: every machine's for an admin, the
        /// caller's own machines' for a member.
        public var folders: [ProjectFolder]
        /// The caller is its owner or an admin, so may rename and remove it.
        public var mayChange: Bool

        public init(id: String, name: String, owner: String = "", folders: [ProjectFolder] = [], mayChange: Bool = true) {
            self.id = id
            self.name = name
            self.owner = owner
            self.folders = folders
            self.mayChange = mayChange
        }
    }

    /// A folder in a project, as its machine last said it.
    struct ProjectFolder: Codable, Sendable, Hashable {
        public var machine: MachineRef
        public var folder: URL
        public var name: String

        public init(machine: MachineRef, folder: URL, name: String) {
            self.machine = machine
            self.folder = folder
            self.name = name
        }
    }

    /// `projects/list`: the organisation's projects, by name.
    struct ProjectList: Codable, Sendable, Hashable {
        public var projects: [Project]

        public init(projects: [Project] = []) { self.projects = projects }
    }

    /// `projects/set`: makes a project, or with `id` renames one.
    struct ProjectSet: Codable, Sendable, Hashable {
        public var id: String?
        public var name: String

        public init(id: String? = nil, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// `projects/remove`. Refused while a folder names the project.
    struct ProjectRequest: Codable, Sendable, Hashable {
        public var id: String

        public init(id: String) { self.id = id }
    }

    /// `control/projectsChanged`: a project was made, renamed, adopted or removed.
    struct ProjectsChanged: Codable, Sendable, Hashable {
        public var id: String?
        public var removed: Bool?

        public init(id: String? = nil, removed: Bool? = nil) {
            self.id = id
            self.removed = removed
        }
    }

    /// `folders/setProject`: the project id to write into the folder's `.agents/folder.json`.
    struct SetFolderProjectRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var project: String

        public init(folder: URL, project: String) {
            self.folder = folder
            self.project = project
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `ProjectList` (#2317).
    static let projectsList = "projects/list"
    /// `ProjectSet` → `Project`; renaming is the owner's or an admin's (#2317).
    static let projectsSet = "projects/set"
    /// `ProjectRequest` → `{}`, the owner's or an admin's (#2317).
    static let projectsRemove = "projects/remove"
    /// `SetFolderProjectRequest` → `FolderSummary`, on the folder's machine (#2317).
    static let foldersSetProject = "folders/setProject"
}

public extension DaemonAPI.Notification {
    /// `ProjectsChanged`: load the projects again (#2317).
    static let controlProjectsChanged = "control/projectsChanged"
}

/// The words a folder's Project is shown in, the same on the Mac and the Remote (the web
/// page's are in `Web/src/model/projects.ts`).
public enum ProjectWords {
    public static let title = "Project"
    public static let newProject = "New Project…"
    public static let rename = "Rename Project…"
    public static let remove = "Remove Project"
    public static let namePrompt = "Project name"
    /// Under the picker: what a project is, and where the choice is kept.
    public static let explanation = "Folders in one project share its tools and its reports, on every machine. "
        + "The project is saved in .agents/folder.json, so a clone you commit it in joins the same project."
    /// A folder whose id the control plane has not adopted yet, or with no control plane.
    public static func unknown(_ id: String) -> String { "Not on the control plane yet (\(id))" }
    public static let noControlPlane = "Connect to a control plane to choose a project."

    /// The project a folder is in, by its id, from the list.
    public static func name(of id: String?, in projects: [DaemonAPI.Project]) -> String? {
        guard let id else { return nil }
        return projects.first { $0.id == id }?.name
    }

    /// Whether a project of this name, in any case, is there already, other than `except`.
    public static func taken(_ name: String, in projects: [DaemonAPI.Project], except: String? = nil) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return projects.contains { $0.id != except && $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}
