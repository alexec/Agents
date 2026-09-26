import Foundation

/// The person's own `~/.agents`, shared by every agent the way a project's `.agents` is
/// shared by every agent working in it (054).
///
///     ~/.agents/AGENTS.md          instructions
///     ~/.agents/skills/<name>/     skills
///     ~/.agents/personas/          personas
///
/// It is the one real copy. What each runtime needs to see it was settled by running
/// every runtime against a scratch home (research R1, R9), not read off their binaries:
/// Codex, Grok, Cursor and Copilot already read `~/.agents/skills`, so only Claude gets
/// links, one per skill, inside its own `~/.claude/skills` — never in place of that
/// folder, because claude.ai keeps its synced skills in there.
///
/// Unlike a project, which is laid out once, the home is reconciled every time: before
/// each session is made, so a skill added a minute ago is there for the next agent. So
/// it keeps a record of the links it placed, and a link the person deleted stays deleted.
public enum PersonalDotAgents {
    public static let folder = ".agents"
    public static let skills = "skills"
    public static let personas = "personas"
    public static let router = "AGENTS.md"

    /// How a runtime is handed a personal plugin (research R12).
    public enum PluginHandover: Sendable {
        /// In the session's `_meta`, as project plugins are.
        case sessionMeta
        /// In `_meta`, and the plugins' own MCP servers in `mcpServers`, because it does
        /// not start them itself (Grok).
        case sessionMetaWithServers
        /// Through an index in `~/.agents/plugins` and its own `plugin add` (Codex).
        case codexMarketplace
        /// A link in its extensions folder (Gemini).
        case extensionLink
        /// No way in from the app (Cursor; Copilot over ACP).
        case none
    }

    /// What one runtime needs from the home layout, as the probe found it.
    public struct Rule: Sendable {
        public var runtimeID: String
        /// Where its own things live, relative to the home.
        public var configFolder: String
        /// Whether it reads `~/.agents/skills` by itself.
        public var readsSharedSkills: Bool
        /// Where its skill links go, for a runtime that does not read the shared folder.
        public var skillsFolder: String?
        /// The file it reads personal instructions from; nil when it has none.
        public var instructionsFile: String?
        /// Whether its real skills and instructions move into `~/.agents` (R3).
        public var adopts: Bool
        /// Whether it takes a stdio MCP server from the client (R9: Copilot does not).
        public var takesStdioServers: Bool
        public var pluginHandover: PluginHandover
    }

    /// Gemini has no skills or instructions rule until it is probed (R14), so it gets no
    /// links: a runtime with nothing known about it is left alone.
    public static let rules: [Rule] = [
        Rule(runtimeID: "claude", configFolder: ".claude", readsSharedSkills: false,
             skillsFolder: ".claude/skills", instructionsFile: ".claude/CLAUDE.md",
             adopts: true, takesStdioServers: true, pluginHandover: .sessionMeta),
        Rule(runtimeID: "codex", configFolder: ".codex", readsSharedSkills: true,
             skillsFolder: nil, instructionsFile: ".codex/AGENTS.md",
             adopts: false, takesStdioServers: true, pluginHandover: .codexMarketplace),
        Rule(runtimeID: "grok", configFolder: ".grok", readsSharedSkills: true,
             skillsFolder: nil, instructionsFile: ".grok/AGENTS.md",
             adopts: false, takesStdioServers: true, pluginHandover: .sessionMetaWithServers),
        Rule(runtimeID: "cursor", configFolder: ".cursor", readsSharedSkills: true,
             skillsFolder: nil, instructionsFile: nil,
             adopts: false, takesStdioServers: true, pluginHandover: .none),
        Rule(runtimeID: "copilot", configFolder: ".copilot", readsSharedSkills: true,
             skillsFolder: nil, instructionsFile: ".copilot/copilot-instructions.md",
             adopts: false, takesStdioServers: false, pluginHandover: .none),
        Rule(runtimeID: "gemini", configFolder: ".gemini", readsSharedSkills: false,
             skillsFolder: nil, instructionsFile: nil,
             adopts: false, takesStdioServers: true, pluginHandover: .extensionLink),
    ]

    public static func rule(for runtimeID: String) -> Rule? {
        rules.first { $0.runtimeID == runtimeID }
    }

    // MARK: - The record

