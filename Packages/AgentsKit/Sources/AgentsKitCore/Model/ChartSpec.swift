import Foundation

/// How to draw a CSV file as a chart (#836): what `show_file` takes beside its path.
///
/// A CSV says what the numbers are and not what they mean, so the agent names the two
/// columns and the mark. The same four words as a Vega-Lite spec's, so an agent that
/// knows one knows the other.
public struct ChartHint: Codable, Hashable, Sendable {
    public var mark: ChartMark
    /// The column along the bottom.
    public var x: String
    /// The column of numbers.
    public var y: String
    /// A column that splits the rows into series, each its own colour.
    public var color: String?
    public var title: String?

    public init(mark: ChartMark, x: String, y: String, color: String? = nil, title: String? = nil) {
        self.mark = mark
        self.x = x
        self.y = y
        self.color = color
        self.title = title
    }

    /// What an agent sent, or nothing. A hint without both columns is no hint.
    public init?(wire: JSONValue?) {
        guard let wire, case .object = wire else { return nil }
        let x = wire["x"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let y = wire["y"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !x.isEmpty, !y.isEmpty else { return nil }
        let color = wire["color"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        self.init(mark: ChartMark(rawValue: wire["mark"]?.stringValue?.lowercased() ?? "") ?? .bar,
                  x: x, y: y, color: color?.isEmpty == false ? color : nil,
                  title: wire["title"]?.stringValue)
    }
}

/// The marks drawn natively: Vega-Lite's commonest four.
public enum ChartMark: String, Codable, Hashable, Sendable, CaseIterable {
    case bar, line, point, area

    /// Said on the card: "Bar chart".
    public var words: String {
        switch self {
        case .bar: return "Bar chart"
        case .line: return "Line chart"
        case .point: return "Scatter chart"
        case .area: return "Area chart"
        }
    }
}

/// A chart the clients draw, from a Vega-Lite spec or a CSV with a hint (#836).
///
/// Only a subset of Vega-Lite: one mark, x, y and colour, the data inline or in a CSV
/// beside the spec. Drawn natively — Swift Charts on the Mac and the Remote, an SVG on
/// the web — so nothing runs and it follows the theme. A spec outside the subset is a
/// `ChartProblem`, and its source is shown with the reason.
public struct ChartSpec: Hashable, Sendable {
    public enum Axis: String, Hashable, Sendable {
        /// Names: one bar each, in the order they came.
        case nominal
        /// Numbers, on a scale.
        case quantitative
        /// Dates, on a time scale.
        case temporal
    }

    public enum XValue: Hashable, Sendable {
        case name(String)
        case number(Double)
        case date(Date)
    }

    public struct Point: Hashable, Sendable {
        public var x: XValue
        public var y: Double
        public var series: String?
    }

    public var mark: ChartMark
    public var title: String?
    public var xField: String
    public var yField: String
    public var colorField: String?
    public var xAxis: Axis
    public var points: [Point]

    /// Past this many points a chart is a smear; the rest are left out and said to be.
    public static let pointLimit = 5_000
    public var isCut = false

    /// Whether a file is a Vega-Lite spec by its name: `x.vl.json` or `x.vega-lite.json`.
    public static func isVegaLite(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".vl.json") || name.hasSuffix(".vega-lite.json") || name.hasSuffix(".vl")
    }

    public static func isCSV(_ url: URL) -> Bool {
        ["csv", "tsv"].contains(url.pathExtension.lowercased())
    }

    /// Whether a file can be drawn as a chart: a spec, or a CSV the agent said how to draw.
    public static func isChart(_ url: URL, hint: ChartHint?) -> Bool {
        isVegaLite(url) || (hint != nil && isCSV(url))
    }

    /// The file a spec's `data.url` names, as written, for a client to read first.
    public static func dataURL(in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let spec = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return spec["data"]?["url"]?.stringValue
    }

    /// Where a `data.url` points, beside the spec. Only a relative path: a web address
    /// is not fetched, as the page never fetches one either.
    public static func neighbourURL(_ name: String, of spec: URL) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("://") else { return nil }
        return URL(filePath: name, relativeTo: spec.deletingLastPathComponent()).standardizedFileURL
    }

    /// A Vega-Lite spec. `neighbour` reads a file a `data.url` names, relative to the
    /// spec's own folder; nil when it cannot be read.
    public static func vegaLite(_ text: String, neighbour: (String) -> String? = { _ in nil }) -> Result<ChartSpec, ChartProblem> {
        guard let data = text.data(using: .utf8),
              let spec = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let top) = spec else {
            return .failure(.notJSON)
        }
        for key in ["layer", "hconcat", "vconcat", "concat", "facet", "repeat", "transform"] where top[key] != nil {
            return .failure(.unsupported(key))
        }
        let markName = spec["mark"]?.stringValue ?? spec["mark"]?["type"]?.stringValue ?? ""
        guard let mark = ChartMark(rawValue: markName.lowercased()) else {
            return .failure(.unsupported(markName.isEmpty ? "a spec with no mark" : "the \(markName) mark"))
        }
        guard let x = spec["encoding"]?["x"]?["field"]?.stringValue,
              let y = spec["encoding"]?["y"]?["field"]?.stringValue else {
            return .failure(.missingEncoding)
        }
        let color = spec["encoding"]?["color"]?["field"]?.stringValue
        let title = spec["title"]?.stringValue ?? spec["title"]?["text"]?.stringValue

        var rows: [[String: String]] = []
        if case .array(let values)? = spec["data"]?["values"] {
            rows = values.compactMap { value in
                guard case .object(let fields) = value else { return nil }
                return fields.compactMapValues(\.chartText)
            }
        } else if let url = spec["data"]?["url"]?.stringValue {
            guard let body = neighbour(url) else { return .failure(.dataUnreadable(url)) }
            if url.lowercased().hasSuffix(".json"),
               let data = body.data(using: .utf8),
               case .array(let values)? = try? JSONDecoder().decode(JSONValue.self, from: data) {
                rows = values.compactMap { value in
                    guard case .object(let fields) = value else { return nil }
                    return fields.compactMapValues(\.chartText)
                }
            } else {
                rows = CSV.rows(body, separator: url.lowercased().hasSuffix(".tsv") ? "\t" : ",")
            }
        } else {
            return .failure(.noData)
        }
        let declared = spec["encoding"]?["x"]?["type"]?.stringValue.flatMap(Axis.init(rawValue:))
        return make(mark: mark, title: title, x: x, y: y, color: color, axis: declared, rows: rows)
    }

