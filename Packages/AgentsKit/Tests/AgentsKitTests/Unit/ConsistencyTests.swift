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
    /// A control is not a state; the next one that earns a colour is written down
    /// here rather than hidden.
    private static let colourAllowList: [(file: String, contains: String, why: String)] = [
        (file: "Remote/Sources/Chat/EntryView.swift", contains: ".foregroundStyle(Color.accentColor)",
         why: "a button that opens a diff, drawn as the system draws controls (FR-006b)"),
    ]

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

    /// Every view in both apps, which is the point. 018 wrote this rule for eleven
    /// transcript entry renderers and it held there; the forty views around them went
    /// on choosing among eight semantic styles by hand until `.callout` was the app's
    /// body font and `.body` appeared nowhere. The list of files the rule applied to
    /// was the bug. There is no list now.
    ///
    /// `Shared/UI/TypeScale.swift` is where a step is resolved, so it is the one file
    /// allowed to name a font.
    private static let scaleDefinition = "Shared/UI/TypeScale.swift"

    private static let viewDirectories = ["App/Sources", "Remote/Sources", "Shared/UI"]

    /// A `.font(` line is allowed when it draws a Markdown heading — those need three
    /// levels where the scale has one above `reading`, so `TextStep.heading` keeps a
    /// ladder of its own and resolves it for both apps — or when it, or the line above
    /// it, says the glyph is decorative (FR-015).
    private static func fontIsAllowed(in source: Source, at index: Int) -> Bool {
        let line = source.lines[index]
        if line.contains("TextStep.heading(") { return true }
        let above = index > 0 ? source.lines[index - 1] : ""
        return line.localizedCaseInsensitiveContains("decorative")
            || above.localizedCaseInsensitiveContains("decorative")
    }

    @Test func noViewNamesAFontItself() throws {
        var violations: [String] = []
        var read = 0
        for source in try Self.sources(under: Self.viewDirectories) {
            guard source.path != Self.scaleDefinition else { continue }
            read += 1
            for (index, line) in source.lines.enumerated() {
                guard Self.code(line).contains(".font(") else { continue }
                guard !Self.fontIsAllowed(in: source, at: index) else { continue }
                violations.append("\(Self.at(source, index)): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(read > 50, "too few sources were read; the repository root is wrong")
        #expect(violations.isEmpty, """
            A view names a font. Everything in both apps draws from one scale: use \
            `.appText(.reading)` for anything read — a message, a row title, a form \
            label, body copy, the document page — `.appText(.supporting)` for what sits \
            under one of those and describes it, `.appText(.fine)` for timestamps, \
            counts, section headers and the chrome on small buttons, `.appText(.code)` \
            for anything monospaced, and `.appText(.title)` for a page's own title. A \
            weight goes on afterwards with `.fontWeight(_:)`; there is no heading step \
            because a heading is `reading` with a weight. A glyph that is not text may \
            keep a fixed size if the line above it says it is decorative.
            \(violations.joined(separator: "\n"))
            """)
    }

    @Test func noTextIsPinnedToAPointSize() throws {
        // FR-015: everything scales with the reader's text size. The fixed sizes left
        // are glyphs in capsules, wells and badges, and each says so on the line above.
        let pinned = try Regex(#"\.system\(size:"#)
        var violations: [String] = []
        for source in try Self.sources(under: Self.viewDirectories) {
            for (index, line) in source.lines.enumerated() {
                guard Self.code(line).contains(pinned) else { continue }
                guard !Self.fontIsAllowed(in: source, at: index) else { continue }
                violations.append("\(Self.at(source, index)): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(violations.isEmpty, """
            Text is pinned to a point size, which the reader's text-size setting cannot \
            move. Use a step of the scale. If it is a glyph in a capsule, a well or a \
            badge rather than text, say so on the line above: `// Decorative: …`.
            \(violations.joined(separator: "\n"))
            """)
    }

    /// The scale is four steps and a monospace one. It is worth a check of its own
    /// because the failure it guards is not a call site drifting — it is somebody
    /// adding a fifth step to avoid choosing between two that exist, which is how the
    /// app got to eight in the first place.
    @Test func theScaleStaysFourStepsAndCode() throws {
        let definition = try Self.sources(under: ["Shared/UI"])
            .first { $0.path == Self.scaleDefinition }
        // The enum's own cases, not the switch labels that resolve them: a `case` line
        // that is a bare name and nothing else.
        let declaration = try Regex(#"^case [a-z][A-Za-z]*$"#)
        let cases = try #require(definition).lines
            .map { Self.code($0).trimmingCharacters(in: .whitespaces) }
            .filter { try! declaration.wholeMatch(in: $0) != nil }
        #expect(cases.contains("case title"))
        #expect(cases.contains("case reading"))
        #expect(cases.contains("case supporting"))
        #expect(cases.contains("case fine"))
        #expect(cases.contains("case code"))
        #expect(cases.count == 5, """
            The scale has \(cases.count) steps rather than five. Five is the number \
            somebody asked for after reading the app with eight: title, reading, \
            supporting, fine, code. A sixth is a decision, not a refactor — if one is \
            genuinely needed, change this test deliberately and say why in TypeScale.
            \(cases.joined(separator: "\n"))
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

    // MARK: 4. The word for a starting agent (020 FR-023)

    /// Whether a line of code spells the word out instead of using the constant.
    ///
    /// Pulled out as a pure function so the check can be *proved to bite* by asserting
    /// it against a sample, rather than by editing a real source file and putting it
    /// back — a scan that matches nothing is a green test protecting nothing, but
    /// mutating the repository to demonstrate that is a trick that leaves the mutation
    /// behind the one time something interrupts the run.
    static func spellsOutStarting(_ line: String) -> Bool {
        code(line).contains("\"Starting\"")
    }

    /// The check above, against lines that must and must not trip it.
    @Test func theStartingWordScanCatchesWhatItIsFor() {
        #expect(Self.spellsOutStarting(#"case .starting: return "Starting""#))
        #expect(Self.spellsOutStarting(#"    Text("Starting")"#))
        // The constant itself is the fix, not a violation.
        #expect(!Self.spellsOutStarting("case .starting: return AgentState.startingLabel"))
        // A comment that names the word while explaining why not to write it.
        #expect(!Self.spellsOutStarting(#"// never write "Starting" here"#))
        // A longer word that merely contains it.
        #expect(!Self.spellsOutStarting(#"Text("Starting up…")"#))
    }

    /// 020 added one state and one word for it, and put the word in `AgentsKitCore`
    /// for the reason `EndedReason.summary` is there: the phone and the window have to
    /// say the same thing about the same agent.
    ///
    /// Only this one word. The other five are *not* identical across the two apps
    /// today — `AgentRow` says "Waiting for your answer" where its own accessibility
    /// label says "Waiting on you" — so there is no shared `AgentState.label` to point
    /// a wider check at. Unifying those is 018's argument, not 020's.
    @Test func noCallSiteSpellsOutTheWordForAStartingAgent() throws {
        var violations: [String] = []
        var scanned = 0
        for source in try Self.sources(under: ["App/Sources", "Remote/Sources", "Shared/UI"]) {
            scanned += 1
            for (index, line) in source.lines.enumerated() where Self.spellsOutStarting(line) {
                violations.append("\(Self.at(source, index)): \(Self.code(line).trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(scanned > 50, "too few sources were read; the repository root is wrong")
        #expect(violations.isEmpty, """
            A view spells out the word for a starting agent. Use \
            `AgentState.startingLabel`, so the row, the accessibility label, the \
            transcript line and the phone's card cannot drift apart.
            \(violations.joined(separator: "\n"))
            """)
    }
}
