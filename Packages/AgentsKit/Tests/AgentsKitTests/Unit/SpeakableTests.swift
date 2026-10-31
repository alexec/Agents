import Testing
@testable import AgentsKitCore

/// #2322: what voice mode says for a reply. The rules are the #1792 spike's, and the three
/// it left to do: clock times, versions and camel case outside backticks.
@Suite("A reply is said as a person says it")
struct SpeakableTests {
    @Test func pathsSayTheirFileName() {
        #expect(Speakable.text("Fixed `Shared/UI/Chat/Dictation.swift:142` today")
            == "Fixed Dictation dot swift, line 142 today.")
        #expect(Speakable.text("See /Users/me/work/notes.md for it") == "See notes dot md for it.")
    }

    @Test func codeIsNamedNotRead() {
        #expect(Speakable.text("Run `DictationTests.testStartTwice` again") == "Run Dictation Tests test Start Twice again.")
        #expect(Speakable.text("Then run `scripts/lint.sh --fix` once") == "Then run a command once.")
    }

    @Test func codeBlocksAreNotRead() {
        #expect(Speakable.text("Run this:\n\n```sh\nmake\nmake test\n```\nThen stop.")
            == "Run this. A shell code block, 2 lines, is on the screen. Then stop.")
        #expect(Speakable.text("Here:\n```\nlet a = 1") == "Here. A code block, 1 line, is on the screen.")
    }

    @Test func tablesSayTheirSize() {
        #expect(Speakable.text("| **A** | B |\n|:---|---:|\n| 1 | 2 |\n| 3 | 4 |")
            == "A table with 2 rows, of A and B, is on the screen.")
    }

    @Test func markupAndNumbers() {
        #expect(Speakable.text("**High:** none, see PR #1802 and #1811 → done")
            == "High: none, see PR 1802 and number 1811 to done.")
        #expect(Speakable.text("- [x] Tests pass") == "Tests pass.")
    }

    @Test func linksSayWhoseTheyAre() {
        #expect(Speakable.text("The draft is at https://github.com/alexec/Agents/releases/tag/v0.8.0.")
            == "The draft is at a link on Github.")
        #expect(Speakable.text("Read [the report](specs/r.md) first.") == "Read the report first.")
    }

    @Test func commitsAndParityLines() {
        #expect(Speakable.text("Merged as 9dfda6049.\n\nremote: same, web: same") == "Merged as a commit.")
        #expect(Speakable.text("It took 1234567 tries.") == "It took 1234567 tries.")
    }

    @Test func unitsAreWords() {
        #expect(Speakable.text("First sound in 45 ms, the build in 30 s and 1 min") ==
            "First sound in 45 milliseconds, the build in 30 seconds and 1 minute.")
        #expect(Speakable.text("It adds 24 MB.") == "It adds 24 megabytes.")
    }

    @Test func clockTimesAreTimes() {
        #expect(Speakable.text("It failed at 10:42:07.") == "It failed at 10 42.")
        #expect(Speakable.text("Back at 9:05 or 14:00.") == "Back at 9 oh 5 or 14 hundred.")
    }

    @Test func versionsAreVersions() {
        #expect(Speakable.text("Shipped v0.8.0 and 0.9.1.") == "Shipped version 0 point 8 point 0 and 0 point 9 point 1.")
        #expect(Speakable.text("Ship 0.8.0 today. Then rest!") == "Ship 0 point 8 point 0 today. Then rest!")
        #expect(Speakable.text("It is 0.5 faster.") == "It is 0.5 faster.")
    }

    @Test func camelCaseIsWords() {
        #expect(Speakable.text("Set wordsPerMinute to 150.") == "Set words Per Minute to 150.")
        #expect(Speakable.text("On GitHub, the iPhone and macOS.") == "On GitHub, the iPhone and macOS.")
    }

    @Test func sentencesSplitButNotAbbreviations() {
        #expect(Speakable.sentences("Use a cache, e.g. this one. Then rest!") == ["Use a cache, e.g. this one.", "Then rest!"])
    }

    @Test func aLongReplyIsSpokenInFull() {
        let sentence = "This sentence has exactly ten words in it, you see."
        let reply = Array(repeating: sentence, count: 8).joined(separator: " ")
        #expect(Speakable.spoken(reply) == Array(repeating: sentence, count: 8))
        #expect(Speakable.spoken("Done. All tests pass.") == ["Done.", "All tests pass."])
    }
}

/// #2429: streaming is bounded until #2534's full final reply is known.
@Suite("A long reply is fully spoken when complete")
struct SpeakableBoundTests {
    private static let long: String = (0..<200)
        .map { "Line \($0) changes `Sources/File\($0).swift` for issue #\($0), and it is fine." }
        .joined(separator: "\n")

    @Test func aLimitGivesTheFirstSentencesAsWithout() {
        let all = Speakable.sentences(Self.long)
        #expect(Speakable.sentences(Self.long, limit: 4) == Array(all.prefix(4)))
        #expect(Speakable.sentences("One. Two.", limit: 4) == ["One.", "Two."])
    }

    @Test func spokenIsTheSameAsCleaningTheFullReply() {
        let all = Speakable.sentences(Self.long)
        #expect(Speakable.spoken(Self.long) == all)
        let short = "It works. The tests pass."
        #expect(Speakable.spoken(short) == ["It works.", "The tests pass."])
        // Many short sentences, under 60 words: all said.
        let few = (1...10).map { "Done \($0)." }.joined(separator: " ")
        #expect(Speakable.spoken(few).count == 10)
    }

    /// Code blocks remain a short spoken description, even in a full reply.
    @Test func codeBlocksStayOnTheScreen() {
        let reply = "```swift\nlet a = 1\n```\n" + Self.long
        #expect(Speakable.spoken(reply).first == "A Swift code block, 1 line, is on the screen.")
        #expect(Speakable.spoken(reply).count == Speakable.sentences(reply).count)
    }
}