    /// A CSV, drawn as its hint says.
    public static func csv(_ text: String, hint: ChartHint, tabs: Bool = false) -> Result<ChartSpec, ChartProblem> {
        make(mark: hint.mark, title: hint.title, x: hint.x, y: hint.y, color: hint.color, axis: nil,
             rows: CSV.rows(text, separator: tabs ? "\t" : ","))
    }

    /// Either, by the file's name.
    public static func read(_ text: String, url: URL, hint: ChartHint?,
                            neighbour: (String) -> String? = { _ in nil }) -> Result<ChartSpec, ChartProblem> {
        if isVegaLite(url) { return vegaLite(text, neighbour: neighbour) }
        if let hint { return csv(text, hint: hint, tabs: url.pathExtension.lowercased() == "tsv") }
        return .failure(.noData)
    }

    static func make(mark: ChartMark, title: String?, x: String, y: String, color: String?,
                     axis declared: Axis?, rows: [[String: String]]) -> Result<ChartSpec, ChartProblem> {
        guard !rows.isEmpty else { return .failure(.noData) }
        guard rows.contains(where: { $0[x] != nil }) else { return .failure(.noColumn(x)) }
        guard rows.contains(where: { $0[y] != nil }) else { return .failure(.noColumn(y)) }
        let xs = rows.compactMap { $0[x] }
        let axis = declared ?? infer(xs)
        var points: [Point] = []
        for row in rows {
            guard let rawX = row[x], let rawY = row[y],
                  let value = Double(rawY.trimmingCharacters(in: .whitespaces)), value.isFinite,
                  let xValue = parse(rawX, as: axis) else { continue }
            points.append(Point(x: xValue, y: value, series: color.flatMap { row[$0] }))
        }
        guard !points.isEmpty else { return .failure(.noNumbers(y)) }
        let isCut = points.count > pointLimit
        var spec = ChartSpec(mark: mark, title: title, xField: x, yField: y, colorField: color,
                             xAxis: axis, points: Array(points.prefix(pointLimit)))
        spec.isCut = isCut
        return .success(spec)
    }

