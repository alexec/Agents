import Foundation
import Testing
@testable import AgentsKitCore

/// What `read_session` hands another agent (065, US1 and US3): the app's record of a
/// session as text, whole when it fits and shortened from the middle when it does not.
@Suite("A session's history as another agent reads it")
struct SessionHistoryTests {
    private let header = SessionHistory.Header(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        title: "Login redirect", runtime: "Claude", status: "Done",
        folder: "/work/api", worktree: nil)

    private func person(_ text: String) -> TranscriptEntry { .init(kind: .userMessage(text)) }
    private func app(_ text: String) -> TranscriptEntry { .init(kind: .userMessage(text, from: .app)) }
    private func reply(_ text: String) -> TranscriptEntry { .init(kind: .agentMessage(messageID: nil, text: text)) }
    private func tool(_ title: String, name: String? = nil, path: String? = nil) -> TranscriptEntry {
        .init(kind: .toolCall(ToolCall(title: title, name: name,
                                       locations: path.map { [ToolCallLocation(path: $0)] } ?? [])))
    }
    private func plan(_ items: [(String, PlanEntry.Status)]) -> TranscriptEntry {
        .init(kind: .planUpdated(Plan(entries: items.map { PlanEntry(content: $0.0, status: $0.1) })))
    }

    private func render(_ entries: [TranscriptEntry], budget: Int = SessionHistory.budget) -> SessionHistory.Document {
        SessionHistory.document(header: header, entries: entries, budget: budget)
    }

    // MARK: Whole

    @Test func aShortSessionIsGivenWholeWithItsRequestRepliesToolsAndPlan() {
        let document = render([
            person("Fix the login redirect"),
            reply("Looking at the router."),
            tool("Edit router.swift", path: "/work/api/Sources/router.swift"),
            plan([("Find the redirect", .completed), ("Add a test", .pending)]),
            person("Now add a test"),
            reply("Added one."),
        ])
        let text = document.markdown
        #expect(document.leftOut == nil)
        #expect(text.contains("**The person:** Fix the login redirect"))
        #expect(text.contains("**Claude:** Looking at the router."))
        #expect(text.contains("Edit router.swift (`/work/api/Sources/router.swift`)"))
        #expect(text.contains("**The person:** Now add a test"))
        #expect(text.contains("**Claude:** Added one."))
        #expect(text.contains("- [x] Find the redirect"))
        #expect(text.contains("- [ ] Add a test"))
        #expect(!text.contains("left out"))
    }

    @Test func theHeaderNamesTheSessionAndSaysReadingDidNotChangeIt() {
        let text = render([person("Hello")]).markdown
        #expect(text.hasPrefix("# Session \u{201C}Login redirect\u{201D}"))
        #expect(text.contains("11111111-2222-3333-4444-555555555555"))
        #expect(text.contains("Runtime: Claude"))
        #expect(text.contains("Status: Done"))
        #expect(text.contains("Working folder: `/work/api`"))
        #expect(text.contains("Reading it did not change it."))
        #expect(!text.contains("carried over"))
    }

    @Test func anUntitledSessionIsCalledUntitledAndAWorktreeIsNamed() {
        var untitled = header
        untitled.title = nil
        untitled.worktree = .init(name: "fix-login", branch: "agents/fix-login")
        let text = SessionHistory.document(header: untitled, entries: [person("Hi")]).markdown
        #expect(text.hasPrefix("# Session Untitled"))
        #expect(text.contains("Worktree: fix-login, on branch `agents/fix-login`"))
    }

    @Test func anAppPromptIsLabelledAsTheApps() {
        let text = render([person("Do it"), app("Say how the work went.")]).markdown
        #expect(text.contains("**The app:** Say how the work went."))
    }

    @Test func theAppsOwnToolsThoughtsUsageAndPermissionsAreLeftOut() {
        let text = render([
            person("Go"),
            .init(kind: .agentThought(messageID: nil, text: "private musing")),
            tool("finish_turn", name: "mcp__agents__finish_turn"),
            tool("mcp__agents__show_file", name: "mcp__agents__show_file"),
            .init(kind: .permissionAsked(PermissionRequest(agentID: UUID(), toolCall: ToolCall(title: "Run rm"),
                                                           options: []))),
            .init(kind: .permissionAnswered(optionID: "allow", optionName: "Allow")),
            .init(kind: .runtimeNote("Runtime starting")),
            tool("Read notes.md", path: "/work/api/notes.md"),
        ]).markdown
        #expect(!text.contains("private musing"))
        #expect(!text.contains("finish_turn"))
        #expect(!text.contains("show_file"))
        #expect(!text.contains("Run rm"))
        #expect(!text.contains("Runtime starting"))
        #expect(text.contains("Read notes.md (`/work/api/notes.md`)"))
    }

    @Test func theLastPlanIsTheOneGivenAndAWithdrawnPlanIsNone() {
        let later = render([person("Go"), plan([("Old step", .pending)]), plan([("New step", .inProgress)])]).markdown
        #expect(later.contains("New step"))
        #expect(!later.contains("Old step"))

        let withdrawn = render([person("Go"), plan([("Step", .pending)]),
                                .init(kind: .planUpdated(Plan(entries: [PlanEntry(content: "Step")], state: .withdrawn)))])
        #expect(!withdrawn.markdown.contains("## The plan"))
    }

    @Test func anInFlightSessionIsWhatHasBeenRecordedSoFar() {
        let text = render([person("Start the migration"), reply("Running it now"),
                           tool("Run swift build")]).markdown
        #expect(text.contains("Start the migration"))
        #expect(text.contains("Run swift build"))
    }

