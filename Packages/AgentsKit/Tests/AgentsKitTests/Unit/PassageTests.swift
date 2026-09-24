import Foundation
import Testing
@testable import AgentsKitCore

/// A passage is a run of source lines, and the page's unit of everything: what is
/// marked, what is followed, what is edited, what is merged, what the agent is told.
///
/// The claim this suite carries: splitting then joining is the identity on any
/// document, and every line of a document is in exactly one passage. Both matter
/// because the daemon writes back whatever the page hands it — a split that lost a
/// blank line would be a page that quietly rewrote the file every time somebody typed.
@Suite("Passages")
struct PassageTests {
    private func sources(_ text: String) -> [String] {
        Passage.split(text).map(\.source)
    }

    // MARK: Splitting

    @Test func plainTextWithNoBlankLinesIsOnePassage() {
        let passages = Passage.split("One.\nTwo.\nThree.")
        #expect(passages.count == 1)
        #expect(passages[0].source == "One.\nTwo.\nThree.")
        #expect(passages[0].lines == 1...3)
        #expect(passages[0].separator == "")
    }

    @Test func oneBlankLineMakesTwoPassages() {
        let passages = Passage.split("First.\n\nSecond.")
        #expect(passages.map(\.source) == ["First.", "Second."])
        #expect(passages[0].separator == "\n\n")
        #expect(passages[1].separator == "")
        #expect(passages[0].lines == 1...1)
        #expect(passages[1].lines == 3...3)
    }

    @Test func aRunOfBlankLinesIsKeptExactly() {
        let passages = Passage.split("A\n\n\n\nB")
        #expect(passages.map(\.source) == ["A", "B"])
        #expect(passages[0].separator == "\n\n\n\n")
    }

    @Test func aBlankLineInsideABacktickFenceDoesNotSplit() {
        let text = "Try:\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nDone."
        #expect(sources(text) == ["Try:", "```swift\nlet a = 1\n\nlet b = 2\n```", "Done."])
    }

    @Test func aTildeFenceIsAFenceToo() {
        let text = "~~~\nx\n\ny\n~~~\n\nAfter."
        #expect(sources(text) == ["~~~\nx\n\ny\n~~~", "After."])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        // Agents stream, so a fence is open for as long as it takes to close it.
        let text = "Before.\n\n```\nhalf\n\nof a\n\nthing"
        #expect(sources(text) == ["Before.", "```\nhalf\n\nof a\n\nthing"])
    }

    @Test func aHeadingRunningStraightIntoAParagraphIsOnePassage() {
        let passages = Passage.split("# Title\nThe first line.\n\nNext.")
        #expect(passages.map(\.source) == ["# Title\nThe first line.", "Next."])
        #expect(passages[0].isHeading)
        #expect(!passages[1].isHeading)
    }

    @Test func aSetextHeadingIsAHeading() {
        let passages = Passage.split("Title\n=====\n\nBody.")
        #expect(passages[0].isHeading)
        #expect(Passage.split("Sub\n---")[0].isHeading)
    }

    @Test func frontMatterIsOnePassage() {
        let text = "---\ntitle: x\nkind: y\n---\n\nBody."
        let passages = Passage.split(text)
        #expect(passages.map(\.source) == ["---\ntitle: x\nkind: y\n---", "Body."])
        // `---` under `title: x` would be a setext rule if this were prose; front
        // matter is not prose, and the page has no business drawing it as a heading.
        #expect(!passages[0].isHeading)
    }

    @Test func nothingIsNoPassages() {
        #expect(Passage.split("") == [])
        #expect(Passage.split("\n\n\n") == [])
        #expect(Passage.split("  \n \n") == [])
    }

    @Test func leadingBlankLinesBelongToTheFirstPassage() {
        let passages = Passage.split("\n\nA")
        #expect(passages.count == 1)
        #expect(passages[0].source == "\n\nA")
        #expect(passages[0].lines == 1...3)
    }

    @Test func aTrailingNewlineIsKeptAsTheLastSeparator() {
        let passages = Passage.split("A\n")
        #expect(passages.map(\.source) == ["A"])
        #expect(passages[0].separator == "\n")
    }

