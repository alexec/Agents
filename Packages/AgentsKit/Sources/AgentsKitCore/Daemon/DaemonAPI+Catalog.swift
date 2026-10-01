import Foundation

/// Searching a catalogue and adding skills to the person or a project (059,
/// contracts/catalog-methods.md).
///
/// Every one of these is for the Mac's own window. None is in `deviceMethods` or
/// `agentMethods`, so a phone, an agent's helper or a stranger is refused before the daemon
/// looks at the request: what an agent may do is its business, and adding a skill changes
/// what every agent after it is told.
extension DaemonAPI.Method {
    public static let catalogSearch = "catalog/search"
    public static let catalogPreview = "catalog/preview"
    public static let catalogDestinationState = "catalog/destination-state"
    public static let skillsAdd = "skills/add"
    public static let skillsList = "skills/list"
    public static let skillsCheckUpdates = "skills/check-updates"
    public static let skillsUpdatePreview = "skills/update-preview"
    public static let skillsRemove = "skills/remove"

}

extension DaemonAPI.Failure {
    /// A catalogue call that could not do what it was asked. `data` is a `CatalogError`,
    /// which says which and is what the sheet shows.
    public static let catalogRefused = -32080
}

extension DaemonAPI {
    /// Where a skill goes: the person's own `~/.agents/skills`, or a project's (or one of
    /// its worktrees') `.agents/skills`.
    public enum SkillDestination: Codable, Hashable, Sendable {
        case personal
        case project(folder: String)

