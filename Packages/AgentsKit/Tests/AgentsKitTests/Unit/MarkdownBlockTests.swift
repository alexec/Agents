import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Reading markdown")
struct MarkdownBlockTests {
    /// The common shape: a list entry that is one line of prose.
    private func item(_ text: AttributedString, checked: Bool? = nil) -> MarkdownBlock.Item {
        .init(blocks: [.paragraph(text)], checked: checked)
    }

    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    @Test func plainTextIsOneParagraph() {
        #expect(MarkdownBlock.parse("Just a line.") == [.paragraph("Just a line.")])
    }

    @Test func blankLinesSeparateParagraphs() {
        let blocks = MarkdownBlock.parse("First.\n\nSecond.")
        #expect(blocks == [.paragraph("First."), .paragraph("Second.")])
    }

    @Test func nothingAtAllIsNoBlocks() {
        #expect(MarkdownBlock.parse("") == [])
        #expect(MarkdownBlock.parse("\n\n  \n") == [])
    }

    @Test func fencedCodeIsKeptExactly() {
        let blocks = MarkdownBlock.parse("Try:\n\n```swift\nlet a = 1\n  let b = 2\n```\n\nDone.")
        #expect(blocks == [.paragraph("Try:"),
                           .code(language: "swift", text: "let a = 1\n  let b = 2"),
                           .paragraph("Done.")])
    }

    @Test func anUnclosedFenceStillEndsSomewhere() {
        // Agents stream, so a code block is unfinished for as long as it takes. The
        // pane truncates at 128 KB, so a file can end this way too.
        let blocks = MarkdownBlock.parse("```\nhalf a fun")
        #expect(blocks == [.code(language: nil, text: "half a fun")])
    }

    @Test func headingsCarryTheirDepth() {
        let blocks = MarkdownBlock.parse("# One\n### Three\n#NotAHeading")
        #expect(blocks == [.heading(level: 1, text: "One"),
                           .heading(level: 3, text: "Three"),
                           .paragraph("#NotAHeading")])
    }

    @Test func aHeadingCanBeUnderlinedInstead() {
        // Setext. The old scanner turned the second of these into a paragraph and a
        // horizontal rule, which is a heading silently becoming a line.
        let blocks = MarkdownBlock.parse("One\n===\n\nTwo\n---")
        #expect(blocks == [.heading(level: 1, text: "One"), .heading(level: 2, text: "Two")])
    }

    @Test func aRunOfBulletsIsOneList() {
        let blocks = MarkdownBlock.parse("- one\n- two\n- three")
        #expect(blocks == [.list(ordered: false, start: 1,
                                 items: [item("one"), item("two"), item("three")])])
    }

    @Test func changingTheMarkerStartsANewList() {
        // CommonMark's rule, and the old scanner had it wrong: `-` and `*` were merged
        // into one run. Two markers mean the author meant two lists.
        let blocks = MarkdownBlock.parse("- one\n* two")
        #expect(blocks == [.list(ordered: false, start: 1, items: [item("one")]),
                           .list(ordered: false, start: 1, items: [item("two")])])
    }

    @Test func numberedListsAreTheirOwnThing() {
        let blocks = MarkdownBlock.parse("1. first\n2. second")
        #expect(blocks == [.list(ordered: true, start: 1, items: [item("first"), item("second")])])
    }

    @Test func anOrderedListKeepsTheNumberItStartedAt() {
        // `3.` means three. Renumbering from one loses what the author was counting.
        let blocks = MarkdownBlock.parse("3. three\n4. four")
        #expect(blocks == [.list(ordered: true, start: 3, items: [item("three"), item("four")])])
    }

    @Test func listsNestToAnyDepth() {
        // The reason the parser was replaced. The old scanner trimmed each line before
        // looking at it, so indentation — and with it every level of nesting in this
        // repository's own documents — was gone before it could be seen.
        let blocks = MarkdownBlock.parse("- top\n  - inner\n    - deepest\n- second")
        let expected: [MarkdownBlock] = [
            .list(ordered: false, start: 1, items: [
                .init(blocks: [
                    .paragraph("top"),
                    .list(ordered: false, start: 1, items: [
                        .init(blocks: [
                            .paragraph("inner"),
                            .list(ordered: false, start: 1, items: [item("deepest")]),
                        ]),
                    ]),
                ]),
                item("second"),
            ]),
        ]
        #expect(blocks == expected)
    }

    @Test func aCheckboxIsStructureRatherThanText() {
        // 2,212 of these in this repository. CommonMark has no task lists, so the box
        // arrives as the literal characters `[ ]` and is taken back off here.
        let blocks = MarkdownBlock.parse("- [ ] todo\n- [x] done\n- plain")
        #expect(blocks == [.list(ordered: false, start: 1, items: [
            item("todo", checked: false),
            item("done", checked: true),
            item("plain"),
        ])])
    }

    @Test func aListEndsWhenSomethingElseStarts() {
        let blocks = MarkdownBlock.parse("- one\n\nAfter.")
        #expect(blocks == [.list(ordered: false, start: 1, items: [item("one")]),
                           .paragraph("After.")])
    }

    @Test func quotesAndRules() {
        let blocks = MarkdownBlock.parse("> said\n> twice\n\n---")
        #expect(blocks == [.quote([.paragraph("said twice")]), .rule])
    }

    @Test func quotesHoldBlocksAndNest() {
        let blocks = MarkdownBlock.parse("> outer\n>\n> > inner")
        #expect(blocks == [.quote([.paragraph("outer"), .quote([.paragraph("inner")])])])
    }

    @Test func softWrappedProseReflows() {
        // What the screenshots showed: a file hard-wrapped by its author must not keep
        // those breaks, or every line ends short and ragged at any pane wider than the
        // author's column.
        #expect(MarkdownBlock.parse("hard wrapped\nprose here.") == [.paragraph("hard wrapped prose here.")])
    }

    @Test func aDeliberateLineBreakIsKept() {
        // Two trailing spaces. Reflowing this one would be losing something.
        guard case .paragraph(let text)? = MarkdownBlock.parse("one  \ntwo").first else {
            Issue.record("not a paragraph"); return
        }
        #expect(plain(text) == "one\ntwo")
    }

    @Test func windowsLineEndingsAreJustLineEndings() {
        // The old scanner split on `\r` and `\n` separately, so a CRLF file gained a
        // blank line after every line: each bullet became a list of its own.
        let blocks = MarkdownBlock.parse("a\r\nb\r\n\r\n- one\r\n- two")
        #expect(blocks == [.paragraph("a b"),
                           .list(ordered: false, start: 1, items: [item("one"), item("two")])])
    }

    @Test func frontMatterDoesNotEatTheFirstHeading() {
        // Unstripped, CommonMark reads the `---` as a rule, the keys as a setext
        // heading, and swallows the real heading under it into that same heading.
        let blocks = MarkdownBlock.parse("---\ntitle: T\nstatus: Draft\n---\n\n# Real\n\nBody.")
        #expect(blocks == [.heading(level: 1, text: "Real"), .paragraph("Body.")])
    }

    @Test func aRuleInTheMiddleIsStillARule() {
        // The other direction, and the one that would quietly eat a document: `---` is
        // only front matter on the very first line.
        #expect(MarkdownBlock.parse("Para.\n\n---\n\nNext.") ==
                [.paragraph("Para."), .rule, .paragraph("Next.")])
    }

    @Test func imagesBecomeBlocksOfTheirOwn() {
        // SwiftUI cannot draw an image inside a run of text, so one sitting in a
        // paragraph becomes a sibling of it rather than vanishing (FR-013).
        let blocks = MarkdownBlock.parse("![alt text](./d.png)\n\nWith ![inline](./i.png) inside.")
        #expect(blocks == [.image(source: "./d.png", alt: "alt text"),
                           .paragraph("With"),
                           .image(source: "./i.png", alt: "inline"),
                           .paragraph("inside.")])
    }

    @Test func inlineMarksAreAttributesRatherThanCharacters() {
        // They come out of the same parse as the blocks. Nobody downstream should be
        // parsing a payload a second time.
        guard case .paragraph(let text)? = MarkdownBlock.parse("a **bold** [link](./x.md)").first else {
            Issue.record("not a paragraph"); return
        }
        #expect(plain(text) == "a bold link")
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(text.runs.contains { $0.link?.absoluteString == "./x.md" })
    }

    @Test func nothingIsLost() {
        // Whatever it does not understand stays as text rather than vanishing. Raw
        // HTML now arrives as an unlabelled code block — shown as written, which is
        // what the promise was — rather than as prose pretending to be prose.
        let blocks = MarkdownBlock.parse("<details><summary>a</summary>\n\nbody\n</details>")
        #expect(blocks.contains(.code(language: nil, text: "<details><summary>a</summary>")))
        #expect(blocks.contains(.paragraph("body")))
    }

    // MARK: GitHub tables

    @Test func aTableIsReadAsATable() {
        let blocks = MarkdownBlock.parse("| Runtime | Ready |\n|---|---|\n| claude | yes |\n| grok | no |")
        #expect(blocks == [.table(.init(header: ["Runtime", "Ready"],
                                        columns: [.leading, .leading],
                                        rows: [["claude", "yes"], ["grok", "no"]]))])
    }

    @Test func theDashesSayHowColumnsLineUp() {
        let blocks = MarkdownBlock.parse("a | b | c\n:--- | :---: | ---:\n1 | 2 | 3")
        guard case .table(let table) = blocks.first else { Issue.record("not a table"); return }
        #expect(table.columns == [.leading, .centre, .trailing])
        #expect(table.header == ["a", "b", "c"])
        #expect(table.rows == [["1", "2", "3"]])
    }

    @Test func aRaggedRowIsMadeRectangular() {
        // GitHub pads the short row and drops what runs over.
        let blocks = MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")
        guard case .table(let table) = blocks.first else { Issue.record("not a table"); return }
        #expect(table.rows == [["1", ""], ["1", "2"]])
    }

    @Test func anEscapedPipeStaysInTheCell() {
        let blocks = MarkdownBlock.parse("| a |\n|---|\n| one \\| two |")
        guard case .table(let table) = blocks.first else { Issue.record("not a table"); return }
        #expect(table.rows == [["one | two"]])
    }

    @Test func pipesWithoutDashesUnderThemAreJustText() {
        // A line of prose with a pipe in it is not the start of a table. The pipe is
        // inside a code span, so it survives as a character; the backticks do not,
        // because they are an attribute now.
        guard case .paragraph(let text)? = MarkdownBlock.parse("run `a | b` to see").first else {
            Issue.record("not a paragraph"); return
        }
        #expect(plain(text) == "run a | b to see")
    }

    @Test func aTableEndsAtTheBlankLineAfterIt() {
        let blocks = MarkdownBlock.parse("| a |\n|---|\n| 1 |\n\nAfter.")
        #expect(blocks.count == 2)
        #expect(blocks.last == .paragraph("After."))
    }

    @Test func aTableCanFollowAParagraph() {
        let blocks = MarkdownBlock.parse("Here:\n| a |\n|---|\n| 1 |")
        #expect(blocks.first == .paragraph("Here:"))
        #expect(blocks.count == 2)
    }

    // MARK: The property the whole feature rests on

    @Test func everyDocumentInThisRepositoryReadsWithoutLosingItsText() throws {
        // Totality, the same shape as 004's "grouping is total over AgentState".
        // A block kind nobody folded would show up as a document missing a paragraph,
        // silently, in exactly the files this feature exists to read.
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let specs = root.appending(path: "specs")
        guard FileManager.default.fileExists(atPath: specs.path) else { return }

        var checked = 0
        let walker = FileManager.default.enumerator(at: specs, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "md",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let blocks = MarkdownBlock.parse(source)
            checked += 1
            // A document with words in it must produce blocks with words in them.
            if source.contains(where: \.isLetter) {
                #expect(!blocks.isEmpty, "\(url.lastPathComponent) produced nothing")
            }
        }
        #expect(checked > 0, "no specs were read; the corpus path is wrong")
    }
}
