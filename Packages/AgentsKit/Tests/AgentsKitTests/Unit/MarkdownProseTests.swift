import Foundation
import Testing
@testable import AgentsKitCore

/// Which blocks of a message go in one selectable text (#5155).
@Suite("Markdown prose runs")
struct MarkdownProseTests {
    @Test func aPromptOfParagraphsAndAListIsOneRun() {
        let blocks = MarkdownBlock.parse("One.\n\nTwo.\n\nThree.\n\n- a\n- b\n\n# After")
        #expect(MarkdownBlock.segments(blocks) == [.prose(0..<blocks.count)])
    }

    @Test func codeCutsTheWords() {
        let blocks = MarkdownBlock.parse("Before.\n\n```swift\nlet x = 1\n```\n\nAfter.\n\nMore.")
        #expect(MarkdownBlock.segments(blocks) == [.prose(0..<1), .block(1), .prose(2..<4)])
    }

    @Test func aListWithCodeInItIsNotProse() throws {
        let blocks = MarkdownBlock.parse("- step\n\n  ```\n  make\n  ```\n- done")
        let list = try #require(blocks.first)
        #expect(blocks.count == 1)
        #expect(!list.isProse)
        #expect(MarkdownBlock.segments(blocks) == [.block(0)])
    }

    @Test func quotesOfWordsAreProse() {
        let blocks = MarkdownBlock.parse("> said\n>\n> - and listed")
        #expect(blocks.allSatisfy { $0.isProse })
    }

    @Test func blocksThatAreNotWordsStandAlone() {
        let blocks = MarkdownBlock.parse("---\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(MarkdownBlock.segments(blocks) == [.block(0), .block(1)])
        #expect(MarkdownBlock.segments([]) == [])
    }

    @Test func codeJoinsTheWordsWhenAsked() {
        let blocks = MarkdownBlock.parse("Before.\n\n```swift\nlet x = 1\n```\n\nAfter.")
        #expect(MarkdownBlock.segments(blocks, code: true) == [.prose(0..<3)])
    }

    @Test func aDiagramAndATableStillStandAloneWithCode() {
        let blocks = MarkdownBlock.parse("Before.\n\n```mermaid\ngraph TD\nA-->B\n```\n\n```sh\nmake\n```\n\n| a |\n|---|\n| 1 |")
        #expect(MarkdownBlock.segments(blocks, code: true) == [.prose(0..<1), .block(1), .prose(2..<3), .block(3)])
    }

    @Test func codeInAListStaysApartWithCode() {
        let blocks = MarkdownBlock.parse("- step\n\n  ```\n  make\n  ```\n- done")
        #expect(MarkdownBlock.segments(blocks, code: true) == [.block(0)])
    }
}
