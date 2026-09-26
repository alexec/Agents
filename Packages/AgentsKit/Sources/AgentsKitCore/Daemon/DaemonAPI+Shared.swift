import Foundation

/// `personal/shared` (054, contracts/personal-shared.md): what is in the person's
/// `~/.agents` and which runtime gets each thing, for Settings ▸ Shared. Read-only, worked
/// out from disk on every call, and for the Mac window only.
///
/// Nothing in it is a value from `mcp.json`: a server's env and headers go by name only,
/// and its command or URL is cut short of anything that looks like a secret (FR-023).
extension DaemonAPI.Method {
    public static let personalShared = "personal/shared"
}

extension DaemonAPI {
    public struct SharedSnapshot: Codable, Equatable, Sendable {
        /// `~/.agents`.
        public var home: String
        /// False for a copy of the app with no personal home (a scratch root), when
        /// everything else is empty.
        public var laidOut: Bool
        /// The installed runtimes with a rule, in the rule table's order: the columns.
        public var runtimes: [RuntimeName]
        public var instructions: Instructions?
        public var skills: [Skill]
        public var mcp: MCP
        public var plugins: [Plugin]
        public var otherFiles: [OtherFile]
        public var needsALook: [Look]

        public init(home: String, laidOut: Bool, runtimes: [RuntimeName] = [], instructions: Instructions? = nil,
                    skills: [Skill] = [], mcp: MCP = MCP(), plugins: [Plugin] = [], otherFiles: [OtherFile] = [],
                    needsALook: [Look] = []) {
            self.home = home
            self.laidOut = laidOut
            self.runtimes = runtimes
            self.instructions = instructions
            self.skills = skills
            self.mcp = mcp
            self.plugins = plugins
            self.otherFiles = otherFiles
            self.needsALook = needsALook
        }
    }

    public struct RuntimeName: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// What one runtime does with one thing.
    public enum Reach: Equatable, Sendable {
        /// It gets it, and how.
        case gets(String)
        /// It uses a copy of its own of that name, at this path, instead.
        case ownCopy(String)
        /// It could, and this one is left out: why.
        case leftOut(String)
        /// It has no way to take this from the app.
        case noWay(String)
        /// Nobody has measured it yet (Gemini, research R14).
        case unchecked(String?)

        public var gets: Bool { if case .gets = self { true } else { false } }

        public var note: String? {
            switch self {
            case .gets(let note), .ownCopy(let note), .leftOut(let note), .noWay(let note): note
            case .unchecked(let note): note
            }
        }
    }

    public struct Instructions: Codable, Equatable, Sendable {
        public var path: String
        public var exists: Bool
        public var reach: [String: Reach]

        public init(path: String, exists: Bool, reach: [String: Reach]) {
            self.path = path
            self.exists = exists
            self.reach = reach
        }
    }

    public struct Skill: Codable, Equatable, Sendable, Identifiable {
        public enum Source: Equatable, Sendable {
            case personal
            case plugin(String)
        }

        public var name: String
        public var path: String
        public var description: String?
        public var source: Source
        /// The other copy of a skill of this name, left where it was.
        public var clash: String?
        public var reach: [String: Reach]

        public var id: String {
            switch source {
            case .personal: "personal/\(name)"
            case .plugin(let plugin): "plugin/\(plugin)/\(name)"
            }
        }

        public init(name: String, path: String, description: String?, source: Source, clash: String?,
                    reach: [String: Reach]) {
            self.name = name
            self.path = path
            self.description = description
            self.source = source
            self.clash = clash
            self.reach = reach
        }
    }

    public struct MCP: Codable, Equatable, Sendable {
        public var file: String
        public var problem: Problem?
        /// The person's, from `mcp.json`.
        public var servers: [Server]
        /// The app's own, sent to every agent.
        public var app: [Server]
        /// Set up in one runtime's own config and nowhere else.
        public var runtimeOnly: [RuntimeOnlyServer]

        public init(file: String = "", problem: Problem? = nil, servers: [Server] = [], app: [Server] = [],
                    runtimeOnly: [RuntimeOnlyServer] = []) {
            self.file = file
            self.problem = problem
            self.servers = servers
            self.app = app
            self.runtimeOnly = runtimeOnly
        }
    }

    public struct Problem: Codable, Equatable, Sendable {
        public var message: String
        public var line: Int?

        public init(message: String, line: Int?) {
            self.message = message
            self.line = line
        }
    }

    public struct Server: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        /// `stdio`, `http` or `sse`.
        public var transport: String
        /// The command and its first arguments, or the URL without its query.
        public var summary: String
        public var envNames: [String]
        public var headerNames: [String]
        /// The runtimes that have a server of this name in their own config.
        public var clash: [String: String]
        public var reach: [String: Reach]

