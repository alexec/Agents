import Foundation

/// The layout a project is given, once — when it is added, or for a project from before
/// this, when the first agent starts in it (`DaemonCore.layOutOnce`): the dotagents
/// convention (github.com/bgreenwell/dotagents), with `.agents` as the one real copy.
///
///     AGENTS.md                the router every agent reads first
///     .agents/skills/          task-specific Agent Skills
///     .agents/personas/        perspectives an agent can adopt
///     CLAUDE.md       -> AGENTS.md
///     .claude/skills  -> ../.agents/skills
///
/// Links only where a known agent needs one. Codex, Grok, Cursor and Copilot read
/// `AGENTS.md` and `.agents/skills` themselves — each one's shipped binary names both —
/// so Claude, which reads neither, is the only runtime that gets links.
///
/// Nothing the person wrote is lost or overwritten. A `CLAUDE.md` with no `AGENTS.md`
/// beside it is moved to `AGENTS.md` and linked back, so `.agents` is where it lives and
/// Claude still finds it; skills in a real `.claude/skills` are moved the same way. Where
/// both sides already hold something different, both are left exactly as they are,
/// because choosing between them is not ours to do. Every step is its own attempt, and a
/// step that fails is logged and carried past: a folder that could not be laid out is
/// still a project.
public enum DotAgents {
    public static let router = "AGENTS.md"
    public static let folder = ".agents"
    public static let resourceFolders = ["skills", "personas"]

    /// A link from a file a known agent reads to the file in `.agents` that holds it.
    struct Link {
        /// Relative to the project.
        var path: String
        /// Relative to the link's own folder, so the project can move and keep working.
        var destination: String
    }

    static let links = [
        Link(path: "CLAUDE.md", destination: "AGENTS.md"),
        Link(path: ".claude/skills", destination: "../.agents/skills"),
    ]

    /// What `apply` adds outside `.agents`, as `git status` names it before it is committed.
    public static var untrackedLayout: [String] { [router] + links.map(\.path) }

    public static func apply(to project: URL) {
        let fileManager = FileManager.default
        // The home folder's `.claude` is Claude's own, for every project: its skills
        // are not this folder's to move, and nothing above it is a project either.
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let path = project.standardizedFileURL.resolvingSymlinksInPath().path
        guard path != "/", !(home + "/").hasPrefix(path.hasSuffix("/") ? path : path + "/") else {
            return
        }
        for name in resourceFolders {
            attempt("create \(folder)/\(name)") {
                try fileManager.createDirectory(
                    at: project.appending(path: "\(folder)/\(name)", directoryHint: .isDirectory),
                    withIntermediateDirectories: true)
            }
        }
        let routerURL = project.appending(path: router)
        let claudeFile = project.appending(path: "CLAUDE.md")
        if !exists(routerURL) {
            attempt("write \(router)") {
                if isPlainFile(claudeFile) {
                    try fileManager.moveItem(at: claudeFile, to: routerURL)
                } else {
                    try routerContents(for: project).write(to: routerURL, atomically: true, encoding: .utf8)
                }
            }
        }
        for link in links {
            attempt("link \(link.path)") { try place(link, in: project) }
        }
    }

    /// The link, or nothing when something the person made is in the way.
    static func place(_ link: Link, in project: URL) throws {
        let fileManager = FileManager.default
        let url = project.appending(path: link.path)
        let target = url.deletingLastPathComponent().appending(path: link.destination)
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil { return }
        if isDirectory(url) {
            guard isDirectory(target) else { return }
            // A real folder of skills: move each one across, then link, but only when
            // every name is free on the other side.
            let entries = try fileManager.contentsOfDirectory(atPath: url.path)
            let clash = entries.contains { exists(target.appending(path: $0)) }
            guard !clash else { return }
            for entry in entries {
                try fileManager.moveItem(at: url.appending(path: entry), to: target.appending(path: entry))
            }
            try fileManager.removeItem(at: url)
        } else if exists(url) {
            return
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: link.destination)
    }

    /// A router that points at what the project already has, and at nothing it lacks.
    static func routerContents(for project: URL) -> String {
        var routes: [String] = []
        let shared = [
            ("README.md", "For the project's purpose and setup:", "READ"),
            ("CONTRIBUTING.md", "Before changing code or documentation:", "READ"),
            ("docs", "For architecture, terminology and decisions:", "CONSULT"),
        ]
        for (path, when, verb) in shared where exists(project.appending(path: path)) {
            routes.append("- **\(when)** \(verb) `\(path)\(isDirectory(project.appending(path: path)) ? "/" : "")`.")
        }
        routes.append("- **For a task a skill covers:** USE the skill in `.agents/skills/`.")
        routes.append("- **When a task calls for a specialist perspective:** ADOPT a persona from `.agents/personas/`.")
        return """
            # AGENTS.md

            ## Context routing

            \(routes.joined(separator: "\n"))

            """
    }

    private static func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { DaemonLog.shared.write("dotagents: could not \(what): \(error)") }
    }

    /// Whether anything is at the path, a dangling link included.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func isPlainFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }
}