        private enum CodingKeys: String, CodingKey { case kind, folder }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "personal": self = .personal
            case "project": self = .project(folder: try c.decode(String.self, forKey: .folder))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "no destination \(other)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .personal: try c.encode("personal", forKey: .kind)
            case .project(let folder):
                try c.encode("project", forKey: .kind)
                try c.encode(folder, forKey: .folder)
            }
        }
    }

    /// One skill a catalogue lists (frame B).
    public struct CatalogResult: Codable, Hashable, Sendable, Identifiable {
        /// The catalogue's own id, `owner/repo/skillId`.
        public var id: String
        public var name: String
        public var owner: String
        public var repo: String
        public var skillID: String
        public var installs: Int
        /// The owner is on the app's short list (research R11). A mark, never a gate.
        public var known: Bool

        public init(id: String, name: String, owner: String, repo: String, skillID: String, installs: Int, known: Bool) {
            self.id = id
            self.name = name
            self.owner = owner
            self.repo = repo
            self.skillID = skillID
            self.installs = installs
            self.known = known
        }

        public var source: String { "\(owner)/\(repo)" }
    }

    /// Why a catalogue call could not do what it was asked, in the words the sheet uses.
    public enum CatalogError: Error, Codable, Hashable, Sendable {
        /// The catalogue or GitHub did not answer. The host is the one that did not.
        case unreachable(host: String)
        /// GitHub's API limit is spent and the tarball fallback failed too.
        case rateLimited(retryAfter: Int?)
        /// A folder of that name that no lock names: the person's own, left alone.
        case unmanaged(path: String)
        /// A lock file the app will not write, because writing it would lose what is in it.
        case lockUnreadable(path: String)
        /// This copy of the app has no personal home (a scratch root with none named).
        case noPersonalHome
        /// The preview was used, swept or never made.
        case previewExpired
        /// A folder that is not a project on this Mac, or a worktree of one.
        case notAProject(path: String)
        /// Replace was needed and not asked for, or asked for where there is nothing to replace.
        case replaceMismatch
        /// The preview found something that means it cannot be added.
        case cannotAdd([PreviewProblem])
        /// The skill named is not one a lock names at that destination.
        case notManaged(name: String)
        /// A step failed on disk; the destination was put back as it was.
        case failed(String)
    }

    public struct CatalogSearchRequest: Codable, Sendable {
        public var query: String
        /// `skills` (default, 059) or `mcp` (060).
        public var kind: CatalogKind
        public init(query: String, kind: CatalogKind = .skills) {
            self.query = query
            self.kind = kind
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            query = try c.decode(String.self, forKey: .query)
            kind = try c.decodeIfPresent(CatalogKind.self, forKey: .kind) ?? .skills
        }

        private enum CodingKeys: String, CodingKey { case query, kind }
    }

    public struct CatalogSearchAnswer: Codable, Sendable, Equatable {
        public var results: [CatalogResult]
        /// Set instead of an empty list when the catalogue could not be asked.
        public var error: CatalogError?
        public init(results: [CatalogResult], error: CatalogError? = nil) {
            self.results = results
            self.error = error
        }
    }

    /// One file in a preview (frame C's list).
    public struct PreviewFile: Codable, Hashable, Sendable {
        public var path: String
        public var bytes: Int
        /// An agent could run it: executable in the repository, under `scripts/`, or `#!`.
        public var runnable: Bool
        /// Where its bytes came from: `snapshot`, `raw` or `tarball`. For the log.
        public var via: String

        public init(path: String, bytes: Int, runnable: Bool, via: String) {
            self.path = path
            self.bytes = bytes
            self.runnable = runnable
            self.via = via
        }
    }

    /// Something a preview found. Any but `skipped` means Add is not offered.
    public enum PreviewProblem: Codable, Hashable, Sendable {
        case noSkillFile
        case notFoundInRepo
        case tooLarge(bytes: Int, files: Int)
        /// Links and paths that would land outside the folder, left out and listed.
        case skipped([String])

        public var blocksAdding: Bool {
            if case .skipped = self { return false }
            return true
        }
    }

    /// What is at the destination already, for the skill a preview is of.
    public enum DestinationState: Codable, Hashable, Sendable {
        case free
        /// A lock names the same source and path: added. `update` when the preview differs.
        case sameSkill(update: Bool)
        /// A lock names this name from somewhere else: Add becomes Replace.
        case managedOther(source: String)
        /// A folder of this name that no lock names: never touched.
        case unmanaged(path: String)
        /// There is nowhere to put it (no personal home, or not a project).
        case unavailable(CatalogError)
    }

    /// A skill fetched at one commit and staged, not yet anywhere an agent looks (frame C).
    public struct SkillPreview: Codable, Hashable, Sendable {
        public var previewID: UUID
        public var result: CatalogResult
        /// Front matter `name`, made into the folder name the CLI would give it.
        public var name: String
        public var description: String
        public var skillPath: String
        public var commit: String
        public var committedAt: Date?
        public var treeSHA: String
        public var computedHash: String
        public var files: [PreviewFile]
        public var skillMarkdown: String
        public var totalBytes: Int
        public var problems: [PreviewProblem]
        public var destinationState: DestinationState

        public init(previewID: UUID, result: CatalogResult, name: String, description: String, skillPath: String,
                    commit: String, committedAt: Date?, treeSHA: String, computedHash: String, files: [PreviewFile],
                    skillMarkdown: String, totalBytes: Int, problems: [PreviewProblem], destinationState: DestinationState) {
            self.previewID = previewID
            self.result = result
            self.name = name
            self.description = description
            self.skillPath = skillPath
            self.commit = commit
            self.committedAt = committedAt
            self.treeSHA = treeSHA
            self.computedHash = computedHash
            self.files = files
            self.skillMarkdown = skillMarkdown
            self.totalBytes = totalBytes
            self.problems = problems
            self.destinationState = destinationState
        }

        public var canAdd: Bool { !problems.contains(where: \.blocksAdding) }
        public var runnableFiles: [PreviewFile] { files.filter(\.runnable) }
    }

    public struct CatalogPreviewRequest: Codable, Sendable {
        public var result: CatalogResult
        public var destination: SkillDestination
        public init(result: CatalogResult, destination: SkillDestination) {
            self.result = result
            self.destination = destination
        }
    }

    public struct CatalogPreviewAnswer: Codable, Sendable, Equatable {
        public var preview: SkillPreview?
        public var error: CatalogError?
        public init(preview: SkillPreview?, error: CatalogError? = nil) {
            self.preview = preview
            self.error = error
        }
    }

    public struct DestinationStateRequest: Codable, Sendable {
        public var previewID: UUID
        public var destination: SkillDestination
        public init(previewID: UUID, destination: SkillDestination) {
            self.previewID = previewID
            self.destination = destination
        }
    }

    public struct DestinationStateAnswer: Codable, Sendable, Equatable {
        public var destinationState: DestinationState
        public init(destinationState: DestinationState) { self.destinationState = destinationState }
    }

    public struct SkillAddRequest: Codable, Sendable {
        public var previewID: UUID
        public var destination: SkillDestination
        public var replace: Bool
        public init(previewID: UUID, destination: SkillDestination, replace: Bool = false) {
            self.previewID = previewID
            self.destination = destination
            self.replace = replace
        }
    }

    /// Whether a managed skill's source has moved on.
    public enum UpdateState: Codable, Hashable, Sendable {
        case unknown
        case current
        case available(commit: String)
    }

    /// A skill a lock names: added by the app or by `npx skills`, and so one the app may
    /// update and remove (research R5).
    public struct ManagedSkill: Codable, Hashable, Sendable {
        public var destination: SkillDestination
        public var name: String
        /// `owner/repo`.
        public var source: String
        public var skillPath: String?
        /// What the lock recorded: the folder's tree SHA (personal) or `computedHash` (project).
        public var recordedHash: String?
        /// From the app's own sidecar; nil for a skill the CLI added.
        public var commit: String?
        public var committedAt: Date?
        public var catalogue: String?
        /// The folder no longer matches what was recorded: the person has edited it.
        public var edited: Bool
        public var update: UpdateState

        public init(destination: SkillDestination, name: String, source: String, skillPath: String?,
                    recordedHash: String?, commit: String? = nil, committedAt: Date? = nil, catalogue: String? = nil,
                    edited: Bool = false, update: UpdateState = .unknown) {
            self.destination = destination
            self.name = name
            self.source = source
            self.skillPath = skillPath
            self.recordedHash = recordedHash
            self.commit = commit
            self.committedAt = committedAt
            self.catalogue = catalogue
            self.edited = edited
            self.update = update
        }
    }

    public struct SkillAddAnswer: Codable, Sendable, Equatable {
        public var skill: ManagedSkill
        public init(skill: ManagedSkill) { self.skill = skill }
    }

    public struct SkillsListRequest: Codable, Sendable {
        public var destination: SkillDestination
        public init(destination: SkillDestination) { self.destination = destination }
    }

    /// A skill in a project's `.agents/skills` (frame D).
    public struct ListedSkill: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        public var description: String?
        public var folder: String
        public var managed: ManagedSkill?
        public var id: String { name }

        public init(name: String, description: String?, folder: String, managed: ManagedSkill?) {
            self.name = name
            self.description = description
            self.folder = folder
            self.managed = managed
        }
    }

    public struct SkillsListAnswer: Codable, Sendable, Equatable {
        public var skills: [ListedSkill]
        public init(skills: [ListedSkill]) { self.skills = skills }
    }

    public struct SkillNameRequest: Codable, Sendable {
        public var destination: SkillDestination
        public var name: String
        public init(destination: SkillDestination, name: String) {
            self.destination = destination
            self.name = name
        }
    }

    public struct SkillUpdatesAnswer: Codable, Sendable, Equatable {
        public var updates: [String: UpdateState]
        public init(updates: [String: UpdateState]) { self.updates = updates }
    }

    public struct SkillChanges: Codable, Hashable, Sendable {
        public var added: [String]
        public var changed: [String]
        public var removed: [String]
        public init(added: [String], changed: [String], removed: [String]) {
            self.added = added
            self.changed = changed
            self.removed = removed
        }
    }

    public struct SkillUpdatePreviewAnswer: Codable, Sendable, Equatable {
        public var preview: SkillPreview
        public var changes: SkillChanges
        public var edited: Bool
        public init(preview: SkillPreview, changes: SkillChanges, edited: Bool) {
            self.preview = preview
            self.changes = changes
            self.edited = edited
        }
    }

    public struct SkillRemoveAnswer: Codable, Sendable, Equatable {
        public var trashedTo: String
        public init(trashedTo: String) { self.trashedTo = trashedTo }
    }
}
