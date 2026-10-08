import Testing
@testable import AgentsKitCore

/// #69: a pause never wipes out what was said before it. #427: dictation writes at the
/// cursor, replaces only the words it is still hearing, and never what was typed.
@Suite("Dictation keeps every word")
struct DictationTextTests {
    // MARK: Heard

    @Test func revisionsReplaceTheWordsBeingHeard() {
        var text = DictationText("")
        text.heard("Fix the", final: false, from: 0)
        text.heard("Fix the bug", final: false, from: 0)
        text.heard("Fix the bug in dictation", final: false, from: 0)
        #expect(text.text == "Fix the bug in dictation")
        #expect(text.isHearing)
        #expect(text.provisional == 0..<24)
    }

    @Test func aPauseKeepsWhatCameBefore() {
        var text = DictationText("")
        text.heard("Please look at the files pane.", final: true, from: 0)
        text.heard("And fix", final: false, from: 3)
        text.heard("And fix the bug.", final: true, from: 3)
        #expect(text.text == "Please look at the files pane. And fix the bug.")
        #expect(!text.isHearing)
    }

    @Test func manyPausesKeepEverySentence() {
        var text = DictationText("")
        var start = 0.0
        for sentence in ["One two three four.", "Five six seven.", "Eight nine ten eleven."] {
            var words: [Substring] = []
            for word in sentence.split(separator: " ") {
                words.append(word)
                text.heard(words.joined(separator: " "), final: false, from: start)
            }
            text.heard(sentence, final: true, from: start)
            start += 2
        }
        #expect(text.text == "One two three four. Five six seven. Eight nine ten eleven.")
    }

    @Test func whatWasTypedIsKept() {
        var text = DictationText("Typed first.")
        text.heard("Then spoken.", final: false, from: 0)
        #expect(text.text == "Typed first. Then spoken.")
        #expect(text.selection == 25..<25)
    }

    @Test func emptyResultsTakeBackOnlyHeardWords() {
        var text = DictationText("Keep this", selection: 5..<9)
        text.heard("", final: true, from: 0)
        #expect(text.text == "Keep this")
        text.heard("that", final: false, from: 1)
        text.heard("", final: false, from: 1)
        #expect(text.text == "Keep ")
    }

    // MARK: At the cursor

    @Test func wordsGoAtTheCursorNotTheEnd() {
        var text = DictationText("Fix the bug. Then ship it.", selection: 12..<12)
        text.heard("Add a test.", final: true, from: 0)
        #expect(text.text == "Fix the bug. Add a test. Then ship it.")
        // The cursor sits after the words, before the space that keeps them apart.
        #expect(text.selection == 24..<24)
    }

    @Test func aSelectionIsSpokenOver() {
        var text = DictationText("Fix the bug quickly", selection: 8..<11)
        text.heard("crash", final: false, from: 0)
        #expect(text.text == "Fix the crash quickly")
    }

    @Test func noSpaceBeforePunctuation() {
        var text = DictationText("Hello")
        text.heard(", world", final: true, from: 0)
        #expect(text.text == "Hello, world")
    }

    // MARK: Edits while listening

    @Test func anEditBeforeTheHeardWordsMovesThemAlong() {
        var text = DictationText("Typed.")
        text.heard("Spoken", final: false, from: 0)
        #expect(text.text == "Typed. Spoken")
        // The person deletes "Typed." while still talking.
        text.edited(to: " Spoken")
        text.heard("Spoken words", final: false, from: 0)
        // The space was dictation's, put there to keep the words apart from the typing.
        #expect(text.text == "Spoken words")
        text.edited(to: "Hi Spoken words")
        text.heard("Spoken words here.", final: true, from: 0)
        #expect(text.text == "Hi Spoken words here.")
    }

    @Test func anEditAfterTheHeardWordsIsLeftAlone() {
        var text = DictationText("End", selection: 0..<0)
        text.heard("Start", final: false, from: 0)
        #expect(text.text == "Start End")
        text.edited(to: "Start End!")
        text.heard("Start here", final: true, from: 0)
        #expect(text.text == "Start here End!")
    }

