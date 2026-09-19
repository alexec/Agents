import Foundation

/// What a runtime last said it offers, kept so the start form appears at once.
///
/// Asking the question costs a runtime: the options only exist once `session/new` has
/// answered, and that is seconds of process start, handshake and sign-in check. The
/// answer, meanwhile, is nearly always the one it gave last time — the same models, the
/// same modes, the same commands. So the last answer is shown while the real one is
/// fetched behind it, and the form is put right if it has moved.
///
/// One file, read whole and written whole, the way projects are. Losing it costs the
/// next form its speed and nothing else.
public struct OptionCache: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var options: [ConfigOption]
        public var commands: [SlashCommand]
        public var savedAt: Date

        public init(options: [ConfigOption], commands: [SlashCommand], savedAt: Date = Date()) {
            self.options = options
            self.commands = commands
            self.savedAt = savedAt
        }

        /// What was advertised, without when we heard it. Two entries that offer the
        /// same are the same form, however long apart they were saved.
        public var offers: Offers { Offers(options: options, commands: commands) }

        public struct Offers: Hashable, Sendable {
            public var options: [ConfigOption]
            public var commands: [SlashCommand]
        }

        /// Whether this is worth showing. A runtime that advertised nothing is a
        /// question we may as well ask again.
        public var isWorthKeeping: Bool { !options.isEmpty || !commands.isEmpty }
    }

    /// How many runtime-and-folder pairs to remember. A person works in a handful of
    /// folders with a handful of runtimes; past that the oldest go.
    static let limit = 50

    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    /// What decides that two asks have the same answer.
    ///
    /// The runtime advertises the models and modes, and the folder decides the
    /// commands, since a project's own `/` commands come from files inside it. MCP
    /// servers are in here too because a runtime can offer a server's prompts as
    /// commands — by name only, so a server that keeps its name and changes its address
    /// is a stale entry, which the refresh behind the form corrects.
    public static func key(runtimeID: String, cwd: URL, mcpServers: [MCPServer]) -> String {
        let servers = mcpServers.map(\.name).sorted().joined(separator: ",")
        return "\(runtimeID)\t\(cwd.standardizedFileURL.path)\t\(servers)"
    }

    public func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: locations.optionCache),
              let entries = try? StoreCoding.decoder.decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }

    public func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let kept = entries.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(Self.limit)
        let data = try StoreCoding.encoder.encode([String: Entry](uniqueKeysWithValues: kept.map { ($0.key, $0.value) }))
        try data.write(to: locations.optionCache, options: .atomic)
    }
}