    @Test func aSessionWithNothingSaidSaysSo() {
        #expect(render([]).markdown.contains("Nothing has been said in this session yet."))
    }

    @Test func whatTheAgentSaidOfHowTheWorkWentIsKept() {
        let report = WorkReport(outcome: .done, message: "Redirect fixed and tested.", at: Date())
        let text = render([person("Go"), .init(kind: .workReported(report))]).markdown
        #expect(text.contains("Redirect fixed and tested."))
    }

    // MARK: As a real runtime writes it

    /// The shape Claude's record had in the 2026-09-29 walk: a reply in chunks sharing a
    /// message id, and a tool call whose title and file arrive in later updates, then a
    /// completion that calls it only "Tool call".
    @Test func chunksAreOneReplyAndUpdatesGiveTheCallItsTitleAndFile() {
        func chunk(_ text: String) -> TranscriptEntry { .init(kind: .agentMessage(messageID: "msg_1", text: text)) }
        func update(_ title: String, path: String? = nil, status: String? = nil) -> TranscriptEntry {
            .init(kind: .toolCallUpdate(ToolCall(toolCallID: "toolu_1", title: title, status: status,
                                                 locations: path.map { [ToolCallLocation(path: $0)] } ?? [])))
        }
        let text = render([
            person("Create notes.txt"),
            .init(kind: .toolCall(ToolCall(toolCallID: "toolu_1", title: "Preparing file…", status: "pending"))),
            update("Write /work/api/notes.txt", path: "/work/api/notes.txt"),
            update("Tool call", status: "completed"),
            .init(kind: .toolCall(ToolCall(toolCallID: "toolu_2", title: "mcp__agents__finish_turn",
                                           name: "mcp__agents__finish_turn"))),
            .init(kind: .toolCallUpdate(ToolCall(toolCallID: "toolu_2", title: "Tool call", status: "completed"))),
            chunk("I created `notes.txt"), chunk("` with one line:"), chunk(" `step 1`."),
        ]).markdown
        #expect(text.contains("**Claude:** I created `notes.txt` with one line: `step 1`."))
        #expect(text.components(separatedBy: "**Claude:**").count == 2)
        #expect(text.contains("- Write /work/api/notes.txt (`/work/api/notes.txt`)"))
        #expect(!text.contains("Preparing file"))
        #expect(!text.contains("- Tool call"))
    }

    @Test func aSubagentsStepsAreLeftToIt() {
        let text = render([
            person("Go"),
            .init(kind: .agentMessage(messageID: "sub", text: "subagent musing"), subagentID: "task-1"),
            reply("Done."),
        ]).markdown
        #expect(!text.contains("subagent musing"))
        #expect(text.contains("**Claude:** Done."))
    }

    // MARK: Shortened

    /// Twenty turns of about 1,000 characters each, against a budget of 8,000.
    private var longSession: [TranscriptEntry] {
        var entries = [person("FIRST REQUEST: migrate the database")]
        entries.append(reply(String(repeating: "a", count: 1_000)))
        for turn in 1..<20 {
            entries.append(person("Turn \(turn)"))
            entries.append(reply("REPLY \(turn) " + String(repeating: "b", count: 1_000)))
        }
        entries.append(plan([("Migrate", .completed), ("Verify", .pending)]))
        return entries
    }

    @Test func aLongSessionKeepsTheFirstRequestTheLatestTurnsAndThePlan() {
        let document = render(longSession, budget: 8_000)
        let text = document.markdown
        #expect(text.contains("FIRST REQUEST: migrate the database"))
        #expect(text.contains("REPLY 19 "))
        #expect(text.contains("REPLY 18 "))
        #expect(!text.contains("REPLY 1 "))
        #expect(text.contains("- [ ] Verify"))
        #expect(text.count <= 8_000)
        let leftOut = document.leftOut
        #expect((leftOut ?? 0) > 0)
        #expect(text.contains("\(leftOut ?? -1) turns in the middle were left out to fit."))
    }

    @Test func theCountOfTurnsLeftOutIsExact() {
        let document = render(longSession, budget: 8_000)
        let kept = (1..<20).filter { document.markdown.contains("REPLY \($0) ") }.count
        // Twenty turns: the first, the kept, and the left out.
        #expect(1 + kept + (document.leftOut ?? 0) == 20)
        // The latest ones are the ones kept, with nothing missing between them.
        #expect(kept > 0)
        #expect((20 - kept..<20).allSatisfy { document.markdown.contains("REPLY \($0) ") })
    }

    @Test func aHistoryAtTheBudgetIsGivenWhole() {
        let entries = [person("Hi"), reply("Hello")]
        let whole = render(entries).markdown
        let exact = render(entries, budget: whole.count)
        #expect(exact.leftOut == nil)
        #expect(exact.markdown == whole)
    }

    @Test func thePlanIsKeptEvenWhenItAloneIsOverTheBudget() {
        let huge = (0..<200).map { ("Step \($0) " + String(repeating: "x", count: 60), PlanEntry.Status.pending) }
        var entries = longSession
        entries.append(plan(huge))
        let document = render(entries, budget: 4_000)
        #expect(document.markdown.contains("FIRST REQUEST"))
        #expect(document.markdown.contains("Step 199 "))
        #expect(document.leftOut == 19)
    }

    @Test func theDefaultBudgetIsEightyThousandCharacters() {
        #expect(SessionHistory.budget == 80_000)
    }

    @Test func buildingItAPageAtATimeGivesTheSameAsAllAtOnce() {
        var builder = SessionHistory.Builder(runtime: "Claude", budget: 8_000)
        for entry in longSession { builder.add(entry) }
        #expect(builder.document(header: header) == render(longSession, budget: 8_000))
    }
}
