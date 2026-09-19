import Foundation
import Testing
@testable import AgentsKit

@Suite("Reading markdown")
struct MarkdownBlockTests {
    @Test func plainTextIsOneParagraph() {
        #expect(MarkdownBlock.parse("Just a line.") == [.paragraph("Just a line.")])
    }

    @Test func blankLinesSeparateParagraphs() {
        let blocks = MarkdownBlock.parse("First.\n\nSecond.")
        #expect(blocks == [.paragraph("First."), .paragraph("Second.")])
    }

    @Test func fencedCodeIsKeptExactly() {
        let blocks = MarkdownBlock.parse("Try:\n\n```swift\nlet a = 1\n  let b = 2\n```\n\nDone.")
        #expect(blocks == [.paragraph("Try:"),
                           .code(language: "swift", text: "let a = 1\n  let b = 2"),
                           .paragraph("Done.")])
    }

    @Test func anUnclosedFenceStillEndsSomewhere() {
        // Agents stream, so a code block is unfinished for as long as it takes.
        let blocks = MarkdownBlock.parse("```\nhalf a fun")
        #expect(blocks == [.code(language: nil, text: "half a fun")])
    }

    @Test func headingsCarryTheirDepth() {
        let blocks = MarkdownBlock.parse("# One\n### Three\n#NotAHeading")
        #expect(blocks == [.heading(level: 1, text: "One"),
                           .heading(level: 3, text: "Three"),
                           .paragraph("#NotAHeading")])
    }

    @Test func aRunOfBulletsIsOneList() {
        let blocks = MarkdownBlock.parse("- one\n- two\n* three")
        #expect(blocks == [.bullets(["one", "two", "three"])])
    }

    @Test func numberedListsAreTheirOwnThing() {
        let blocks = MarkdownBlock.parse("1. first\n2. second")
        #expect(blocks == [.numbered(["first", "second"])])
    }

    @Test func aListEndsWhenSomethingElseStarts() {
        let blocks = MarkdownBlock.parse("- one\n\nAfter.")
        #expect(blocks == [.bullets(["one"]), .paragraph("After.")])
    }

    @Test func quotesAndRules() {
        let blocks = MarkdownBlock.parse("> said\n> twice\n\n---")
        #expect(blocks == [.quote("said\ntwice"), .rule])
    }

    @Test func nothingIsLost() {
        // Whatever it does not understand stays as text rather than vanishing.
        let odd = "<details><summary>a</summary>\n\nbody\n</details>"
        let blocks = MarkdownBlock.parse(odd)
        #expect(blocks.contains(.paragraph("<details><summary>a</summary>")))
        #expect(blocks.contains(.paragraph("body\n</details>")))
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
        // A line of prose with a pipe in it is not the start of a table.
        let blocks = MarkdownBlock.parse("run `a | b` to see")
        #expect(blocks == [.paragraph("run `a | b` to see")])
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
}
