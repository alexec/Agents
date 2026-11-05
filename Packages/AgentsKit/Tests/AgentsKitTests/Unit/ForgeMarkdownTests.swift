import Foundation
import Testing
@testable import AgentsKitCore

/// An issue's words are drawn as the forge draws them: its comments hidden, its few HTML
/// tags as Markdown, its line breaks kept, and its title's code spans as code. The web
/// page's `forgeMarkdown.test.mjs` holds the same cases.
@Suite("Forge Markdown")
struct ForgeMarkdownTests {
    private func md(_ text: String) -> String { ForgeMarkdown.markdown(text) }

    @Test func anHTMLCommentIsHiddenAlsoOverLines() {
        #expect(md("<!-- agent -->\nFixed in #12.") == "Fixed in #12.")
        #expect(md("One <!-- note --> two") == "One  two")
        #expect(md("Before\n\n<!--\nhidden\n-->\n\nAfter") == "Before\n\n\nAfter")
    }

    @Test func aCommentInCodeIsCode() {
        #expect(md("Start with `<!-- agent -->`.") == "Start with `<!-- agent -->`.")
        #expect(md("```html\n<!-- kept -->\n<br>\n```") == "```html\n<!-- kept -->\n<br>\n```")
    }

    @Test func detailsAndSummaryAreABoldLineAndWhatFollows() {
        #expect(md("<details>\n<summary>Logs</summary>\n\nline\n</details>") == "**Logs**\n\nline")
        #expect(md("<details open><summary>Logs</summary>") == "**Logs**")
    }

    @Test func brIsAHardBreakAndASpaceInATableRow() {
        #expect(md("one<br>two") == "one  \ntwo")
        #expect(md("| a<br/>b | c |") == "| a b | c |")
    }

    @Test func imgAndAAreMarkdownImagesAndLinks() {
        #expect(md(#"<img width="300" alt="Mac [list]" src="https://x.test/a.png" />"#) == #"![Mac \[list\]](<https://x.test/a.png>)"#)
        #expect(md("<a href='https://x.test'>site</a>") == "[site](<https://x.test>)")
        #expect(md("<img alt=none>") == "")
    }

    @Test func inlineMarksAreMarkdownMarks() {
        #expect(md("<b>Note:</b> <i>this</i> <code>x</code> <kbd>⌘K</kbd> <del>old</del>") == "**Note:** *this* `x` `⌘K` ~~old~~")
        #expect(md(#"<p align="center">centred</p>"#) == "centred")
        #expect(md("<h3>Heading</h3>") == "### Heading")
    }

    @Test func anyOtherTagStaysAsItWasWritten() {
        #expect(md("<script>alert(1)</script>") == "<script>alert(1)</script>")
    }

    @Test func aSingleLineBreakInAParagraphIsKept() {
        #expect(md("one\ntwo\nthree") == "one  \ntwo  \nthree")
        #expect(md("- a\n- b") == "- a\n- b")
        #expect(md("Title\n---") == "Title\n---")
        #expect(md("| a | b |\n|---|---|") == "| a | b |\n|---|---|")
        #expect(md("text\n# Heading") == "text\n# Heading")
        #expect(md("```\nx\ny\n```") == "```\nx\ny\n```")
    }

    #if canImport(Darwin)
    /// What `MarkdownText` then draws: the comment gone, the summary bold, the break kept.
    @Test func theBlocksAreTheForges() {
        let blocks = MarkdownBlock.parse(md("<!-- agent -->\n<details><summary>Logs</summary>\n\none\ntwo\n</details>"))
        let words = blocks.map { block -> String? in
            guard case .paragraph(let text) = block else { return nil }
            return String(text.characters)
        }
        #expect(words == ["Logs", "one\ntwo"])
    }
    #endif

    @Test func aTitlesCodeSpansAreCode() {
        typealias Part = ForgeMarkdown.TitlePart
        #expect(ForgeMarkdown.titleParts("Fix `make.sh` on `main`") == [
            Part(text: "Fix ", code: false), Part(text: "make.sh", code: true),
            Part(text: " on ", code: false), Part(text: "main", code: true),
        ])
        #expect(ForgeMarkdown.titleParts("`` `a` ``") == [Part(text: "`a`", code: true)])
        #expect(ForgeMarkdown.titleParts("No `end") == [Part(text: "No `end", code: false)])
        #expect(ForgeMarkdown.titleParts("**bold** stays") == [Part(text: "**bold** stays", code: false)])
    }
}