    static func infer(_ values: [String]) -> Axis {
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return .nominal }
        if trimmed.allSatisfy({ Double($0) != nil }) { return .quantitative }
        if trimmed.allSatisfy({ date($0) != nil }) { return .temporal }
        return .nominal
    }

    static func parse(_ raw: String, as axis: Axis) -> XValue? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        switch axis {
        case .nominal: return .name(text)
        case .quantitative: return Double(text).map(XValue.number)
        case .temporal: return date(text).map(XValue.date)
        }
    }

    /// An ISO 8601 date, with or without its time: what agents write.
    static func date(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        if text.count == 10, let date = day.date(from: text) { return date }
        let minutes = ISO8601DateFormatter()
        minutes.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return minutes.date(from: text)
    }

    /// The series, in the order they first came: the legend's order.
    public var series: [String] {
        var seen: [String] = []
        for point in points { if let name = point.series, !seen.contains(name) { seen.append(name) } }
        return seen
    }

    /// "Bar chart · 12 rows", for the card and the pane.
    public var summary: String {
        "\(mark.words) · \(points.count == 1 ? "1 row" : "\(points.count) rows")\(isCut ? " (first \(Self.pointLimit))" : "")"
    }
}

/// Why a chart was not drawn, said above its source.
public enum ChartProblem: Error, Hashable, Sendable {
    case notJSON
    case unsupported(String)
    case missingEncoding
    case noData
    case dataUnreadable(String)
    case noColumn(String)
    case noNumbers(String)

    public var words: String {
        switch self {
        case .notJSON: return "This is not a Vega-Lite spec: it does not read as a JSON object."
        case .unsupported(let what): return "This chart uses \(what), which the app does not draw. Its source is below."
        case .missingEncoding: return "The spec does not name an x and a y field."
        case .noData: return "There is no data to draw."
        case .dataUnreadable(let url): return "The data at \(url) could not be read."
        case .noColumn(let name): return "There is no column called \(name)."
        case .noNumbers(let name): return "The \(name) column has no numbers in it."
        }
    }
}

extension JSONValue {
    /// A field of a data row as the chart reads it: a string or a number, as text.
    var chartText: String? {
        switch self {
        case .string(let text): return text
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }
}

/// Just enough CSV: a header row, quoted fields with doubled quotes, CRLF or LF.
public enum CSV {
    public static func rows(_ text: String, separator: Character = ",") -> [[String: String]] {
        let table = parse(text, separator: separator)
        guard let header = table.first else { return [] }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces) }
        return table.dropFirst().compactMap { fields in
            guard !(fields.count == 1 && fields[0].isEmpty) else { return nil }
            var row: [String: String] = [:]
            for (index, name) in names.enumerated() where index < fields.count { row[name] = fields[index] }
            return row
        }
    }

    public static func parse(_ text: String, separator: Character = ",") -> [[String]] {
        var table: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let char = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty: quoted = true
            case separator: row.append(field); field = ""
            case "\n", "\r\n", "\r":
                row.append(field); field = ""
                table.append(row); row = []
            default: field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); table.append(row) }
        return table
    }
}
