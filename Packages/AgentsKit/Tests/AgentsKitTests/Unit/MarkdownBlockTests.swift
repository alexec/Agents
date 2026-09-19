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
        let odd = "| a | b |\n|---|---|\n| 1 | 2 |"
        let blocks = MarkdownBlock.parse(odd)
        #expect(blocks.count == 1)
        if case .paragraph(let text) = blocks[0] { #expect(text.contains("| 1 | 2 |")) }
    }
}
