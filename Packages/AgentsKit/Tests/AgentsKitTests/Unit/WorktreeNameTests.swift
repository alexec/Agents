import Foundation
import Testing
@testable import AgentsKitCore

/// What a new worktree is called, taken from the prompt that starts its agent (030, R3).
@Suite("A worktree's name, from the prompt")
struct WorktreeNameTests {
    @Test func theFirstFewWordsThatSayWhatToDo() {
        #expect(WorktreeName.from(prompt: "Fix the login redirect on Safari") == "fix-login-redirect-safari")
    }

    @Test func politenessAndLittleWordsAreLeftOut() {
        #expect(WorktreeName.from(prompt: "Please can you add tests for the parser?") == "add-tests-parser")
    }

    @Test func onlyFourWords() {
        #expect(WorktreeName.from(prompt: "rename every model class to singular nouns now") == "rename-every-model-class")
    }

    @Test func accentsAreFoldedAndOnlyLettersAndDigitsKept() {
        #expect(WorktreeName.from(prompt: "Café menu: v2 — ship it!") == "cafe-menu-v2-ship")
    }

    @Test func neverLongerThanThirtyTwoAndNeverEndsInAHyphen() {
        let name = WorktreeName.from(prompt: "internationalisation localisation documentation refactoring")
        #expect(name.count <= WorktreeName.maxLength)
        #expect(!name.hasSuffix("-"))
        #expect(name == "internationalisation")

        let oneLongWord = WorktreeName.from(prompt: String(repeating: "a", count: 50))
        #expect(oneLongWord == String(repeating: "a", count: 32))
    }

    @Test func aPromptWithNoWordsIsNamedForWhenItStarted() throws {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 24; parts.hour = 17; parts.minute = 5
        let when = try #require(Calendar.current.date(from: parts))
        #expect(WorktreeName.from(prompt: "🙂 !!", now: when) == "agent-0924-1705")
        #expect(WorktreeName.from(prompt: "", now: when) == "agent-0924-1705")
        #expect(WorktreeName.from(prompt: "the a of", now: when) == "agent-0924-1705")
    }

    @Test func aNameInUseGetsTheNextFreeNumber() {
        #expect(WorktreeName.next(after: "x", taken: []) == "x")
        #expect(WorktreeName.next(after: "x", taken: ["x"]) == "x-2")
        #expect(WorktreeName.next(after: "x", taken: ["x", "x-2"]) == "x-3")
    }

    @Test func theBranchIsTheNameUnderAgents() {
        #expect(WorktreeName.branch(for: "fix-login") == "agents/fix-login")
    }

    @Test func aBranchsFolderHasNoSlashes() {
        #expect(WorktreeName.folder(forBranch: "feature/login") == "feature-login")
        #expect(WorktreeName.folder(forBranch: "agents/fix-it") == "fix-it")
        #expect(WorktreeName.folder(forBranch: "fix//two  gaps") == "fix-two-gaps")
        #expect(WorktreeName.folder(forBranch: "/") == "branch")
    }
}
