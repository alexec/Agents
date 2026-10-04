import Foundation
import Testing
@testable import AgentsKitCore

/// Finding a session in the caller's project by id or exact title, and listing them
/// (065, FR-001, FR-004, FR-005). Every refusal is checked for its words, because the
/// agent that asked reads them.
@Suite("Finding a session in this project")
struct SessionLookupTests {
    private let project = Project.standardize(URL(filePath: "/work/api"))
    private let other = Project.standardize(URL(filePath: "/work/web"))
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func agent(_ title: String?, in folder: URL? = nil, minutesAgo: Double = 0,
                       state: AgentState = .finished, runtime: String = "claude",
                       id: UUID = UUID()) -> Agent {
        Agent(id: id, runtimeID: runtime, cwd: folder ?? project, title: title, state: state,
              lastActivityAt: start.addingTimeInterval(-minutesAgo * 60))
    }

    private func find(_ value: String, _ agents: [Agent], retired: [Tombstone] = []) -> SessionLookup.Found {
        SessionLookup.find(value, in: project, agents: agents, retired: retired)
    }

    private func refusal(_ found: SessionLookup.Found) -> String? {
        if case .refused(let sentence) = found { return sentence }
        return nil
    }

    private func session(_ found: SessionLookup.Found) -> UUID? {
        if case .session(let agent) = found { return agent.id }
        return nil
    }

    // MARK: Finding

    @Test func anIdIsFoundBeforeATitle() {
        let named = agent("Login redirect")
        // A session titled with the other's id: the id still means the session.
        let impostor = agent(named.id.uuidString)
        #expect(session(find(named.id.uuidString, [impostor, named])) == named.id)
    }

    @Test func anExactTitleIsFoundAfterTrimming() {
        let named = agent("Login redirect")
        #expect(session(find("  Login redirect\n", [agent("Other"), named])) == named.id)
    }

