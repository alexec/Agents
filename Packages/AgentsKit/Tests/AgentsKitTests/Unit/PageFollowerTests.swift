import Foundation
import Testing
@testable import AgentsKitCore

/// The live page's rules, which lived in a view where no test could reach them until
/// the phone needed the same page (034). 022's behaviour first, then what a dropped
/// connection adds.
@Suite("A live page following a file and taking typing")
struct PageFollowerTests {
    private let three = "# Title\n\nOne.\n\nTwo.\n"

    private func loaded(_ text: String) -> PageFollower {
        var page = PageFollower()
        page.load(text)
        return page
    }

    private func typedOut(_ page: inout PageFollower) {
        while page.tick() {}
    }

    // MARK: Following the agent

    @Test func loadingSplitsIntoPassages() {
        let page = loaded(three)
        #expect(page.passages.map(\.source) == ["# Title", "One.", "Two."])
        #expect(page.revealing == nil)
    }

    @Test func aWriteQueuesItsBlocksForOneCaretInDocumentOrder() {
        var page = loaded(three)
        let effects = page.follow("# Title\n\nOne, more.\n\nTwo.\n\nThree.\n")
        #expect(effects.isEmpty, "the caret takes the view; nothing needs moving by hand")
        #expect(page.revealing?.index == 1)
        #expect(page.pending.map(\.index) == [3])
        // The rewritten block types from where it stopped agreeing, not from the top.
        #expect(page.shown(1) == "One")
        // The appended block is not on the page until its turn.
        #expect(page.shown(3) == "")
        typedOut(&page)
        #expect(page.shown(1) == "One, more.")
        #expect(page.shown(3) == "Three.")
    }

    @Test func aSecondWriteCompletesTheFirstBeforeQueueingItsOwn() {
        var page = loaded(three)
        _ = page.follow("# Title\n\nOne, more and more and more.\n\nTwo.\n")
        #expect(page.revealing?.index == 1)
        _ = page.follow("# Title\n\nOne, more and more and more.\n\nTwo, again.\n")
        #expect(page.revealing?.index == 2, "one caret: the first block was completed, not raced")
        #expect(page.shown(1) == "One, more and more and more.")
    }

    @Test func aDeletionHasNothingToTypeAndMovesTheViewByHand() {
        var page = loaded(three)
        // The last passage goes: nothing is left to type, so the view is moved.
        let effects = page.follow("# Title\n\nOne.\n")
        #expect(page.revealing == nil)
        #expect(effects.count == 1)
        guard case .scroll = effects.first else { Issue.record("no scroll"); return }
    }

    @Test func aNamedLineFindsItsPassage() {
        let page = loaded(three)
        #expect(page.index(containing: 3) == 1)
        #expect(page.index(containing: 5) == 2)
    }

    @Test func openingAPassageBeingTypedGivesItWholeAndMovesTheCaretOn() {
        var page = loaded(three)
        _ = page.follow("# Title\n\nOne, more.\n\nTwo, more.\n")
        #expect(page.revealing?.index == 1)
        _ = page.begin(1)
        #expect(page.editing?.draft == "One, more.")
        #expect(page.revealing?.index == 2)
    }

    // MARK: Typing

    @Test func aCommitSavesTheWholeDocumentAndItsEchoIsNotNews() {
        var page = loaded(three)
        _ = page.begin(1)
        page.edit("One, mine.")
        let effects = page.commit()
        let document = "# Title\n\nOne, mine.\n\nTwo.\n"
        #expect(effects == [.save(document)])
        page.saved(problem: nil, draft: "One, mine.")

        let echo = page.follow(document)
        #expect(echo.isEmpty)
        #expect(page.revealing == nil)
        #expect(page.editing?.index == 1, "the editor stays open through its own echo")
    }

    @Test func nothingChangedIsNothingToSave() {
        var page = loaded(three)
        _ = page.begin(1)
        #expect(page.commit().isEmpty)
    }

    @Test func theAgentWritingElsewhereLeavesTheDraftAndTheViewAlone() {
        var page = loaded(three)
        _ = page.begin(2)
        page.edit("Two, mine.")
        let effects = page.follow("# Title, theirs\n\nOne.\n\nTwo.\n")
        #expect(page.editing?.draft == "Two, mine.")
        #expect(page.editing?.index == 2)
        #expect(!effects.contains { if case .scroll = $0 { return true }; return false })
        // The file is to hold both.
        #expect(effects == [.save("# Title, theirs\n\nOne.\n\nTwo, mine.\n")])
        #expect(page.collision == nil)
    }

    @Test func theAgentWritingTheSamePassageKeepsMineAndShowsTheirs() {
        var page = loaded(three)
        _ = page.begin(1)
        page.edit("One, mine.")
        let effects = page.follow("# Title\n\nOne, theirs.\n\nTwo.\n")
        #expect(page.collision == "One, theirs.")
        #expect(effects == [.save("# Title\n\nOne, mine.\n\nTwo.\n")])

        let theirs = page.takeTheirs()
        #expect(theirs == [.save("# Title\n\nOne, theirs.\n\nTwo.\n")])
        #expect(page.collision == nil)
    }

    // MARK: A connection that drops (034)

    @Test func aFailedSaveKeepsTheDraftOpenAndUnsaved() {
        var page = loaded(three)
        _ = page.begin(1)
        page.edit("One, mine.")
        _ = page.commit()
        page.saved(problem: "Your Mac is not answering.", draft: "One, mine.")
        #expect(page.saveProblem == "Your Mac is not answering.")

        _ = page.close()
        #expect(page.editing?.draft == "One, mine.", "an unsaved draft is never closed away")
        #expect(page.editing?.isSaved == false)
    }

    @Test func aReconnectWritesADraftThatNeverLanded() {
        var page = loaded(three)
        _ = page.begin(1)
        page.edit("One, mine.")
        _ = page.commit()
        page.saved(problem: "Your Mac is not answering.", draft: "One, mine.")

        // Nothing changed on disk while away.
        let effects = page.reconnected(three)
        #expect(effects == [.save("# Title\n\nOne, mine.\n\nTwo.\n")])
    }

    @Test func aReconnectCarriesTheDraftAcrossWhatTheAgentWroteMeanwhile() {
        var page = loaded(three)
        _ = page.begin(2)
        page.edit("Two, mine.")
        _ = page.commit()
        page.saved(problem: "Your Mac is not answering.", draft: "Two, mine.")

        let effects = page.reconnected("# Title\n\nOne, theirs.\n\nTwo.\n")
        #expect(effects == [.save("# Title\n\nOne, theirs.\n\nTwo, mine.\n")])
        #expect(page.editing?.draft == "Two, mine.")
    }

    @Test func aSaveThatLandsClearsTheProblem() {
        var page = loaded(three)
        _ = page.begin(1)
        page.edit("One, mine.")
        _ = page.commit()
        page.saved(problem: "Your Mac is not answering.", draft: "One, mine.")
        _ = page.commit()
        page.saved(problem: nil, draft: "One, mine.")
        #expect(page.saveProblem == nil)
        #expect(page.editing?.isSaved == true)
        _ = page.close()
        #expect(page.editing == nil)
    }
}
