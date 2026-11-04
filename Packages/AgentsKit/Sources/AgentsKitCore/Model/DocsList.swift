import Foundation

/// Where Docs is (#3321): the list, or a doc's page by its ref, at a line a search found.
public struct DocsPlace: Hashable, Sendable {
    public var ref: String?
    public var line: Int?

    public init(ref: String? = nil, line: Int? = nil) {
        self.ref = ref
        self.line = ref == nil ? nil : line
    }
}

/// Docs' list (#3321, spec 3319), as the web page's model/docs.ts: every machine's docs grouped by
/// source (each folder, then each docs connector), a folder's by its subfolders; search results
/// from every machine; and the words a row and a page say.
public enum DocsList {
    public enum Sort: String, CaseIterable, Hashable, Sendable {
        case updated, title

        public var title: String { self == .updated ? "Last updated" : "Title" }
    }

    /// One machine's `docs/list`, or why it could not be read.
    public struct HostDocs: Hashable, Sendable {
        public var host: MachineRef
        /// The machine's name, said beside a folder when there are several machines.
        public var name: String
        public var docs: [DaemonAPI.Doc]
        public var sources: [DaemonAPI.DocsSource]
        public var problem: String?

        public init(host: MachineRef, name: String, docs: [DaemonAPI.Doc] = [], sources: [DaemonAPI.DocsSource] = [],
                    problem: String? = nil) {
            self.host = host
            self.name = name
            self.docs = docs
            self.sources = sources
            self.problem = problem
        }
    }

    /// The project a folder is in (#3408), as the list names it: its id, and its name.
    public struct Project: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The project of a machine's folder, by the folder's path; nil for a folder in no project.
    public typealias ProjectOf = (MachineRef, String?) -> Project?

    /// A source as the list shows it: one per project, one per folder in no project on each machine,
    /// and one per connector of them all.
    public struct SourceRow: Hashable, Sendable, Identifiable {
        /// project:<id> for a project's folders; host|id for a folder in no project; the id alone for
        /// a connector, which is one source on every machine.
        public var key: String
        public var host: MachineRef
        public var source: DaemonAPI.DocsSource
        public var heading: String
        /// The project its folder is in: a connector's is the project of the folder whose mcp.json adds it.
        public var project: Project?
        /// Every folder in it, by machine: a project's folders on each machine, the first one's first.
        public var members: [Member] = []

        public struct Member: Hashable, Sendable {
            public var host: MachineRef
            public var id: String
        }

        public var id: String { key }
    }

    /// The docs of one subfolder of a source: "specs/", "docs/", or "" for its top.
    public struct Shelf: Hashable, Sendable, Identifiable {
        public var dir: String
        public var docs: [DaemonAPI.Doc]

        public var id: String { dir }
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public var row: SourceRow
        public var shelves: [Shelf]

        public var id: String { row.key }
    }

    /// A search result and the machine that found it.
    public struct Result: Hashable, Sendable, Identifiable {
        public var host: MachineRef
        public var result: DaemonAPI.DocsSearchResult

        public var id: String { result.doc.ref }
    }

    /// The key the list keeps a source by: one connector on two machines is one source, and so are a
    /// project's clones on two machines (#3408). The first is kept.
    public static func sourceKey(host: MachineRef, _ source: DaemonAPI.DocsSource, project: Project? = nil) -> String {
        if source.kind == .connector { return source.id }
        return project.map { "project:\($0.id)" } ?? "\(host.rawValue)|\(source.id)"
    }

    /// Every machine's sources, the folders first and then the connectors, each once. A project's
    /// folders are one source, said by the project's name with no machine, on every machine (#3408).
    public static func sources(_ lists: [HostDocs], projectOf: ProjectOf = { _, _ in nil }) -> [SourceRow] {
        let several = lists.count > 1
        var out: [SourceRow] = []
        for kind in [DaemonAPI.DocsSource.Kind.folder, .connector] {
            for list in lists {
                for source in list.sources where source.kind == kind {
                    let project = projectOf(list.host, source.folder ?? (kind == .folder ? source.id : nil))
                    let key = sourceKey(host: list.host, source, project: project)
                    let member = SourceRow.Member(host: list.host, id: source.id)
                    if let kept = out.firstIndex(where: { $0.key == key }) {
                        if kind == .folder { out[kept].members.append(member) }
                        continue
                    }
                    let heading = kind == .connector ? source.name
                        : project?.name ?? (several ? "\(source.name) (\(list.name))" : source.name)
                    out.append(SourceRow(key: key, host: list.host, source: source, heading: heading, project: project,
                                         members: [member]))
                }
            }
        }
        return out
    }