        public var id: String { name }

        public init(name: String, transport: String, summary: String, envNames: [String] = [],
                    headerNames: [String] = [], clash: [String: String] = [:], reach: [String: Reach]) {
            self.name = name
            self.transport = transport
            self.summary = summary
            self.envNames = envNames
            self.headerNames = headerNames
            self.clash = clash
            self.reach = reach
        }
    }

    public struct RuntimeOnlyServer: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var runtimeID: String
        public var file: String

        public var id: String { "\(runtimeID)/\(name)" }

        public init(name: String, runtimeID: String, file: String) {
            self.name = name
            self.runtimeID = runtimeID
            self.file = file
        }
    }

    public struct Plugin: Codable, Equatable, Sendable, Identifiable {
        public struct Contents: Codable, Equatable, Sendable {
            public var skills: Int
            public var commands: Int
            public var agents: Int
            public var hooks: Int
            public var mcpServers: Int

            public init(skills: Int, commands: Int, agents: Int, hooks: Int, mcpServers: Int) {
                self.skills = skills
                self.commands = commands
                self.agents = agents
                self.hooks = hooks
                self.mcpServers = mcpServers
            }
        }

        public var name: String
        public var version: String?
        public var description: String?
        public var path: String
        public var contents: Contents
        /// Its files, relative to its folder, for the detail's tree.
        public var files: [String]
        /// Its MCP servers' names.
        public var serverNames: [String]
        public var reach: [String: Reach]

        public var id: String { path }

        public init(name: String, version: String?, description: String?, path: String, contents: Contents,
                    files: [String], serverNames: [String], reach: [String: Reach]) {
            self.name = name
            self.version = version
            self.description = description
            self.path = path
            self.contents = contents
            self.files = files
            self.serverNames = serverNames
            self.reach = reach
        }
    }

    public struct OtherFile: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case persona, git, managed, unused
        }

        /// Relative to `~/.agents`.
        public var path: String
        public var kind: Kind

        public var id: String { path }

        public init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }
    }

    /// Something the overview lists under Needs a look, and the page it opens.
    public struct Look: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case clash, leftOut, noWay, noFile, problem
        }

        public enum Page: String, Codable, Sendable {
            case instructions, skills, mcp, plugins, other
        }

        public var kind: Kind
        public var page: Page
        /// What it is about: a skill, a server, a runtime's name.
        public var item: String
        public var text: String

        public var id: String { "\(kind.rawValue)/\(page.rawValue)/\(item)" }

        public init(kind: Kind, page: Page, item: String, text: String) {
            self.kind = kind
            self.page = page
            self.item = item
            self.text = text
        }
    }
}

// MARK: - Wire shapes

/// `{"gets": "…"}`, `{"ownCopy": "…"}`, `{"leftOut": "…"}`, `{"noWay": "…"}`, and
/// `"unchecked"` or `{"unchecked": "…"}`.
extension DaemonAPI.Reach: Codable {
    private enum Key: String, CodingKey { case gets, ownCopy, leftOut, noWay, unchecked }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let word = try? single.decode(String.self) {
            guard word == "unchecked" else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "unknown reach \(word)")
            }
            self = .unchecked(nil)
            return
        }
        let container = try decoder.container(keyedBy: Key.self)
        if let note = try container.decodeIfPresent(String.self, forKey: .gets) { self = .gets(note) }
        else if let note = try container.decodeIfPresent(String.self, forKey: .ownCopy) { self = .ownCopy(note) }
        else if let note = try container.decodeIfPresent(String.self, forKey: .leftOut) { self = .leftOut(note) }
        else if let note = try container.decodeIfPresent(String.self, forKey: .noWay) { self = .noWay(note) }
        else { self = .unchecked(try container.decodeIfPresent(String.self, forKey: .unchecked)) }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .unchecked(nil) = self {
            var single = encoder.singleValueContainer()
            try single.encode("unchecked")
            return
        }
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .gets(let note): try container.encode(note, forKey: .gets)
        case .ownCopy(let note): try container.encode(note, forKey: .ownCopy)
        case .leftOut(let note): try container.encode(note, forKey: .leftOut)
        case .noWay(let note): try container.encode(note, forKey: .noWay)
        case .unchecked(let note): try container.encode(note, forKey: .unchecked)
        }
    }
}

/// `"personal"` or `{"plugin": "<name>"}`.
extension DaemonAPI.Skill.Source: Codable {
    private enum Key: String, CodingKey { case plugin }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), (try? single.decode(String.self)) == "personal" {
            self = .personal
            return
        }
        self = .plugin(try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .plugin))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .personal:
            var single = encoder.singleValueContainer()
            try single.encode("personal")
        case .plugin(let name):
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(name, forKey: .plugin)
        }
    }
}