    @Test func aTitleIsMatchedExactlyAndCaseSensitively() {
        let named = agent("Login redirect")
        #expect(refusal(find("login redirect", [named]))
                == "There is no session named \u{201C}login redirect\u{201D} in this project.")
        #expect(refusal(find("Login", [named])) != nil)
    }

    @Test func untitledIsNotATitle() {
        #expect(refusal(find("Untitled", [agent(nil)])) != nil)
    }

    @Test func anEmptyValueIsRefused() {
        #expect(refusal(find("  ", [agent("A")])) == "Give a session id or exact title.")
    }

    @Test func aTitleUsedTwiceIsRefusedWithEachMatch() {
        let older = agent("Fix tests", minutesAgo: 60, runtime: "codex")
        let newer = agent("Fix tests", minutesAgo: 5)
        let sentence = refusal(find("Fix tests", [older, newer])) ?? ""
        #expect(sentence.hasPrefix("More than one session is named \u{201C}Fix tests\u{201D}: "))
        #expect(sentence.hasSuffix(". Read one by id."))
        #expect(sentence.contains("\(older.id.uuidString) — Codex, "))
        #expect(sentence.contains("\(newer.id.uuidString) — Claude, "))
        // Newest first, as the list is.
        let first = sentence.range(of: newer.id.uuidString)!.lowerBound
        #expect(first < sentence.range(of: older.id.uuidString)!.lowerBound)
    }

    @Test func anArchivedSessionIsStillFound() {
        let archived = agent("Old work", state: .archived)
        #expect(session(find("Old work", [archived])) == archived.id)
    }

    @Test func aRetiredSessionIsGoneByIdAndByTitle() {
        let old = agent("Retired work", state: .archived)
        let tombstone = Tombstone(from: old, retiredAt: start, because: .age)
        #expect(refusal(find(old.id.uuidString, [], retired: [tombstone])) == "That conversation is gone.")
        #expect(refusal(find("Retired work", [], retired: [tombstone])) == "That conversation is gone.")
    }

    @Test func aLiveSessionWinsOverARetiredOneOfTheSameTitle() {
        let old = Tombstone(from: agent("Same", state: .archived), retiredAt: start, because: .age)
        let live = agent("Same")
        #expect(session(find("Same", [live], retired: [old])) == live.id)
    }

    @Test func anotherProjectsSessionIsNotThereById() {
        let elsewhere = agent("Theirs", in: other)
        let sentence = refusal(find(elsewhere.id.uuidString, [elsewhere]))
        #expect(sentence == "There is no session named \u{201C}\(elsewhere.id.uuidString)\u{201D} in this project.")
    }

    @Test func anotherProjectsSessionIsNotThereByTitle() {
        #expect(refusal(find("Theirs", [agent("Theirs", in: other)])) != nil)
    }

    @Test func anotherProjectsRetiredSessionIsNotSaidToBeGone() {
        let tombstone = Tombstone(from: agent("Theirs", in: other, state: .archived), retiredAt: start, because: .age)
        #expect(refusal(find("Theirs", [], retired: [tombstone]))
                == "There is no session named \u{201C}Theirs\u{201D} in this project.")
    }

    @Test func aSessionInAWorktreeBelongsToItsProject() {
        var inWorktree = agent("In a worktree", in: URL(filePath: "/work/.worktrees/fix"))
        inWorktree.worktree = AgentWorktree(name: "fix", root: URL(filePath: "/work/.worktrees/fix"),
                                            branch: "agents/fix", project: project,
                                            base: nil, madeByApp: true)
        #expect(session(find("In a worktree", [inWorktree])) == inWorktree.id)
    }

    // MARK: Listing

    @Test func listIncludesValuesAndOwners() {
        var labeled = agent("Review")
        labeled.labels = [SessionLabel(value: "Urgent", owner: .person),
                          SessionLabel(value: "Build", owner: .agent)]
        let text = SessionLookup.list(in: project, agents: [labeled], caller: nil)
        #expect(text.contains("Urgent (person), Build (agent)"))
    }

    @Test func theListIsThisProjectsSessionsNewestFirst() {
        let a = agent("Alpha", minutesAgo: 30)
        let b = agent("Beta", minutesAgo: 1)
        let c = agent("Gamma", in: other)
        let d = agent("Delta", minutesAgo: 10, state: .archived)
        #expect(SessionLookup.sessions(in: project, agents: [a, b, c, d]).map(\.id) == [b.id, d.id, a.id])
    }

    @Test func tiesAreBrokenByIdAscending() {
        let low = agent("Low", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = agent("High", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(SessionLookup.sessions(in: project, agents: [high, low]).map(\.id) == [low.id, high.id])
    }

    @Test func eachListedSessionHasItsIdTitleRuntimeStatusAndWhatItLastSaid() {
        var said = agent("Login redirect")
        said.report = WorkReport(outcome: .done, message: "Fixed and tested.", at: start)
        let quiet = agent(nil, minutesAgo: 5, state: .running, runtime: "codex")
        let text = SessionLookup.list(in: project, agents: [said, quiet], caller: quiet.id)
        #expect(text.contains("\(said.id.uuidString): \u{201C}Login redirect\u{201D} — Claude, Done"))
        #expect(text.contains("Last said: Fixed and tested."))
        #expect(text.contains("\(quiet.id.uuidString): Untitled (you) — Codex, Working"))
        #expect(text.components(separatedBy: "Last said:").count == 2)
    }

    /// The clean-up workflow (#199) ties a worktree to its session, and leaves one whose
    /// session holds a lease alone, from these two.
    @Test func eachListedSessionSaysItsWorktreeAndWhatItHolds() {
        var built = agent("Build it", in: URL(filePath: "/work/api/.agents/worktrees/build-it"))
        built.worktree = AgentWorktree(name: "build-it", root: URL(filePath: "/work/api/.agents/worktrees/build-it"),
                                       branch: "agents/build-it", project: project, base: "main", madeByApp: true)
        let plain = agent("In the folder", minutesAgo: 5)
        let text = SessionLookup.list(in: project, agents: [built, plain], caller: nil,
                                      holding: [built.id: ["build", "screen"]])
        #expect(text.contains("Worktree: /work/api/.agents/worktrees/build-it on agents/build-it. Holding: build, screen."))
        let plainLine = text.split(separator: "\n").first { $0.contains(plain.id.uuidString) } ?? ""
        #expect(!plainLine.contains("Worktree:"))
        #expect(!plainLine.contains("Holding:"))
    }

    @Test func aSpentAllowanceIsSaidInTheStatus() {
        let spent = Agent(runtimeID: "claude", cwd: project, title: "Ran out", state: .stopped,
                          endedReason: .allowanceSpent)
        #expect(SessionLookup.status(of: spent).hasSuffix(": Its allowance ran out"))
    }
}
