import Foundation
import Testing

/// The three rules 018 wrote down, as checks that fail when somebody writes a literal
/// instead of using the shared definition.
///
/// Source scans, because neither app has a test target: `App/Sources`, `Remote/Sources`
/// and `Shared/UI` are read from disk the way `MarkdownBlockTests` reads the specs.
/// Each was proved to bite by putting a literal back and watching it fail (quickstart
/// section 2); a regex that matches nothing is a green test that protects nothing.
@Suite("The layout agrees with itself")
struct ConsistencyTests {
    // MARK: Where the sources are

    /// The repository root, found from this file rather than from the working
    /// directory, so the check runs the same under `swift test` and under Xcode.
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private struct Source {
        let path: String   // relative to the repository root
        let lines: [String]
    }

    /// Every Swift file under the given top-level directories.
    private static func sources(under directories: [String]) throws -> [Source] {
        var found: [Source] = []
        for directory in directories {
            let base = root.appending(path: directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            while let url = walker.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let relative = String(url.path.dropFirst(root.path.count + 1))
                found.append(Source(path: relative, lines: text.components(separatedBy: "\n")))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The line with any trailing `//` comment cut off, so a comment that names a
    /// colour or a font while explaining why not to use one is not a violation.
    private static func code(_ line: String) -> Substring {
        if let range = line.range(of: "//") { return line[..<range.lowerBound] }
        return line[...]
    }

    /// `file:line: what` — enough to click on in Xcode and to find with a grep.
    private static func at(_ source: Source, _ index: Int) -> String {
        "\(source.path):\(index + 1)"
    }

    // MARK: 1. Colour (FR-024)

    /// Sites allowed to name a colour outside `StateTint`, each with its reason.
    ///
    /// The spec's FR-006b reserved a place here for an accent-coloured button that
    /// opens a diff on the phone, a control rather than a state. No such site exists
    /// in the source, so the list is empty; the mechanism stays so the next control
    /// that earns a colour has somewhere to be written down rather than hidden.
    private static let colourAllowList: [(file: String, contains: String, why: String)] = []

    @Test func noCallSiteNamesAStateColourItself() throws {
        // `.red`, `.orange`, `.green` and the accent are the four things a call site
        // reached for before 018, and `StateTint` is now the only place that may.
        let literal = try Regex(#"\.(red|orange|green|accentColor)\b"#)
        var violations: [String] = []
        var scanned = 0
        for source in try Self.sources(under: ["App/Sources", "Remote/Sources", "Shared/UI"]) {
            guard source.path != "Shared/UI/StateTint.swift" else { continue }
            scanned += 1
            for (index, line) in source.lines.enumerated() {
                let code = Self.code(line)
                guard code.contains(literal) else { continue }
                if Self.colourAllowList.contains(where: { source.path.hasSuffix($0.file) && code.contains($0.contains) }) {
                    continue
                }
                violations.append("\(Self.at(source, index)): \(code.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(scanned > 50, "too few sources were read; the repository root is wrong")
        #expect(violations.isEmpty, """
            A colour is named at a call site. Colour means one of three things here, and \
            `StateTint` is the only place that says which colour each is. Use \
            `.tinted(.attention)`, `.tinted(.failure)` or `.tinted(.vouched)`, or \
            `(condition ? StateTint.failure : .none).style(or: .secondary)` where the site \
            picks between a tint and its own grey. A control that genuinely needs a colour \
            goes on the allow-list in ConsistencyTests with its reason.
            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: 2. Type scale (FR-025)

    /// The transcript entry renderers. The prompt bar, the readers and the capsule
    /// chrome are not entries and keep their own sizes.
    private static let entryRenderers = [
        "App/Sources/Chat/Transcript.swift",
        "App/Sources/Chat/BlocksView.swift",
        "App/Sources/Chat/MarkdownText.swift",
        "App/Sources/Chat/PlanView.swift",
        "App/Sources/Chat/DiffView.swift",
        "App/Sources/Chat/CommandList.swift",
        "App/Sources/Chat/AttachmentStrip.swift",
        "Remote/Sources/Chat/EntryView.swift",
        "Remote/Sources/Chat/BlocksView.swift",
        "Remote/Sources/Chat/MarkdownText.swift",
    ]

    /// A `.font(` line is allowed when it is a markdown heading — those keep their own
    /// relative sizes and are not a step — or when it, or the line above it, says the
    /// glyph is decorative (FR-015).
    private static func fontIsAllowed(in source: Source, at index: Int) -> Bool {
        let line = source.lines[index]
        if source.path.hasSuffix("MarkdownText.swift"), line.contains(".font(level") { return true }
        let above = index > 0 ? source.lines[index - 1] : ""
        return line.localizedCaseInsensitiveContains("decorative")
            || above.localizedCaseInsensitiveContains("decorative")
    }

    @Test func noTranscriptEntryNamesAFontItself() throws {
        var violations: [String] = []
        var read = 0
        for source in try Self.sources(under: ["App/Sources/Chat", "Remote/Sources/Chat"]) {
            guard Self.entryRenderers.contains(source.path) else { continue }
            read += 1
            for (index, line) in source.lines.enumerated() {
                guard Self.code(line).contains(".font(") else { continue }
                guard !Self.fontIsAllowed(in: source, at: index) else { continue }
                violations.append("\(Self.at(source, index)): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(read == Self.entryRenderers.count, "an entry renderer has moved; update the list")
        #expect(violations.isEmpty, """
            A transcript entry names a font. Entries draw from the chat scale: use \
            `.chatText(.prose)` for a message, `.chatText(.supporting)` for a thought, \
            a tool title or a placeholder, `.chatText(.fine)` for a timestamp or label, \
            and `.chatText(.code)` for anything monospaced. A weight goes on afterwards \
            with `.fontWeight(_:)`. A glyph that is not text may keep a fixed size if the \
            line above it says it is decorative.
            \(violations.joined(separator: "\n"))
            """)
    }

    @Test func noChatTextIsPinnedToAPointSize() throws {
        // FR-015: everything in the chat scales with the reader's text size. The
        // fixed sizes left are glyphs in capsules and badges, and each says so.
        let pinned = try Regex(#"\.system\(size:"#)
        var violations: [String] = []
        for source in try Self.sources(under: ["App/Sources/Chat", "Remote/Sources/Chat"]) {
            for (index, line) in source.lines.enumerated() {
                guard Self.code(line).contains(pinned) else { continue }
                guard !Self.fontIsAllowed(in: source, at: index) else { continue }
                violations.append("\(Self.at(source, index)): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(violations.isEmpty, """
            Chat text is pinned to a point size, which the reader's text-size setting \
            cannot move. Use a step of the chat scale. If it is a glyph in a capsule or \
            a badge rather than text, say so on the line above: `// Decorative: …`.
            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: 3. Measure (FR-026)

    /// Everything that draws in the chat column. All of it takes its edges from
    /// `chatColumn()` and none of it applies a horizontal margin of its own.
    private static let columnSurfaces = [
        "App/Sources/Chat/Transcript.swift",
        "App/Sources/Chat/PromptBar.swift",
        "App/Sources/Permission/PermissionView.swift",
        "App/Sources/Elicitation/ElicitationView.swift",
        "App/Sources/Projects/ProjectAgentsView.swift",
    ]

    /// A gutter is tens of points; the inset of a capsule or a card inside the bar is
    /// a dozen. Anything this size or larger, applied horizontally in a column
    /// surface, is a margin standing in for the measure.
    private static let marginSize = 20

    @Test func noChatSurfaceKeepsAGutterOfItsOwn() throws {
        // A numeric literal at or above the margin size, or anything that is not a
        // literal at all — `Self.gutter` was how the project page kept its own copy.
        let padding = /\.padding\(\.horizontal,\s*([^)]+)\)/
        var violations: [String] = []
        var read = 0
        for source in try Self.sources(under: ["App/Sources"]) {
            guard Self.columnSurfaces.contains(source.path) else { continue }
            read += 1
            for (index, line) in source.lines.enumerated() {
                for match in Self.code(line).matches(of: padding) {
                    let argument = match.output.1.trimmingCharacters(in: .whitespaces)
                    if let value = Int(argument), value < Self.marginSize { continue }
                    violations.append("\(Self.at(source, index)): .padding(.horizontal, \(argument))")
                }
            }
        }
        #expect(read == Self.columnSurfaces.count, "a column surface has moved; update the list")
        #expect(violations.isEmpty, """
            A chat surface sets its own horizontal margin. The column's width and margin \
            come from `ChatMetrics`, applied by `.chatColumn()`; use that instead, so the \
            transcript, the prompt bar and the cards above it keep one pair of edges. \
            A capsule's own inset stays under \(Self.marginSize) points.
            \(violations.joined(separator: "\n"))
            """)
    }
}
