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
        let present = rules.filter { installed.contains($0.runtimeID) }
        // What the person already has moves in first, so the links below point at it.
        for rule in present where rule.adopts {
            if let skillsFolder = rule.skillsFolder {
                adoptSkills(home: home, from: skillsFolder, record: &record)
            }
        }
        adoptInstructions(home: home, from: present, record: &record)
        writeRouterIfMissing(home: home)
        for rule in present {
            if let skillsFolder = rule.skillsFolder {
                sweep(home: home, skillsFolder: skillsFolder, record: &record)
                linkSkills(home: home, into: skillsFolder, record: &record)
            }
            if let instructionsFile = rule.instructionsFile {
                placeLink(home: home, at: instructionsFile, to: "\(folder)/\(router)", record: &record)
            }
            if rule.pluginHandover == .extensionLink {
                linkGeminiExtensions(home: home, record: &record)
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
        for skill in sharedSkills(home: home) {
            let relative = "\(skillsFolder)/\(skill)"
            let url = target.appending(path: skill)
            if isManaged(url) || managedNames.contains(skill) {
                DaemonLog.shared.write("personal layout: left \(relative) alone, a name another tool manages")
                continue
            }
            placeLink(home: home, at: relative, to: "\(folder)/\(skills)/\(skill)", record: &record)
        }
    }

    /// One link at `path` to `shared` (both relative to the home), by data-model's table.
    /// A real file or folder there is the person's, and a clash: left alone.
    static func placeLink(home: URL, at path: String, to shared: String, record: inout Record) {
        let fileManager = FileManager.default
        let url = home.appending(path: path)
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            if resolves(existing, from: url, to: home.appending(path: shared)) {
                record.links[path] = record.links[path] ?? existing
            }
            return
        }
        if DotAgents.exists(url) { return }
        if record.links[path] != nil { return }  // placed once, removed by the person (FR-009)
        let depth = path.split(separator: "/").count - 1
        let destination = String(repeating: "../", count: depth) + shared
        attempt("link \(path)") {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
            record.links[path] = destination
        }
    }

    // MARK: - Adopting what is already there (US3)

    /// Each real skill folder in a runtime's own skills folder moves to `~/.agents/skills`
    /// when that name is free there; the link step then links it back (FR-005). A taken
    /// name leaves both where they are. A failed move leaves the original in place, since
    /// a move on one disk is a rename.
    static func adoptSkills(home: URL, from skillsFolder: String, record: inout Record) {
        let fileManager = FileManager.default
        let source = home.appending(path: skillsFolder, directoryHint: .isDirectory)
        if (try? fileManager.destinationOfSymbolicLink(atPath: source.path)) != nil { return }
        let shared = home.appending(path: "\(folder)/\(skills)", directoryHint: .isDirectory)
        let entries = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
        for name in entries.sorted() where !name.hasPrefix(".") && !managedNames.contains(name) {
            let url = source.appending(path: name)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
                  DotAgents.isDirectory(url), !isManaged(url),
                  !DotAgents.exists(shared.appending(path: name)) else { continue }
            attempt("move \(skillsFolder)/\(name) into \(folder)/\(skills)") {
                try fileManager.moveItem(at: url, to: shared.appending(path: name))
                // A real folder where our link once was: the person put it back, so the
                // link that replaces it is wanted.
                record.links.removeValue(forKey: "\(skillsFolder)/\(name)")
                DaemonLog.shared.write("personal layout: moved \(skillsFolder)/\(name) into \(folder)/\(skills)")
            }
        }
    }

    /// The order a real instructions file is looked for when `~/.agents/AGENTS.md` is
    /// missing; only the first found moves (FR-006, research R3).
    static let adoptionOrder = ["claude", "codex", "copilot", "grok"]

    static func adoptInstructions(home: URL, from present: [Rule], record: inout Record) {
        let fileManager = FileManager.default
        let shared = home.appending(path: "\(folder)/\(router)")
        guard !DotAgents.exists(shared) else { return }
        for id in adoptionOrder {
            guard let file = present.first(where: { $0.runtimeID == id })?.instructionsFile else { continue }
            let url = home.appending(path: file)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
                  DotAgents.isPlainFile(url) else { continue }
            attempt("move \(file) to \(folder)/\(router)") {
                try fileManager.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: url, to: shared)
                record.links.removeValue(forKey: file)
                DaemonLog.shared.write("personal layout: moved \(file) to \(folder)/\(router)")
            }
            return
        }
    }

    /// With no instructions anywhere, a short `~/.agents/AGENTS.md` that says what it is
    /// for, so the links have something to point at (US2 scenario 3).
    static func writeRouterIfMissing(home: URL) {
        let url = home.appending(path: "\(folder)/\(router)")
        guard !DotAgents.exists(url) else { return }
        attempt("write \(folder)/\(router)") {
            try routerContents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static let routerContents = """
        # Personal instructions

        How you like to work, written once for every agent the Agents app starts: each reads
        this file, on every runtime that has a place for personal instructions, in every project.
        A project's own AGENTS.md is read as well, and says more about that project.

        """

    // MARK: - Out of the way (US4)

    /// Links into `~/.agents/skills` that now point at nothing are removed, whoever made
    /// them, and no other link is (FR-008, R7). A record entry goes with its skill, so the
    /// same skill added again is linked again.
    static func sweep(home: URL, skillsFolder: String, record: inout Record) {
        sweep(home: home, folder: skillsFolder, sharedFolder: "\(folder)/\(skills)",
              present: Set(sharedSkills(home: home)), record: &record)
    }

    /// The same for any folder the app links into from a folder in `~/.agents`: a link in
    /// `folder` that resolves inside `sharedFolder` to nothing goes, and so does the record
    /// of a name no longer in `present`.
    static func sweep(home: URL, folder linkFolder: String, sharedFolder: String, present: Set<String>,
                      record: inout Record) {
        let fileManager = FileManager.default
        let folderURL = home.appending(path: linkFolder, directoryHint: .isDirectory)
        let shared = home.appending(path: sharedFolder).standardizedFileURL.path + "/"
        if (try? fileManager.destinationOfSymbolicLink(atPath: folderURL.path)) == nil {
            let entries = (try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? []
            for name in entries {
                let url = folderURL.appending(path: name)
                guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { continue }
                let resolved = (destination.hasPrefix("/") ? URL(filePath: destination)
                                : folderURL.appending(path: destination)).standardizedFileURL
                guard resolved.path.hasPrefix(shared), !fileManager.fileExists(atPath: resolved.path) else { continue }
                attempt("remove the dangling link \(linkFolder)/\(name)") {
                    try fileManager.removeItem(at: url)
                }
            }
        }
        for path in record.links.keys where path.hasPrefix(linkFolder + "/") {
            let name = String(path.dropFirst(linkFolder.count + 1))
            if !present.contains(name) { record.links.removeValue(forKey: path) }
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