    /// The projects the sources are in, by name, for the Project filter.
    public static func projects(_ rows: [SourceRow]) -> [Project] {
        var seen = Set<String>()
        return rows.compactMap(\.project).filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The sources and their docs, sorted, with the one source asked for or all of them, in the one
    /// project asked for or in every one. A project's docs are those of all its folders, each ref
    /// once: a doc in two clones is the first clone's.
    public static func groups(_ lists: [HostDocs], sort: Sort, only: String = "", projectOf: ProjectOf = { _, _ in nil },
                              project: String = "") -> [Group] {
        sources(lists, projectOf: projectOf)
            .filter { (only.isEmpty || $0.key == only) && (project.isEmpty || $0.project?.id == project) }.map { row in
            var seen = Set<String>()
            let docs = row.members.flatMap { member in
                lists.filter { row.source.kind == .connector || $0.host == member.host }
                    .flatMap { $0.docs.filter { $0.source == member.id } }
            }
                .filter { seen.insert($0.ref).inserted }
            return Group(row: row, shelves: shelves(docs, sort: sort, byFolder: row.source.kind == .folder))
        }
    }

    /// A folder's docs by their first folder (specs/, docs/), those at its top last; a connector's in one.
    public static func shelves(_ docs: [DaemonAPI.Doc], sort: Sort, byFolder: Bool) -> [Shelf] {
        let by = Dictionary(grouping: docs) { byFolder ? dir(of: $0.path ?? "") : "" }
        return by.keys.sorted { a, b in a.isEmpty ? false : b.isEmpty ? true : a < b }
            .map { Shelf(dir: $0, docs: sorted(by[$0] ?? [], sort)) }
    }

    /// "specs/" for specs/3319-docs/spec.md; "" for README.md.
    public static func dir(of path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// The path under its shelf: 3319-docs/spec.md on the specs/ shelf.
    public static func underShelf(_ doc: DaemonAPI.Doc, _ dir: String) -> String {
        let name = shortForm(doc)
        return !dir.isEmpty && name.hasPrefix(dir) ? String(name.dropFirst(dir.count)) : name
    }

    public static func sorted(_ docs: [DaemonAPI.Doc], _ sort: Sort) -> [DaemonAPI.Doc] {
        docs.sorted { a, b in
            if sort == .updated, a.updated != b.updated {
                return (a.updated ?? .distantPast) > (b.updated ?? .distantPast)
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// What a row and a page title say: the path of a folder doc, the title of a connector doc.
    public static func shortForm(_ doc: DaemonAPI.Doc) -> String {
        doc.path.flatMap { $0.isEmpty ? nil : $0 } ?? doc.title
    }

    /// The title beside a folder doc's path, when it says more than the file name.
    public static func titleBeside(_ doc: DaemonAPI.Doc) -> String? {
        guard let path = doc.path, !path.isEmpty else { return nil }
        let file = path.split(separator: "/").last.map(String.init) ?? ""
        return !doc.title.isEmpty && doc.title != file ? doc.title : nil
    }

    public static func updatedWords(_ doc: DaemonAPI.Doc, now: Date = Date()) -> String {
        guard let updated = doc.updated else { return "" }
        let seconds = max(0, now.timeIntervalSince(updated))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d ago"
        case ..<(365 * 86_400): return "\(Int(seconds / (7 * 86_400)))w ago"
        default: return "\(Int(seconds / (365 * 86_400)))y ago"
        }
    }

    /// Whether a doc is a folder's own file, which its page follows as it changes.
    public static func isFolderDoc(_ doc: DaemonAPI.Doc) -> Bool {
        !(doc.path ?? "").isEmpty && !doc.source.hasPrefix("mcp:")
    }

    /// The vendor a connector doc opens in, by its ref's scheme; a mapped server by its name.
    public static func vendorName(_ ref: String) -> String {
        let scheme = ref.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        switch scheme {
        case "confluence": return "Confluence"
        case "notion": return "Notion"
        case "gdrive": return "Google Drive"
        case "mcp":
            let name = ref.dropFirst(4).split(separator: "/").first.map(String.init) ?? ""
            return name.isEmpty ? "its app" : name
        default: return "its app"
        }
    }

    /// What a source that did not answer says in place of its docs.
    public static func problem(_ source: DaemonAPI.DocsSource) -> String? {
        switch source.state {
        case .read: nil
        case .notMapped: "not mapped"
        case .failed: source.message.map { "could not be read: \($0)" } ?? "could not be read"
        }
    }

    /// The prompt Map it… starts a session with, in the folder whose Docs slot holds the connector.
    public static func mapItPrompt(_ source: DaemonAPI.DocsSource) -> String {
        "Map the docs server \(source.name) with the map-a-docs-server skill, so Docs can list and read it."
    }

    /// Every machine's search results, the most matches first, each doc once.
    public static func merged(_ lists: [(host: MachineRef, results: [DaemonAPI.DocsSearchResult])]) -> [Result] {
        var seen = Set<String>()
        var out: [Result] = []
        for list in lists {
            for result in list.results where seen.insert(result.doc.ref).inserted {
                out.append(Result(host: list.host, result: result))
            }
        }
        // A stable sort: the daemon's own order among docs with as many matches.
        return out.enumerated().sorted { a, b in
            a.element.result.matches.count != b.element.result.matches.count
                ? a.element.result.matches.count > b.element.result.matches.count : a.offset < b.offset
        }.map(\.element)
    }

    /// The results whose doc is in a source the list shows (#3408): a project not asked for is left out.
    public static func results(_ results: [Result], in rows: [SourceRow]) -> [Result] {
        results.filter { r in
            rows.contains { row in
                row.members.contains { $0.id == r.result.doc.source && (row.source.kind == .connector || $0.host == r.host) }
            }
        }
    }

    /// The source ids to search on a machine, for one source: its folders there, or the connector.
    public static func searchSources(_ row: SourceRow, on host: MachineRef) -> [String] {
        row.source.kind == .connector ? [row.source.id] : row.members.filter { $0.host == host }.map(\.id)
    }

    /// The Mac window's address of a doc (spec 3319).
    public static func windowAddress(_ ref: String) -> String { "agents://docs/\(ref)" }

    public static let noDocsHere = "No machine here reads docs yet. Docs come from a project’s Docs slot, in Project Settings ▸ Tools."
    public static let noDocs = "No docs. A folder’s Markdown files at its top and under specs/ and docs/ show here."
    public static let noResults = "No doc has those words."
}
