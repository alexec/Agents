import Foundation

/// A kind of session the person can start (#760): a file in `.agents/personas/`, in the
/// folder or in `~/.agents`, whose front matter is a `name`, a `description` and the
/// settings a workflow names, and whose body is the prompt it starts with.
///
/// Its own folder rather than a skill, so no runtime reads one as a skill and the model
/// cannot pick one up half way through a session. Picked on the start form, which sets
/// what it names and leaves the rest as the form has it; the body goes to the agent
/// with the briefing, never into the transcript.
public struct Persona: Codable, Hashable, Sendable, Identifiable {
    /// Where the file is. A folder's wins over one in `~/.agents` with the same id.
    public enum Origin: String, Codable, Hashable, Sendable {
        case folder
        case personal
    }

    /// The file's name without `.md`: what a start names it by.
    public var id: String
    /// The front matter's `name`, or the id.
    public var name: String
    public var description: String?
    public var origin: Origin
    public var settings: WorkflowSettings
    /// Why the file cannot be used, when it cannot. Listed so the person sees it, never
    /// picked.
    public var problem: String?

    public init(id: String, name: String? = nil, description: String? = nil, origin: Origin,
                settings: WorkflowSettings = WorkflowSettings(), problem: String? = nil) {
        self.id = id
        self.name = name ?? id
        self.description = description
        self.origin = origin
        self.settings = settings
        self.problem = problem
    }

    /// Where both kinds of persona live, under a folder or a home folder.
    public static let folderName = ".agents/personas"
    public static let fileExtension = "md"

    public static func folder(in base: URL) -> URL {
        base.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// The option values this persona names that the runtime offers, by option id, to
    /// lay over the form's choices. Each key on its own: a model this runtime does not
    /// offer is left as the form has it rather than refusing the rest, because the
    /// person is at the form and can see and change every one before starting.
    public func choices(against advertised: [ConfigOption]) -> [String: JSONValue] {
        var singles: [WorkflowSettings] = []
        if let mode = settings.permissionMode { singles.append(WorkflowSettings(permissionMode: mode)) }
        if let model = settings.model { singles.append(WorkflowSettings(model: model)) }
        if let effort = settings.effort { singles.append(WorkflowSettings(effort: effort)) }
        for (id, value) in settings.options { singles.append(WorkflowSettings(options: [id: value])) }
        var values: [String: JSONValue] = [:]
        for single in singles {
            if case .resolved(let options) = WorkflowSettings.resolve(single, against: advertised) {
                values.merge(options.values) { _, new in new }
            }
        }
        return values
    }

    /// The form's labels when the picked persona changes from `old` to `new` (#2649): the
    /// old one's labels go, unless the new one names them too, and the new one's are added
    /// beside the rest, each once.
    public static func labels(_ labels: [String], switchingFrom old: Persona?, to new: Persona?) -> [String] {
        let kept = Set((new?.settings.labels ?? []).map(SessionLabelPolicy.key))
        let gone = Set((old?.settings.labels ?? []).map(SessionLabelPolicy.key)).subtracting(kept)
        let left = labels.filter { !gone.contains(SessionLabelPolicy.key($0)) }
        return left + SessionLabelPolicy.accepted(new?.settings.labels ?? [], existing: left)
    }
}

extension DaemonAPI {
    public struct PersonaFile: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var origin: Persona.Origin
        public var content: String
        public init(id: String, origin: Persona.Origin, content: String) {
            self.id = id; self.origin = origin; self.content = content
        }
    }

    public struct PersonasFilesRequest: Codable, Sendable {
        public var folder: URL?
        public var origin: Persona.Origin
        public init(folder: URL? = nil, origin: Persona.Origin) { self.folder = folder; self.origin = origin }
    }

    public struct PersonaFileSaveRequest: Codable, Sendable {
        public var folder: URL?
        public var origin: Persona.Origin
        public var id: String
        public var content: String
        public var delete: Bool?
        public init(folder: URL? = nil, origin: Persona.Origin, id: String, content: String, delete: Bool? = nil) {
            self.folder = folder; self.origin = origin; self.id = id; self.content = content; self.delete = delete
        }
    }

    /// `personas/list`: the personas a start in this folder can pick, the folder's and
    /// the home's together, one per id with the folder's winning, by name.
    public struct PersonasListRequest: Codable, Sendable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
    }
}
