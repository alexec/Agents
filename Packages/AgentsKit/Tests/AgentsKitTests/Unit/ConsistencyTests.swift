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
        (file: "Shared/UI/Chat/TranscriptRows.swift", contains: "foregroundStyle(Color.accentColor)",
         why: "a file a tool call touched, drawn on a phone as the system draws a link (FR-006b, 033)"),
        (file: "Shared/UI/Page/CursorFlag.swift", contains: "Color(nsColor: .controlAccentColor)",
         why: "the person's caret flag on a live page, in the colour the system draws their own insertion point"),
        (file: "Shared/UI/Page/CursorFlag.swift", contains: "color: .accentColor",
         why: "the same flag on a phone, where the accent is the colour of the person's own insertion point (034)"),
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
        // The phone's, in the same column since 033.
        "Shared/UI/Chat/ChatTranscript.swift",
        "Remote/Sources/Chat/PromptBar.swift",
        "Remote/Sources/Permission/PermissionSheet.swift",
        "Remote/Sources/Elicitation/ElicitationSheet.swift",
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
        for source in try Self.sources(under: ["App/Sources", "Remote/Sources", "Shared/UI"]) {
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

    // MARK: 5. One chat on every screen (033 FR-021)

    /// The transcript's pieces, which live in `Shared/UI/Chat` and nowhere else. The
    /// phone had its own copy of each of these until 033, and in a month it had grown
    /// a chevron and an "N more" the Mac never had.
    private static let sharedChatTypes = [
        "EntryRow", "ToolRunRow", "ToolCallLine", "StateLine", "WorkReportLine",
        "QueuedPromptRow", "WorkingLine", "ComingBackLine", "JumpToEnd", "BlocksView",
        "DiffView", "PlanView", "TerminalOutputView", "ServedRequestLine", "CommandList",
        "MentionList", "OptionMenu", "SelectCapsule", "Dictation",
    ]

    /// The name of a type a line declares, if it declares one.
    static func declaredType(_ line: String) -> String? {
        let declaration = /^\s*(?:private\s+|fileprivate\s+|public\s+)?(?:final\s+)?(?:struct|class|enum)\s+(\w+)/
        return Self.code(line).firstMatch(of: declaration).map { String($0.output.1) }
    }

    /// Every string literal on a line long enough to be a sentence somebody reads.
    static func sentences(_ line: String, atLeast length: Int = 20) -> [String] {
        Self.code(line).matches(of: /"((?:[^"\\]|\\.)*)"/)
            .map { String($0.output.1) }
            .filter { $0.count >= length && $0.contains(" ") && !$0.contains("\\(") }
    }

    /// Both checks, against lines that must and must not trip them.
    @Test func theChatScansCatchWhatTheyAreFor() {
        #expect(Self.declaredType("private struct ToolRunRow: View {") == "ToolRunRow")
        #expect(Self.declaredType("struct EntryView: View {") == "EntryView")
        #expect(Self.declaredType("    let row = ToolRunRow(calls: [])") == nil)
        #expect(Self.declaredType("// struct ToolRunRow was here") == nil)
        #expect(Self.sentences(#"Text("Say what next, and it goes when this turn ends")"#)
                == ["Say what next, and it goes when this turn ends"])
        #expect(Self.sentences(#"Label("Folder", systemImage: "folder")"#).isEmpty)
        // A comment that quotes a sentence is not a second copy of it.
        #expect(Self.sentences(#"// "Say what next, and it goes when this turn ends""#).isEmpty)
    }

    @Test func thePhoneDrawsTheSharedChatRatherThanItsOwn() throws {
        var violations: [String] = []
        var scanned = 0
        for source in try Self.sources(under: ["Remote/Sources", "App/Sources"]) {
            scanned += 1
            for (index, line) in source.lines.enumerated() {
                guard let name = Self.declaredType(line), Self.sharedChatTypes.contains(name) else { continue }
                violations.append("\(Self.at(source, index)): \(name)")
            }
        }
        #expect(scanned > 50, "too few sources were read; the repository root is wrong")
        #expect(violations.isEmpty, """
            An app declares its own copy of a piece of the chat that lives in \
            `Shared/UI/Chat`. Two copies drift; change the shared one, and if the phone \
            genuinely needs to differ, say how through `ChatActions` or a platform \
            branch in the shared file, and add it to 033's Deliberate Differences.
            \(violations.joined(separator: "\n"))
            """)
    }

    /// The live page's pieces, one copy for both apps in `Shared/UI/Page` and Core (034).
    private static let sharedPageTypes = [
        "MarkdownText", "LivePage", "PassageEditor", "CursorFlag", "FileLines",
        "PageFollower", "PassageMerge", "ImageStamps", "ShellClient",
    ]

    /// The page is one page on the Mac and the phone. Two `MarkdownText`s drifted once;
    /// this is what stops two pages doing the same.
    @Test func neitherAppHasAPageOfItsOwn() throws {
        var violations: [String] = []
        var scanned = 0
        for source in try Self.sources(under: ["Remote/Sources", "App/Sources"]) {
            scanned += 1
            for (index, line) in source.lines.enumerated() {
                guard let name = Self.declaredType(line), Self.sharedPageTypes.contains(name) else { continue }
                violations.append("\(Self.at(source, index)): \(name)")
            }
        }
        #expect(scanned > 50, "too few sources were read; the repository root is wrong")
        #expect(violations.isEmpty, """
            An app declares its own copy of a piece of the live page, which lives in \
            `Shared/UI/Page` and AgentsKitCore. Change the shared one; what genuinely \
            differs by app goes through `PageActions` or a platform branch there.
            \(violations.joined(separator: "\n"))
            """)
    }

    /// A sentence written into both apps' chats, rather than once where both read it.
    ///
    /// The chat folders only: a settings screen that happens to share a phrase with a
    /// phone screen is not what this is about.
    @Test func noSentenceInTheChatIsWrittenTwice() throws {
        func sentences(under directory: String) throws -> [String: String] {
            var found: [String: String] = [:]
            for source in try Self.sources(under: [directory]) {
                for (index, line) in source.lines.enumerated() {
                    for sentence in Self.sentences(line) { found[sentence] = Self.at(source, index) }
                }
            }
            return found
        }
        let shared = try sentences(under: "Shared/UI/Chat")
        let mac = try sentences(under: "App/Sources/Chat")
        let phone = try sentences(under: "Remote/Sources/Chat")
        #expect(!shared.isEmpty && !mac.isEmpty && !phone.isEmpty, "a chat folder has moved")

        var violations: [String] = []
        for (sentence, place) in mac where phone[sentence] != nil {
            violations.append("\(place) and \(phone[sentence]!): \"\(sentence)\"")
        }
        for (sentence, place) in shared {
            if let copy = mac[sentence] ?? phone[sentence] {
                violations.append("\(copy) repeats \(place): \"\(sentence)\"")
            }
        }
        #expect(violations.isEmpty, """
            A sentence in the chat is written in more than one place. Put it in \
            `Shared/UI/Chat` (`PromptWords` for the prompt area) and read it from there, \
            so the Mac and the phone cannot come to say different things.
            \(violations.sorted().joined(separator: "\n"))
            """)
    }
}
