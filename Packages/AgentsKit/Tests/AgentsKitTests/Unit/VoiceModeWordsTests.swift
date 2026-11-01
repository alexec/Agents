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

    /// #2444: dictation's problem is said as voice mode's, in voice mode's alert.
    @Test func dictationsProblemIsVoiceModes() {
        #expect(VoiceModeWords.problem(dictation: "Dictation needs the microphone. Turn it on in Settings, under this app.")
            == "Voice mode needs the microphone. Turn it on in Settings, under this app.")
        #expect(VoiceModeWords.problem(dictation: "The microphone would not start: busy")
            == "The microphone would not start: busy")
    }

    /// #2443: while an answer waits for a "no", the strip says what goes.
    @Test func theStripSaysWhatIsAboutToGo() {
        #expect(VoiceModeWords.sayNoToStop("Sending File") == "Sending File. Say no to stop.")
    }

    /// #2446: VoiceOver's own words, heard through the microphone, are not a prompt.
    @Test func voiceOversWordsAreNotAPrompt() {
        #expect(VoiceModeWords.isEcho("voice mode is on", of: "Voice mode is on. Say what you want."))
        #expect(VoiceModeWords.isEcho("Say what you want", of: "Voice mode is on. Say what you want."))
        #expect(!VoiceModeWords.isEcho("Fix the bug", of: "Voice mode is on. Say what you want."))
        #expect(!VoiceModeWords.isEcho("", of: "Voice mode is on."))
    }

    /// #3163: words heard while a prompt was sent are the words after it, also when the
    /// recognizer revised it meanwhile; the prompt itself is never heard again.
    @Test func wordsHeardWhileSendingAreOnlyTheNewOnes() {
        #expect(VoiceModeWords.heard(after: "fix the bug", in: "fix the bug") == "")
        #expect(VoiceModeWords.heard(after: "fix the bug", in: "fix the bug and add a test") == "and add a test")
        #expect(VoiceModeWords.heard(after: "fix the bug", in: "Fix the bug. And add a test") == "And add a test")
        #expect(VoiceModeWords.heard(after: "fix the cafe", in: "Fix the café, then push") == "then push")
        #expect(VoiceModeWords.heard(after: "fix the bug", in: "Fix the bugs") == "")
        #expect(VoiceModeWords.heard(after: "fix the bug", in: "Fix that bug and push") == "and push")
        #expect(VoiceModeWords.heard(after: "", in: "and push") == "and push")
        #expect(VoiceModeWords.heard(after: "fix the bug", in: "fix") == "")
    }
}