    /// What the app has placed in one home (data-model `PlacedLinks`), kept in the
    /// daemon's root so nothing of ours litters `~/.agents`, which other tools write too.
    public struct Record: Codable, Equatable, Sendable {
        public var home: String
        /// Link path, relative to the home, to the destination it was given.
        public var links: [String: String] = [:]
        /// The last fingerprint of each plugin added to Codex (R12).
        public var codexPlugins: [String: String] = [:]

        public init(home: String) { self.home = home }

        /// The record for this home: a missing or unreadable file, or one written for a
        /// different home, is an empty record.
        public static func load(from url: URL, home: URL) -> Record {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.home == home.path else { return Record(home: home.path) }
            return record
        }

        public func save(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    // MARK: - Reconcile

    /// Bring the home in line with `~/.agents`, for the runtimes that are installed.
    /// Every step is its own attempt (FR-012), and running it twice with nothing changed
    /// changes nothing (FR-011).
    public static func reconcile(home: URL, installed: Set<String>, record: inout Record) {
        let shared = home.appending(path: folder, directoryHint: .isDirectory)
        for name in [skills, personas] {
            attempt("create \(folder)/\(name)") {
                try FileManager.default.createDirectory(at: shared.appending(path: name, directoryHint: .isDirectory),
                                                        withIntermediateDirectories: true)
            }
        }
        for rule in rules where installed.contains(rule.runtimeID) {
            if let skillsFolder = rule.skillsFolder {
                linkSkills(home: home, into: skillsFolder, record: &record)
            }
        }
    }

    /// One link per skill in a runtime's own skills folder (research R2), following
    /// data-model's table:
    ///
    ///     nothing there, not recorded   place the link, record it
    ///     nothing there, recorded       leave it: the person removed it
    ///     a link into the shared skill  leave it; record it if we had not
    ///     any other link, a real folder leave it
    static func linkSkills(home: URL, into skillsFolder: String, record: inout Record) {
        let fileManager = FileManager.default
        let target = home.appending(path: skillsFolder, directoryHint: .isDirectory)
        // Somebody linked the whole folder somewhere: that is theirs, and links placed
        // inside it would land wherever it points.
        if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil { return }
        let depth = skillsFolder.split(separator: "/").count
        for skill in sharedSkills(home: home) {
            let relative = "\(skillsFolder)/\(skill)"
            let url = target.appending(path: skill)
            let destination = String(repeating: "../", count: depth) + "\(folder)/\(skills)/\(skill)"
            if isManaged(url) || managedNames.contains(skill) {
                DaemonLog.shared.write("personal layout: left \(relative) alone, a name another tool manages")
                continue
            }
            if let existing = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
                if resolves(existing, from: url, to: home.appending(path: "\(folder)/\(skills)/\(skill)")) {
                    record.links[relative] = record.links[relative] ?? existing
                }
                continue
            }
            if DotAgents.exists(url) { continue }  // a real folder of the person's: a clash, left alone
            if record.links[relative] != nil { continue }  // placed once, removed by the person
            attempt("link \(relative)") {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
                record.links[relative] = destination
            }
        }
    }

    /// The skills in `~/.agents/skills`: folders, or links to folders, that are not hidden.
    static func sharedSkills(home: URL) -> [String] {
        let url = home.appending(path: "\(folder)/\(skills)", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return entries.sorted().filter { name in
            !name.hasPrefix(".") && DotAgents.isDirectory(url.appending(path: name).resolvingSymlinksInPath())
        }
    }

    /// Names another tool owns inside a runtime's skills folder (FR-007).
    static let managedNames: Set<String> = ["synced"]

    /// A folder another tool keeps in step: claude.ai's sync marks its own.
    static func isManaged(_ url: URL) -> Bool {
        guard DotAgents.isDirectory(url) else { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return entries.contains { $0.hasPrefix(".bucket-") || $0 == ".sync-manifest.json" }
    }

    /// Whether a link's destination, read relative to the link's own folder, is `target`.
    static func resolves(_ destination: String, from link: URL, to target: URL) -> Bool {
        let resolved = destination.hasPrefix("/")
            ? URL(filePath: destination)
            : link.deletingLastPathComponent().appending(path: destination)
        return resolved.standardizedFileURL.path == target.standardizedFileURL.path
    }

    static func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { DaemonLog.shared.write("personal layout: could not \(what): \(error)") }
    }
}
