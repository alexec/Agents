import Foundation

/// A `set_tile` call read and checked (074 FR-006): the tile it asks for, or the one
/// sentence saying what is wrong. Nothing here knows who is calling; the keeper and the
/// project's limits are the daemon's to apply.
public struct TileCheck: Sendable, Equatable {
    public var id: String
    /// The tile as it would be written, with a placeholder keeper the daemon replaces.
    public var tile: TileFile
    public var takeOver: Bool

    /// Every refusal starts the same way, so an agent reads at once that nothing changed.
    public static let lead = "Nothing was set: "

    public static func read(_ arguments: JSONValue?) -> Result<TileCheck, TileProblem> {
        func text(_ key: String) -> String? {
            let value = arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func fail(_ words: String) -> Result<TileCheck, TileProblem> { .failure(TileProblem(lead + words)) }
        func tooLong(_ key: String, _ value: String?, _ limit: Int) -> Bool {
            (value?.count ?? 0) > limit
        }

        guard let id = text("id") else {
            return fail("give the tile an `id`, e.g. open_bugs.")
        }
        guard TileLimits.isValidID(id) else {
            return fail("`id` \"\(id)\" has to be 1 to 40 lowercase letters, digits, _ and -, and not start with _.")
        }
        guard let title = text("title") else { return fail("give the tile a `title`.") }
        if tooLong("title", title, TileLimits.titleLength) {
            return fail("`title` is over \(TileLimits.titleLength) characters.")
        }
        guard let rawType = text("type") else {
            return fail("say its `type`: number, status, table, note or link.")
        }
        guard let type = TileType(rawValue: rawType.lowercased()) else {
            return fail("`type` \"\(rawType)\" is not one of number, status, table, note or link.")
        }
        let section = text("section")
        if tooLong("section", section, TileLimits.sectionLength) {
            return fail("`section` is over \(TileLimits.sectionLength) characters.")
        }
        let source = text("source")
        if tooLong("source", source, TileLimits.sourceLength) {
            return fail("`source` is over \(TileLimits.sourceLength) characters.")
        }
        if source == nil, type == .number || type == .table {
            return fail("a \(type.rawValue) tile needs a `source`: one line saying where the value came from, e.g. \"gh issue list -l bug --state open\".")
        }
        var stale: Int?
        if let given = arguments?["stale_after_hours"], !given.isNull {
            guard let hours = given.intValue ?? given.stringValue.flatMap({ Int($0) }),
                  TileLimits.staleHours.contains(hours) else {
                return fail("`stale_after_hours` has to be a whole number from 1 to 168.")
            }
            stale = hours
        }
        var tile = TileFile(title: title, type: type, section: section, keeper: TileKeeper(),
                            source: source, staleAfterHours: stale)

        switch type {
        case .number:
            let raw = arguments?["value"]
            let value: Double? = switch raw {
            case .int(let v)?: Double(v)
            case .double(let v)?: v
            case .string(let s)?: Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
            default: nil
            }
            guard let value, value.isFinite else { return fail("a number tile needs a `value` that is a number.") }
            let unit = text("unit")
            if tooLong("unit", unit, TileLimits.unitLength) {
                return fail("`unit` is over \(TileLimits.unitLength) characters.")
            }
            var good: TileGood?
            if let raw = text("good") {
                guard let read = TileGood(rawValue: raw.lowercased()) else {
                    return fail("`good` has to be up or down.")
                }
                good = read
            }
            tile.number = TileNumber(value: value, unit: unit, good: good)

        case .status:
            guard let raw = text("level"), let level = TileLevel(rawValue: raw.lowercased()) else {
                return fail("a status tile needs a `level`: ok, warn, bad or unknown.")
            }
            guard let line = text("line") else { return fail("a status tile needs a `line` saying what it is.") }
            if tooLong("line", line, TileLimits.statusLineLength) {
                return fail("`line` is over \(TileLimits.statusLineLength) characters.")
            }
            let since = text("since")
            if tooLong("since", since, TileLimits.sinceLength) {
                return fail("`since` is over \(TileLimits.sinceLength) characters.")
            }
            tile.status = TileStatus(level: level, line: line, since: since)

        case .table:
            guard let columns = arguments?["columns"]?.arrayValue?.compactMap(\.stringValue), !columns.isEmpty else {
                return fail("a table tile needs `columns`: a list of 1 to \(TileLimits.tableColumns) headings.")
            }
            guard columns.count <= TileLimits.tableColumns else {
                return fail("a table has at most \(TileLimits.tableColumns) columns; this has \(columns.count).")
            }
            if columns.contains(where: { $0.count > TileLimits.cellLength }) {
                return fail("a column heading is over \(TileLimits.cellLength) characters.")
            }
            let rawRows = arguments?["rows"]?.arrayValue ?? []
            guard rawRows.count <= TileLimits.tableRows else {
                return fail("a table has at most \(TileLimits.tableRows) rows; this has \(rawRows.count).")
            }
            var rows: [[TileCell]] = []
            for (index, raw) in rawRows.enumerated() {
                guard let cells = raw.arrayValue, cells.count == columns.count else {
                    return fail("row \(index + 1) needs \(columns.count) cells, one per column.")
                }
                var row: [TileCell] = []
                for cell in cells {
                    let read: TileCell? = switch cell {
                    case .string(let s): TileCell(text: s)
                    case .int(let v): TileCell(text: String(v))
                    case .double(let v): TileCell(text: DashboardModel.numberWords(v))
                    case .object:
                        cell["text"]?.stringValue.map { TileCell(text: $0, url: cell["url"]?.stringValue) }
                    default: nil
                    }
                    guard let read else {
                        return fail("row \(index + 1) has a cell that is not text or {\"text\", \"url\"}.")
                    }
                    guard read.text.count <= TileLimits.cellLength, (read.url?.count ?? 0) <= TileLimits.cellLength else {
                        return fail("row \(index + 1) has a cell over \(TileLimits.cellLength) characters.")
                    }
                    row.append(read)
                }
                rows.append(row)
            }
            tile.table = TileTable(columns: columns, rows: rows)

        case .note:
            guard let markdown = arguments?["markdown"]?.stringValue, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return fail("a note tile needs `markdown`.")
            }
            guard markdown.utf8.count <= TileLimits.noteBytes else {
                return fail("a note is at most 4 KB of Markdown; this is \(markdown.utf8.count / 1024 + 1) KB.")
            }
            tile.note = TileNote(markdown: markdown)

        case .link:
            let link = TileLink(url: text("url"), session: text("session"), file: text("file"), workflow: text("workflow"))
            let given = [link.url, link.session, link.file, link.workflow].compactMap { $0 }
            guard given.count == 1 else {
                return fail("a link tile needs exactly one of `url`, `session`, `file` or `workflow`.")
            }
            if let url = link.url, URL(string: url)?.scheme.map({ ["http", "https"].contains($0.lowercased()) }) != true {
                return fail("`url` has to be an http or https address.")
            }
            if let session = link.session, UUID(uuidString: session) == nil {
                return fail("`session` has to be a session's id, as list_sessions gives it.")
            }
            if let file = link.file, file.hasPrefix("/") || file.split(separator: "/").contains("..") {
                return fail("`file` has to be a path inside the project, from its folder, e.g. docs/index.md.")
            }
            if given.first.map({ $0.count > TileLimits.sourceLength }) == true {
                return fail("the link is over \(TileLimits.sourceLength) characters.")
            }
            tile.link = link
        }

        let takeOver = arguments?["take_over"]?.boolValue ?? false
        return .success(TileCheck(id: id, tile: tile, takeOver: takeOver))
    }
}

/// What was wrong with a tile call, in the sentence the agent reads.
public struct TileProblem: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
