import Testing
@testable import Speakable

@Suite struct SpeakableTests {

    @Test func pathsSayTheirFileName() {
        #expect(Speakable.text("Fixed `Shared/UI/Chat/Dictation.swift:142` today")
            == "Fixed Dictation dot swift, line 142 today.")
    }

    @Test func codeBlocksAreNotRead() {
        let text = Speakable.text("Run this:\n\n```sh\nmake\nmake test\n```\nThen stop.")
        #expect(text == "Run this. A shell code block, 2 lines, is on the screen. Then stop.")
    }

    @Test func tablesSayTheirSize() {
        let text = Speakable.text("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        #expect(text == "A table with 2 rows, of A and B.")
    }

    @Test func markupAndNumbers() {
        #expect(Speakable.text("**High:** none, see PR #1802 and #1811 → done")
            == "High: none, see PR 1802 and number 1811 to done.")
    }

    @Test func linksSayWhoseTheyAre() {
        #expect(Speakable.text("The draft is at https://github.com/alexec/Agents/releases/tag/v0.8.0.")
            == "The draft is at a link on Github.")
    }

    @Test func commitsAndParityLines() {
        #expect(Speakable.text("Merged as 9dfda6049.\n\nremote: same, web: same") == "Merged as a commit.")
    }

    @Test func sentencesSplitButNotVersions() {
        #expect(Speakable.sentences("Ship 0.8.0 today. Then rest!") == ["Ship 0.8.0 today.", "Then rest!"])
    }
}
