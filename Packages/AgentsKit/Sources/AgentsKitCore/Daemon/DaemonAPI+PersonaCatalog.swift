import Foundation

/// Personas from a marketplace (#3665): a GitHub marketplace's `personas/<id>.md`, searched,
/// shown whole, added to `.agents/personas` at one commit and named in the lock, and updated
/// only when the person says so. The requests are the skill catalogue's; the answers are
/// these. Like the skills', none is in `agentMethods`.
extension DaemonAPI.Method {
    public static let personasSearch = "personas/search"
    public static let personasPreview = "personas/preview"
    public static let personasAdd = "personas/add"
    public static let personasManaged = "personas/managed"
    public static let personasCheckUpdates = "personas/check-updates"
    public static let personasUpdatePreview = "personas/update-preview"
    public static let personasRemove = "personas/remove"
}

extension DaemonAPI {
    /// A persona file fetched at one commit, shown whole before it is added.
    public struct PersonaPreview: Codable, Hashable, Sendable {
        public var previewID: UUID
        public var result: CatalogResult
        /// Its path in the repository, `personas/<id>.md`.
        public var path: String
        public var commit: String
        public var blobSHA: String
        public var committedAt: Date?
        /// The whole file, front matter included.
        public var markdown: String
        /// The file as the start form reads it: the settings it sets, or why it can't be read.
        public var persona: Persona
        public var destinationState: DestinationState

        public init(previewID: UUID, result: CatalogResult, path: String, commit: String, blobSHA: String,
                    committedAt: Date? = nil, markdown: String, persona: Persona,
                    destinationState: DestinationState = .free) {
            self.previewID = previewID
            self.result = result
            self.path = path
            self.commit = commit
            self.blobSHA = blobSHA
            self.committedAt = committedAt
            self.markdown = markdown
            self.persona = persona
            self.destinationState = destinationState
        }
    }

    public struct PersonaPreviewAnswer: Codable, Sendable, Equatable {
        public var preview: PersonaPreview?
        public var error: CatalogError?
        public init(preview: PersonaPreview?, error: CatalogError? = nil) {
            self.preview = preview
            self.error = error
        }
    }

    /// A persona a lock names: added from a marketplace, and so one the app may update and
    /// remove. One the person made is never one of these.
    public struct ManagedPersona: Codable, Hashable, Sendable, Identifiable {
        public var destination: SkillDestination
        public var id: String
        /// `owner/repo`.
        public var source: String
        public var path: String
        public var commit: String?
        /// The file no longer has what was added: the person has edited it.
        public var edited: Bool
        public var update: UpdateState

        public init(destination: SkillDestination, id: String, source: String, path: String, commit: String? = nil,
                    edited: Bool = false, update: UpdateState = .unknown) {
            self.destination = destination
            self.id = id
            self.source = source
            self.path = path
            self.commit = commit
            self.edited = edited
            self.update = update
        }
    }

    public struct PersonaAddAnswer: Codable, Sendable, Equatable {
        public var persona: ManagedPersona
        public init(persona: ManagedPersona) { self.persona = persona }
    }

    public struct PersonasManagedAnswer: Codable, Sendable, Equatable {
        public var personas: [ManagedPersona]
        public init(personas: [ManagedPersona]) { self.personas = personas }
    }

    /// A setting an update changes that the person is warned about: `runtime` or
    /// `permission-mode`, with nil for not set.
    public struct PersonaSettingChange: Codable, Hashable, Sendable {
        public var key: String
        public var old: String?
        public var new: String?
        public init(key: String, old: String?, new: String?) {
            self.key = key
            self.old = old
            self.new = new
        }
    }

    public struct PersonaUpdatePreviewAnswer: Codable, Sendable, Equatable {
        public var preview: PersonaPreview
        /// The file as it is now, for the diff.
        public var installed: String
        public var edited: Bool
        public var changes: [PersonaSettingChange]
        public init(preview: PersonaPreview, installed: String, edited: Bool, changes: [PersonaSettingChange]) {
            self.preview = preview
            self.installed = installed
            self.edited = edited
            self.changes = changes
        }
    }
}
