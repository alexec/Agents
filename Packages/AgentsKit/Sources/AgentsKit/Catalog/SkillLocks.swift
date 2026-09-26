import Foundation

/// The `skills` CLI's two lock files, read and written in the CLI's own shape (059, research
/// R5, contracts/lock-files.md), so each tool sees what the other added.
///
/// A skill a lock names is one a tool put there, and the app may update and remove it. A
/// folder no lock names is the person's own, and the app never touches it.
///
/// The app adds no key of its own to either file: the CLI rebuilds an entry whole when it
/// writes one, so anything extra would be lost, and the CLI's file is not the app's to
/// extend. What the lock has no room for goes in the app's own sidecar (`CatalogSidecar`).
struct SkillLock {
    enum Kind: Sendable { case personal, project }

    /// One entry, the fields the CLI writes for a GitHub skill.
    struct Entry: Equatable, Sendable {
        var source: String
        var sourceType: String
        var sourceURL: String?
        var skillPath: String?
        /// Personal: the folder's git tree SHA.
        var skillFolderHash: String?
        /// Project: the CLI's SHA-256 of the folder.
        var computedHash: String?
        var installedAt: String?
        var updatedAt: String?

        /// The recorded hash, whichever kind of lock it came from.
        var recordedHash: String? { skillFolderHash ?? computedHash }
    }

    let kind: Kind
    let url: URL
    private(set) var root: OrderedJSON

    static let personalVersion = 3
    static let projectVersion = 1

    /// Where the personal lock is: `$XDG_STATE_HOME/skills/.skill-lock.json` when that is
    /// set, as the CLI does, otherwise `<home>/.agents/.skill-lock.json`.
    static func personalURL(home: URL, environment: [String: String]) -> URL {
        if let state = environment["XDG_STATE_HOME"], !state.isEmpty {
            return URL(filePath: state).appending(path: "skills/.skill-lock.json")
        }
        return home.appending(path: ".agents/.skill-lock.json")
    }

    static func projectURL(folder: URL) -> URL { folder.appending(path: "skills-lock.json") }

    /// Read a lock, or start an empty one if there is no file.
    ///
    /// A file that cannot be read, or is of an older version, throws `lockUnreadable`: the
    /// CLI would treat it as empty and write over it, and the app will not.
    static func load(_ kind: Kind, at url: URL) throws -> SkillLock {
        guard let data = try? Data(contentsOf: url) else {
            return SkillLock(kind: kind, url: url, root: empty(kind))
        }
        let want = kind == .personal ? personalVersion : projectVersion
        guard let root = try? OrderedJSON.parse(data), let version = root["version"]?.intValue, version >= want,
              root["skills"]?.objectPairs != nil else {
            throw DaemonAPI.CatalogError.lockUnreadable(path: url.path)
        }
        return SkillLock(kind: kind, url: url, root: root)
    }

    private static func empty(_ kind: Kind) -> OrderedJSON {
        switch kind {
        case .personal:
            .object([("version", .number(String(personalVersion))), ("skills", .object([])), ("dismissed", .object([]))])
        case .project:
            .object([("version", .number(String(projectVersion))), ("skills", .object([]))])
        }
    }

    var names: [String] { root["skills"]?.objectPairs?.map(\.0) ?? [] }

    func entry(_ name: String) -> Entry? {
        guard let e = root["skills"]?[name], e.objectPairs != nil, let source = e["source"]?.stringValue else { return nil }
        return Entry(source: source, sourceType: e["sourceType"]?.stringValue ?? "",
                     sourceURL: e["sourceUrl"]?.stringValue, skillPath: e["skillPath"]?.stringValue,
                     skillFolderHash: e["skillFolderHash"]?.stringValue, computedHash: e["computedHash"]?.stringValue,
                     installedAt: e["installedAt"]?.stringValue, updatedAt: e["updatedAt"]?.stringValue)
    }

    var entries: [String: Entry] {
        var out: [String: Entry] = [:]
        for name in names { if let e = entry(name) { out[name] = e } }
        return out
    }

    /// Add or replace a GitHub skill's entry, as the CLI's `addSkillToLock` /
    /// `addSkillToLocalLock` would write it. A personal entry keeps its first `installedAt`.
    mutating func upsert(name: String, source: String, skillPath: String, hash: String, now: Date = Date()) {
        var skills = root["skills"] ?? .object([])
        switch kind {
        case .personal:
            let stamp = Self.stamp(now)
            let installed = entry(name)?.installedAt ?? stamp
            skills.set(name, .object([
                ("source", .string(source)),
                ("sourceType", .string("github")),
                ("sourceUrl", .string("https://github.com/\(source).git")),
                ("skillPath", .string(skillPath)),
                ("skillFolderHash", .string(hash)),
                ("installedAt", .string(installed)),
                ("updatedAt", .string(stamp)),
            ]))
        case .project:
            skills.set(name, .object([
                ("source", .string(source)),
                ("sourceType", .string("github")),
                ("skillPath", .string(skillPath)),
                ("computedHash", .string(hash)),
            ]))
        }
        root.set("skills", skills)
    }

    mutating func remove(name: String) {
        guard var skills = root["skills"] else { return }
        skills.remove(name)
        root.set("skills", skills)
    }

    /// The file as the CLI writes it: personal as `JSON.stringify(lock, null, 2)` with no
    /// newline; project with only `version` and `skills`, skills sorted by name, and a
    /// newline at the end.
    func text() -> String {
        switch kind {
        case .personal:
            return root.stringified()
        case .project:
            let skills = (root["skills"]?.objectPairs ?? []).sorted { $0.0 < $1.0 }
            let out: OrderedJSON = .object([("version", root["version"] ?? .number("1")), ("skills", .object(skills))])
            return out.stringified() + "\n"
        }
    }

    /// Written whole, to a file beside it and renamed, so a reader never sees half of one.
    func write() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text().utf8).write(to: url, options: .atomic)
    }

    /// `new Date().toISOString()`: milliseconds, UTC, `Z`.
    static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }
}

/// What the lock files have no field for (059, research R5): the commit a skill was taken
/// at, its date, the folder's tree SHA and the catalogue. In the daemon's root, so a scratch
/// root has its own. Losing it costs a "Taken at" line and one API call, nothing more.
struct CatalogSidecar: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var commit: String
        var committedAt: Date?
        var treeSHA: String
        var catalogue: String
        var addedAt: Date
    }

    var version = 1
    var skills: [String: Record] = [:]

    static func key(_ destination: DaemonAPI.SkillDestination, name: String) -> String {
        switch destination {
        case .personal: "personal/\(name)"
        case .project(let folder): "\(URL(filePath: folder).standardizedFileURL.path)/\(name)"
        }
    }

    static func load(from url: URL) -> CatalogSidecar {
        guard let data = try? Data(contentsOf: url) else { return CatalogSidecar() }
        return (try? Self.decoder.decode(CatalogSidecar.self, from: data)) ?? CatalogSidecar()
    }

    /// Written with anything whose lock entry has gone left out: `stillManaged` answers for
    /// each key whether a lock still names it.
    func save(to url: URL, keeping stillManaged: (String) -> Bool) throws {
        var kept = self
        kept.skills = skills.filter { stillManaged($0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(kept).write(to: url, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
