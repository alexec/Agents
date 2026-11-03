import Foundation

/// `docs/list`, `docs/search` and `docs/read` (#3319): a machine's docs, a folder's `*.md` files
/// and its docs connectors' pages, one model for both. The data behind Docs and a doc's page (#3321).
public extension DaemonAPI {
    /// One doc: its lineage ref (kind `doc`), its title, and where it comes from.
    struct Doc: Codable, Sendable, Hashable, Identifiable {
        public var ref: String
        /// Its first `#` heading, or its file name; a connector doc's title.
        public var title: String
        /// The `DocsSource` id it comes from: a folder's path, or `mcp:<server name>`.
        public var source: String
        /// A folder doc's folder, or the folder whose mcp.json reaches the connector.
        public var folder: String?
        /// A folder doc's path in its folder.
        public var path: String?
        /// A connector doc's address in its vendor's app.
        public var url: String?
        public var updated: Date?

        public var id: String { ref }

        public init(ref: String, title: String, source: String, folder: String? = nil, path: String? = nil,
                    url: String? = nil, updated: Date? = nil) {
            self.ref = ref
            self.title = title
            self.source = source
            self.folder = folder
            self.path = path
            self.url = url
            self.updated = updated
        }
    }

    /// Where docs come from: a folder, or a docs connector in a folder's Docs slot.
    struct DocsSource: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable { case folder, connector }
        public enum State: String, Codable, Sendable, Hashable { case read, notMapped, failed }

        /// The folder's path, or `mcp:<server name>`.
        public var id: String
        public var kind: Kind
        public var name: String
        public var folder: String?
        public var state: State
        public var message: String?

        public init(id: String, kind: Kind, name: String, folder: String? = nil, state: State = .read,
                    message: String? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.folder = folder
            self.state = state
            self.message = message
        }
    }

    struct DocsListRequest: Codable, Sendable, Hashable {
        public var folder: String?
        public var source: String?
        public var cursor: String?
        public var limit: Int?

        public init(folder: String? = nil, source: String? = nil, cursor: String? = nil, limit: Int? = nil) {
            self.folder = folder
            self.source = source
            self.cursor = cursor
            self.limit = limit
        }
    }

    /// A page of docs, the last updated first, and the sources it looked at.
    struct DocsList: Codable, Sendable, Hashable {
        public var docs: [Doc]
        public var sources: [DocsSource]
        public var cursor: String?

        public init(docs: [Doc] = [], sources: [DocsSource] = [], cursor: String? = nil) {
            self.docs = docs
            self.sources = sources
            self.cursor = cursor
        }
    }

    struct DocsSearchRequest: Codable, Sendable, Hashable {
        public var query: String
        public var sources: [String]?
        public var limit: Int?

        public init(query: String, sources: [String]? = nil, limit: Int? = nil) {
            self.query = query
            self.sources = sources
            self.limit = limit
        }
    }

    /// One place a search found: its line and the line cut short for a folder doc; a snippet only
    /// for a connector doc.
    struct DocsMatch: Codable, Sendable, Hashable {
        public var line: Int?
        public var snippet: String

        public init(line: Int? = nil, snippet: String) {
            self.line = line
            self.snippet = snippet
        }
    }

    struct DocsSearchResult: Codable, Sendable, Hashable {
        public var doc: Doc
        public var matches: [DocsMatch]

        public init(doc: Doc, matches: [DocsMatch] = []) {
            self.doc = doc
            self.matches = matches
        }
    }

    struct DocsSearch: Codable, Sendable, Hashable {
        public var results: [DocsSearchResult]
        public var sources: [DocsSource]

        public init(results: [DocsSearchResult] = [], sources: [DocsSource] = []) {
            self.results = results
            self.sources = sources
        }
    }

    struct DocsReadRequest: Codable, Sendable, Hashable {
        public var ref: String
        public var from: Int?
        public var to: Int?

        public init(ref: String, from: Int? = nil, to: Int? = nil) {
            self.ref = ref
            self.from = from
            self.to = to
        }
    }

    /// The doc's Markdown from line `from` to line `to`, and its total lines. `next` is the
    /// `from` of the next read when this one was cut short.
    struct DocsReading: Codable, Sendable, Hashable {
        public var doc: Doc
        public var text: String
        public var from: Int
        public var to: Int
        public var lines: Int
        public var next: Int?

        public init(doc: Doc, text: String, from: Int = 1, to: Int = 0, lines: Int = 0, next: Int? = nil) {
            self.doc = doc
            self.text = text
            self.from = from
            self.to = to
            self.lines = lines
            self.next = next
        }
    }
}

public extension DaemonAPI.Method {
    /// `DocsListRequest` → `DocsList`, `DocsSearchRequest` → `DocsSearch`,
    /// `DocsReadRequest` → `DocsReading` (#3319).
    static let docsList = "docs/list"
    static let docsSearch = "docs/search"
    static let docsRead = "docs/read"
}
