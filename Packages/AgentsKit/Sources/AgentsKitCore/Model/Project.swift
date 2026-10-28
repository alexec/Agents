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
        /// The caller is its owner or an admin, so may rename and remove it, and set its slots.
        public var mayChange: Bool
        /// Its Tasks, Code review and CI (#2669), one per slot; a slot not here is each
        /// folder's own.
        public var slots: [ProjectSlot]?

        public init(id: String, name: String, owner: String = "", folders: [ProjectFolder] = [], mayChange: Bool = true,
                    slots: [ProjectSlot]? = nil) {
            self.id = id
            self.name = name
            self.owner = owner
            self.folders = folders
            self.mayChange = mayChange
            self.slots = slots
        }
    }

    /// One of a project's Tasks, Code review and CI slots (#2669): the forge and repository
    /// that fill it for every folder in the project, or skipped.
    struct ProjectSlot: Codable, Sendable, Hashable {
        public var slot: ConnectorSlotKind
        public var forge: ConnectionProvider?
        public var repository: String?
        public var site: String?
        public var skipped: Bool?

        public init(slot: ConnectorSlotKind, forge: ConnectionProvider? = nil, repository: String? = nil,
                    site: String? = nil, skipped: Bool? = nil) {
            self.slot = slot; self.forge = forge; self.repository = repository; self.site = site; self.skipped = skipped
        }

        /// The folder's own slot, as the project's for every folder.
        public static func from(_ setup: ConnectorSetup, _ slot: ConnectorSlot) -> ProjectSlot? {
            if slot.state == .skipped { return ProjectSlot(slot: slot.slot, skipped: true) }
            guard let repository = slot.repository ?? setup.repository else { return nil }
            return ProjectSlot(slot: slot.slot, forge: setup.forgeOrGitHub, repository: repository, site: setup.siteOrGitHub)
        }
    }

    /// `projects/setSlot` (#2669): sets one of the project's slots, or with no value gives it
    /// back to each folder. Only the owner or an admin.
    struct ProjectSlotSet: Codable, Sendable, Hashable {
        public var id: String
        public var slot: ConnectorSlotKind
        public var value: ProjectSlot?

        public init(id: String, slot: ConnectorSlotKind, value: ProjectSlot? = nil) {
            self.id = id; self.slot = slot; self.value = value
        }
    }

    /// One project's slots, as a machine gets them (#2669).
    struct ProjectTools: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var slots: [ProjectSlot]

        public init(id: String, name: String, slots: [ProjectSlot] = []) { self.id = id; self.name = name; self.slots = slots }
    }

    /// `projects/joined`'s answer and `host/projects` (#2669).
    struct MachineProjects: Codable, Sendable, Hashable {
        public var projects: [ProjectTools]

        public init(projects: [ProjectTools] = []) { self.projects = projects }
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

    /// `folders/add` (#2671): the folder, and the project picked in the Add Folder sheet. With
    /// none, a folder that names no project gets one of its own.
    struct AddFolderRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var project: String?

        public init(folder: URL, project: String? = nil) {
            self.folder = folder
            self.project = project
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
    /// `ProjectSlotSet` → `Project`, the owner's or an admin's (#2669).
    static let projectsSetSlot = "projects/setSlot"
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
    /// The projects could not be read (#2756), kept apart from a list with none: what went
    /// wrong, said next to Try Again. Nil for an older control plane, which has no projects.
    public static func notRead(_ error: any Error) -> String? {
        if let error = error as? JSONRPCError {
            return error.isMethodNotFound ? nil : "Couldn’t read the projects. \(error.message)"
        }
        return "Couldn’t read the projects. The control plane can’t be reached."
    }
    public static let tryAgain = "Try Again"
    public static let noControlPlane = "Connect to a control plane to choose a project."
    /// The Add Folder sheet's first choice (#2671), what a solo person keeps.
    public static let ownProject = "Its Own Project"
    /// Under the Add Folder sheet's picker.
    public static let addNote = "Its own project is a new one of the folder's name, or the one its .agents/folder.json names. "
        + "Pick another to share that project's tools and reports."

    /// On a Connectors page whose folder is in a project (#2669): whose the slots are, and who
    /// may change them.
    public static func slotsOwner(_ name: String) -> String {
        "Tasks, Code review and CI are the project's (\(name)), the same in every folder of it. Only its owner or an admin changes them."
    }
    /// A slot the project sets.
    public static func setByProject(_ name: String) -> String { "Set by the project \(name)." }
    /// One slot's row in the project's card: what fills it, and whose it is.
    public static func slotLine(_ slot: DaemonAPI.ConnectorSlot, name: String) -> String {
        let what = [slot.choice, slot.repository].compactMap { $0 }.joined(separator: " · ")
        switch (slot.isFromProject, slot.state == .skipped) {
        case (true, true): return "Skipped in every folder of \(name)."
        case (true, false): return "\(what), for every folder of \(name)."
        case (false, true): return "Skipped in this folder only."
        case (false, false):
            return slot.repository == nil ? "This folder has no GitHub or GitLab remote." : "\(what), this folder's own."
        }
    }
    /// Make the folder's own slot the project's.
    public static let useForProject = "Use for the Whole Project"
    /// Give the slot back to each folder.
    public static let useFolderOwn = "Use Each Folder's Own"

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