    @Test func everyLineIsInExactlyOnePassage() {
        let text = "# T\n\nA\nB\n\n\n```\n\nc\n```\n\nD\n"
        let passages = Passage.split(text)
        #expect(passages.first?.lines.lowerBound == 1)
        for (before, after) in zip(passages, passages.dropFirst()) {
            // A separator is the newline that ends the passage plus one per blank
            // line it owns, so the next passage starts that many lines on.
            let blank = max(0, before.separator.count - 1)
            #expect(after.lines.lowerBound == before.lines.upperBound + blank + 1)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            - (text.hasSuffix("\n") ? 1 : 0)
        let last = try! #require(passages.last)
        #expect(last.lines.upperBound + max(0, last.separator.count - 1) == lines)
    }

    // MARK: Joining

    @Test func joinUndoesSplit() throws {
        let cases = [
            "One.\nTwo.\nThree.", "First.\n\nSecond.", "A\n\n\n\nB",
            "Try:\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nDone.",
            "~~~\nx\n\ny\n~~~\n\nAfter.", "Before.\n\n```\nhalf\n\nof a\n\nthing",
            "# Title\nThe first line.\n\nNext.", "---\ntitle: x\n---\n\nBody.",
            "\n\nA", "A\n", "A\n\n", "",
        ]
        // Not in the list: a document that is nothing but blank lines. That splits to
        // no passages and joins to nothing, and the page has nothing to hand the
        // daemon for it. The one document the round trip does not hold for.
        for text in cases {
            #expect(Passage.join(Passage.split(text)) == text, "\(text.debugDescription)")
        }
        // This repository's own README, which has every shape of block in it.
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        #expect(Passage.join(Passage.split(text)) == text)
    }

    @Test func joiningNothingIsNothing() {
        #expect(Passage.join([]) == "")
    }

    // MARK: A line, as a passage

    @Test func aLineFindsThePassageThatHoldsIt() {
        let passages = Passage.split("A\nB\n\nC\n\n\nD")
        #expect(Passage.index(containing: 1, in: passages) == 0)
        #expect(Passage.index(containing: 2, in: passages) == 0)
        #expect(Passage.index(containing: 4, in: passages) == 1)
        #expect(Passage.index(containing: 7, in: passages) == 2)
    }

    @Test func aLineInTheBlankRunBelongsToThePassageBeforeIt() {
        let passages = Passage.split("A\n\n\nB")
        #expect(Passage.index(containing: 2, in: passages) == 0)
        #expect(Passage.index(containing: 3, in: passages) == 0)
    }

    @Test func aLinePastTheEndIsTheLastPassage() {
        let passages = Passage.split("A\n\nB")
        #expect(Passage.index(containing: 400, in: passages) == 1)
    }

    @Test func aLineThatIsNotALineIsNowhere() {
        let passages = Passage.split("A\n\nB")
        #expect(Passage.index(containing: 0, in: passages) == nil)
        #expect(Passage.index(containing: -3, in: passages) == nil)
        #expect(Passage.index(containing: 1, in: []) == nil)
    }
}

/// What differs between two versions of a document, said in passages of the new one.
///
/// The agent's tools rewrite the file whole, so the disk only ever shows before and
/// after. This is what turns that into "the third paragraph changed", which is what
/// the page marks and scrolls to.
@Suite("What changed")
struct PassageChangeTests {
    @Test func identicalTextsChangeNothing() {
        let change = PassageChange.between(old: "A\n\nB", new: "A\n\nB")
        #expect(change.changedLines == nil)
        #expect(change.changed.isEmpty)
        #expect(change.first == nil)
    }

    @Test func aPassageAppendedIsTheOnlyOneMarked() {
        let change = PassageChange.between(old: "A\n\nB", new: "A\n\nB\n\nC")
        #expect(change.changed == IndexSet([2]))
        #expect(change.first == 2)
    }

    @Test func aWordChangedMarksOnlyItsPassage() {
        let change = PassageChange.between(old: "A\n\nB one\n\nC", new: "A\n\nB two\n\nC")
        #expect(change.changed == IndexSet([1]))
        #expect(change.first == 1)
        #expect(change.changedLines == 3...3)
    }

    @Test func twoPassagesApartAreBothMarkedAndNothingBetween() {
        let change = PassageChange.between(old: "A\n\nB\n\nC\n\nD", new: "A!\n\nB\n\nC\n\nD!")
        #expect(change.changed == IndexSet([0, 3]))
        #expect(change.first == 0)
    }

    @Test func aPassageDeletedMarksWhatNowSitsThere() {
        let change = PassageChange.between(old: "A\n\nB\n\nC", new: "A\n\nC")
        #expect(change.changed == IndexSet([1]))
        #expect(change.first == 1)
    }

    @Test func theLastPassageDeletedMarksTheNewLast() {
        let change = PassageChange.between(old: "A\n\nB\n\nC", new: "A\n\nB")
        #expect(change.changed == IndexSet([1]))
    }

    @Test func anEntirelyDifferentTextMarksEverything() {
        let change = PassageChange.between(old: "A\n\nB", new: "X\n\nY\n\nZ")
        #expect(change.changed == IndexSet([0, 1, 2]))
        #expect(change.first == 0)
    }

    @Test func aFirstWriteMarksEverything() {
        let change = PassageChange.between(old: "", new: "X\n\nY")
        #expect(change.changed == IndexSet([0, 1]))
        #expect(change.first == 0)
    }

    @Test func everythingDeletedMarksNothing() {
        let change = PassageChange.between(old: "X\n\nY", new: "")
        #expect(change.changed.isEmpty)
        #expect(change.first == nil)
    }
}
