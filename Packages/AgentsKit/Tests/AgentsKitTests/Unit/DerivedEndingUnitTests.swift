import Foundation
import Testing
@testable import AgentsKitCore

/// The words the app puts on a row for an ending the agent did not account for (#479).
@Suite("Deriving an ending's outcome, sentence and title")
struct DerivedEndingUnitTests {
    private let at = Date(timeIntervalSince1970: 0)

    @Test func theFirstSentenceOfTheClosingWordsIsTheMessage() {
        let report = DerivedEnding.report(closingWords: "Login works again. The fix is on its branch.",
                                          questionOpen: false, at: at)
        #expect(report.outcome == .done)
        #expect(report.message == "Login works again.")
    }

    @Test func markdownIsTakenOffAndCodeSkipped() {
        #expect(DerivedEnding.firstSentence(of: "## Summary\n\n**Done** — renamed `foo`.") == "Summary")
        #expect(DerivedEnding.firstSentence(of: "```\nlet x = 1.\n```\n- Fixed it. More.") == "Fixed it.")
        #expect(DerivedEnding.firstSentence(of: "1. First step done. Next.") == "First step done.")
        // Not cut at a version number or a path.
        #expect(DerivedEnding.firstSentence(of: "Bumped to 1.5 in Package.swift today.")
                == "Bumped to 1.5 in Package.swift today.")
    }

    @Test func aLongSentenceIsCutToOneLineAtAWord() {
        let long = String(repeating: "word ", count: 60) + "end."
        let message = DerivedEnding.report(closingWords: long, questionOpen: false, at: at).message
        #expect(message.count <= DerivedEnding.summaryLimit)
        #expect(message.hasSuffix("…"))
        #expect(!message.contains("wor…"))
    }

    @Test func aQuestionAtTheEndIsWaitingOnAnAnswer() {
        let report = DerivedEnding.report(closingWords: "Two ways to go. Shall I keep the alias?",
                                          questionOpen: false, at: at)
        #expect(report.outcome == .needsAnswer)
        #expect(report.message == "Shall I keep the alias?")
    }

    @Test func anOpenCardIsWaitingOnAnAnswerWhateverWasSaid() {
        let report = DerivedEnding.report(closingWords: "Asked on the card.", questionOpen: true, at: at)
        #expect(report.outcome == .needsAnswer)
        #expect(report.message == "Asked on the card.")
        #expect(DerivedEnding.report(closingWords: nil, questionOpen: true, at: at).message
                == WorkOutcome.needsAnswer.heading)
    }

    @Test func nothingSaidIsStillAMessage() {
        #expect(DerivedEnding.report(closingWords: nil, questionOpen: false, at: at).message == DerivedEnding.silentDone)
        #expect(DerivedEnding.report(closingWords: "  \n", questionOpen: false, at: at).message == DerivedEnding.silentDone)
    }

    @Test func aTitleIsTheFirstFewWordsOfThePrompt() {
        #expect(DerivedEnding.title(fromPrompt: "Fix the login redirect") == "Fix the login redirect")
        #expect(DerivedEnding.title(fromPrompt: "Make the turn ending optional and work it out instead")
                == "Make the turn ending optional and work it…")
        #expect(DerivedEnding.title(fromPrompt: "# Plan\nmore") == "Plan")
        #expect(DerivedEnding.title(fromPrompt: "   ") == nil)
    }
}