    @Test func anEditInsideTheHeardWordsMakesThemTheirs() {
        var text = DictationText("")
        text.heard("Fix the bag", final: false, from: 0)
        // The person corrects the word themselves.
        text.edited(to: "Fix the bug")
        #expect(!text.isHearing)
        #expect(text.isDroppingAdoptedSpeech)
        // The recogniser's later takes on the same speech would undo that.
        let revised = text.heard("Fix the bag in", final: false, from: 0)
        let settled = text.heard("Fix the bag in it.", final: true, from: 0)
        #expect(!revised && !settled)
        #expect(text.text == "Fix the bug")
        // New speech goes where the person puts the cursor next.
        text.selected(11..<11)
        text.heard("Then test.", final: false, from: 4)
        #expect(text.text == "Fix the bug Then test.")
        #expect(!text.isDroppingAdoptedSpeech)
    }

    @Test func typingAtTheCursorIsNeverOverwritten() {
        var text = DictationText("")
        text.heard("First sentence.", final: true, from: 0)
        // Between sentences the person types a word of their own.
        text.edited(to: "First sentence. Typed")
        text.selected(21..<21)
        text.heard("spoken", final: false, from: 2)
        text.heard("spoken words.", final: true, from: 2)
        #expect(text.text == "First sentence. Typed spoken words.")
    }

    @Test func clickingElsewhereLetsTheHeardWordsSettleThenMovesOn() {
        var text = DictationText("Alpha. Omega.")
        text.heard("Middle", final: false, from: 0)
        #expect(text.text == "Alpha. Omega. Middle")
        // The person clicks after "Alpha." while those words are still being heard.
        text.selected(6..<6)
        #expect(text.selection == 6..<6)
        text.heard("Middle bit.", final: true, from: 0)
        #expect(text.text == "Alpha. Omega. Middle bit.")
        text.heard("Beta.", final: true, from: 2)
        #expect(text.text == "Alpha. Beta. Omega. Middle bit.")
    }

    @Test func clickingIntoTheHeardWordsStopsThemChanging() {
        var text = DictationText("")
        text.heard("Fix the bag", final: false, from: 0)
        text.selected(8..<11)
        #expect(!text.isHearing)
        text.edited(to: "Fix the bug")
        text.heard("Fix the bag now.", final: true, from: 0)
        #expect(text.text == "Fix the bug")
    }

    @Test func deletingBackToTheCursorKeepsItThere() {
        var text = DictationText("One two three", selection: 7..<7)
        // Backspace over "two" while dictation waits at the cursor.
        text.edited(to: "One  three")
        text.selected(4..<4)
        text.heard("four", final: true, from: 0)
        #expect(text.text == "One four three")
    }

    @Test func theFieldsOwnSelectionIsNotAMove() {
        var text = DictationText("")
        text.heard("Hello there", final: false, from: 0)
        text.selected(text.selection)
        #expect(text.isHearing)
        text.heard("Hello there friend.", final: true, from: 0)
        #expect(text.text == "Hello there friend.")
    }

    // MARK: Marked as tentative (#448)

    @Test func onlyTheWordsBeingHeardAreMarked() {
        var text = DictationText("Look at", selection: 7..<7)
        #expect(text.heardWords == nil)
        text.heard("the files", final: false, from: 0)
        // Not the space put before them, and not what was typed.
        #expect(text.text == "Look at the files")
        #expect(text.heardWords == 8..<17)
        text.heard("the files pane.", final: true, from: 0)
        #expect(text.heardWords == nil)
    }

    @Test func theSpaceAfterTheHeardWordsIsNotMarked() {
        var text = DictationText("Fix bug", selection: 4..<4)
        text.heard("the", final: false, from: 0)
        #expect(text.text == "Fix the bug")
        #expect(text.heardWords == 4..<7)
    }

    @Test func wordsTheyEditAreNoLongerMarked() {
        var text = DictationText("")
        text.heard("Hello there", final: false, from: 0)
        text.edited(to: "Hello")
        #expect(text.heardWords == nil)
    }
}
