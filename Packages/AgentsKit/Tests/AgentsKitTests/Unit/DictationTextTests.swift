import Testing
@testable import AgentsKitCore

/// #69: a short pause must never wipe out what was said before it.
@Suite("Dictation keeps every word")
struct DictationTextTests {
    @Test func aResetAfterAPauseKeepsWhatCameBefore() {
        var text = DictationText(startingWith: "")
        text.heard("Please look", final: false)
        text.heard("Please look at the files pane", final: false)
        // A breath; the recogniser starts afresh without saying the last one was final.
        let shown = text.heard("and fix the bug", final: false)
        #expect(shown == "Please look at the files pane and fix the bug")
    }

    @Test func revisionsWithinAnUtteranceReplaceRatherThanAdd() {
        var text = DictationText(startingWith: "")
        text.heard("Fix the", final: false)
        text.heard("Fix the bug", final: false)
        let shown = text.heard("Fix the bug in dictation", final: false)
        #expect(shown == "Fix the bug in dictation")
    }

    @Test func anUtteranceThatEndsWithAnErrorIsSettledNotLost() {
        var text = DictationText(startingWith: "")
        text.heard("Write the issue", final: false)
        // The recogniser gives up with an error and no transcript.
        text.heard("", final: true)
        let shown = text.heard("then start an agent", final: false)
        #expect(shown == "Write the issue\n\nthen start an agent")
    }

    @Test func aFinalUtteranceStartsAParagraph() {
        var text = DictationText(startingWith: "")
        text.heard("First thought", final: true)
        #expect(text.heard("Second thought", final: false) == "First thought\n\nSecond thought")
    }

    @Test func whatWasTypedIsKept() {
        var text = DictationText(startingWith: "Typed first.")
        #expect(text.heard("Then spoken", final: false) == "Typed first. Then spoken")
    }

    @Test func aShortStartThatIsRevisedIsNotDoubled() {
        var text = DictationText(startingWith: "")
        text.heard("Hello", final: false)
        #expect(text.heard("Hello world", final: false) == "Hello world")
    }

    @Test func aShortStartFollowedByNewWordsIsKept() {
        var text = DictationText(startingWith: "")
        text.heard("Okay", final: false)
        #expect(text.heard("now the next part", final: false) == "Okay now the next part")
    }

    @Test func manyPausesKeepEverySentence() {
        var text = DictationText(startingWith: "")
        for sentence in ["one two three four", "five six seven", "eight nine ten eleven"] {
            var words: [Substring] = []
            for word in sentence.split(separator: " ") {
                words.append(word)
                text.heard(words.joined(separator: " "), final: false)
            }
        }
        #expect(text.shown == "one two three four five six seven eight nine ten eleven")
    }
}
