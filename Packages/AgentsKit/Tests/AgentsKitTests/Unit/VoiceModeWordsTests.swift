import Testing
@testable import AgentsKitCore

/// What voice mode says when something does not go (the usability check of 2026-10-22b).
@Suite("Voice mode says what did not go")
struct VoiceModeWordsTests {
    /// #2441: a prompt the host did not take keeps its words on the screen.
    @Test func anUnsentPromptKeepsItsWords() {
        #expect(VoiceModeWords.notSent == "Not sent. Say it again.")
        #expect(VoiceModeWords.unsent("Fix the bug") == "Not sent: “Fix the bug”. Say it again.")
    }

    /// #2442: an answer by voice that did not go says where it is.
    @Test func anAnswerThatDidNotGoSaysItIsOnTheScreen() {
        #expect(VoiceModeWords.answerNotSent == "The answer did not go. It is on the screen.")
    }
}
