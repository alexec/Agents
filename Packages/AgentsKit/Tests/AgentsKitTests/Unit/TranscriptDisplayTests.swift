import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("What the chat draws")
struct TranscriptDisplayTests {
    private func message(_ text: String, _ id: String? = nil) -> TranscriptEntry {
        TranscriptEntry(kind: .agentMessage(messageID: id, text: text))
    }

    private func call(_ id: String, _ title: String, status: String? = nil) -> TranscriptEntry {
        TranscriptEntry(kind: .toolCall(ToolCall(toolCallID: id, title: title, status: status)))
    }

    private func update(_ id: String, status: String, title: String = "Tool call") -> TranscriptEntry {
        TranscriptEntry(kind: .toolCallUpdate(ToolCall(toolCallID: id, title: title, status: status)))
    }

    /// The end-of-turn call is drawn twice already — the chips above the prompt and
    /// the report at the foot — so the call itself is not (023). The finished update
    /// the Claude adapter sends carries neither name nor title, so it is suppressed
    /// by id, not by name.
    @Test func theFinishCallIsNotDrawn() {
        let ours = ToolCall(toolCallID: "1", title: "finish_turn", name: "mcp__agents__finish_turn")
        let oursFinished = ToolCall(toolCallID: "1", title: "Tool call", status: "completed")
        let theirs = ToolCall(toolCallID: "2", title: "Read a file", name: "read_file")
        let items = TranscriptEntry.display([
            message("Done."),
            TranscriptEntry(kind: .toolCall(ours)),
            TranscriptEntry(kind: .toolCallUpdate(oursFinished)),
            TranscriptEntry(kind: .toolCall(theirs)),
        ])
        let drawn = items.compactMap { item -> [ToolCall]? in
            if case .toolRun(_, let calls) = item { return calls }
            return nil
        }.flatMap { $0 }
        #expect(drawn.map(\.name) == ["read_file"])
    }

    @Test func oneToolCallIsOneLine() {
        let items = TranscriptEntry.display([call("t1", "Write hello.txt")])
        #expect(items.count == 1)
        #expect(items[0].latestToolCall?.title == "Write hello.txt")
        #expect(items[0].hiddenToolCallCount == 0)
    }

    @Test func aCallAndItsUpdatesAreStillOneCall() {
        let items = TranscriptEntry.display([
            call("t1", "Write hello.txt", status: "pending"),
            update("t1", status: "in_progress"),
            update("t1", status: "completed"),
        ])
        #expect(items.count == 1)
        #expect(items[0].hiddenToolCallCount == 0, "an update is the same call further along")
        #expect(items[0].latestToolCall?.status == "completed")
        #expect(items[0].latestToolCall?.title == "Write hello.txt", "the update does not lose the title")
    }

    @Test func aRunOfCallsShowsTheLatestAndKeepsTheRest() {
        let items = TranscriptEntry.display([
            call("t1", "Read the file"),
            call("t2", "Patch the file"),
            call("t3", "Run the tests"),
        ])
        #expect(items.count == 1)
        #expect(items[0].latestToolCall?.title == "Run the tests")
        #expect(items[0].hiddenToolCallCount == 2)
        if case .toolRun(_, let calls) = items[0] {
            #expect(calls.map(\.title) == ["Read the file", "Patch the file", "Run the tests"])
        }
    }

    @Test func anythingSaidBetweenThemStartsANewRun() {
        let items = TranscriptEntry.display([
            call("t1", "Read the file"),
            message("Here is what I found"),
            call("t2", "Patch the file"),
            call("t3", "Run the tests"),
        ])
        #expect(items.count == 3)
        #expect(items[0].hiddenToolCallCount == 0)
        if case .entry(let entry) = items[1] { #expect(entry.text == "Here is what I found") }
        #expect(items[2].hiddenToolCallCount == 1)
    }

    @Test func messageChunksAreStillJoined() {
        let items = TranscriptEntry.display([
            message("Created ", "m1"), message("hello.txt", "m1"),
        ])
        #expect(items.count == 1)
        if case .entry(let entry) = items[0] { #expect(entry.text == "Created hello.txt") }
    }

    @Test func everythingElseKeepsItsOwnLine() {
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .userMessage("do it")),
            call("t1", "Write a file"),
            TranscriptEntry(kind: .stateChanged(.waitingOnUser, reason: nil)),
        ])
        #expect(items.count == 3)
    }

    // MARK: - Plumbing is kept in the record and left off the page

    @Test func theTurnEndingAndItsCostAreNotDrawn() {
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .userMessage("do it")),
            message("Done"),
            state(.finished, .endTurn),
            TranscriptEntry(kind: .usageRecorded(TurnUsage(totalTokens: 1234, cost: nil))),
        ])
        #expect(texts(items) == ["do it", "Done"])
    }

    @Test func theTurnEndingStillMakesWorkingOld() {
        // Nothing was said in the turn, so nothing drawn followed "Working". The
        // ending is not drawn either, but it is still the end of the working.
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .userMessage("do it")),
            state(.running),
            state(.finished, .endTurn),
        ])
        #expect(texts(items) == ["do it"])
    }

    @Test func theTurnEndingStillClosesARunOfToolCalls() {
        let items = TranscriptEntry.display([
            call("t1", "Read the file"),
            state(.finished, .endTurn),
            TranscriptEntry(kind: .userMessage("and again")),
            call("t2", "Read the file"),
        ])
        #expect(texts(items) == ["<tools>", "and again", "<tools>"])
    }

    @Test func aReadTheAppServedIsQuietAndAWriteIsNot() {
        let read = ServedRequest(kind: .readFile(path: "/tmp/a.md"), outcome: .served)
        let refusedRead = ServedRequest(kind: .readFile(path: "/tmp/b.md"), outcome: .refused(reason: "outside the folder"))
        let write = ServedRequest(kind: .writeFile(path: "/tmp/c.md", byteCount: 3), outcome: .served)
        let items = TranscriptEntry.display([
            call("t1", "Look"),
            TranscriptEntry(kind: .servedRequest(read)),
            call("t2", "Look again"),
            TranscriptEntry(kind: .servedRequest(refusedRead)),
            TranscriptEntry(kind: .servedRequest(write)),
        ])
        #expect(texts(items) == ["<tools>", "Read b.md", "Wrote c.md"])
        #expect(items[0].hiddenToolCallCount == 1, "a quiet read does not split the run")
    }

    // MARK: - Lines about a moment go once the moment has

    private func state(_ state: AgentState, _ reason: EndedReason? = nil) -> TranscriptEntry {
        TranscriptEntry(kind: .stateChanged(state, reason: reason))
    }

    private func note(_ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: .runtimeNote(text))
    }

    private func texts(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { item in
            guard case .entry(let entry) = item else { return "<tools>" }
            switch entry.kind {
            case .stateChanged(let s, let r): return "state:\(s):\(r.map { "\($0)" } ?? "-")"
            case .optionChanged(let id, let value): return "\(id)=\(value.stringValue ?? "?")"
            case .unrecognised: return "<unrecognised>"
            case .servedRequest(let request): return request.summary
            default: return entry.text ?? "?"
            }
        }
    }

    @Test func aPassingLineStaysWhileItIsTheLatestThing() {
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .userMessage("do it")),
            state(.running),
        ])
        #expect(texts(items) == ["do it", "state:running:-"])
    }

    @Test func aPassingLineGoesOnceAnythingFollowsIt() {
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .userMessage("do it")),
            state(.running),
            message("On it"),
        ])
        #expect(texts(items) == ["do it", "On it"])
    }

    @Test func onlyTheNewestOfARunOfPassingLinesStays() {
        // A restart, as the record has it: the explanation, the ending it explains,
        // the runtime coming up, the conversation taken back, and work resuming.
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .userMessage("do it")),
            note(RuntimeNote.stoppedWithDaemon),
            state(.stopped, .daemonGone),
            note(RuntimeNote.starting("Claude")),
            note(RuntimeNote.pickedBackUp),
            state(.running),
        ])
        #expect(texts(items) == ["do it", "state:running:-"])
    }

    @Test func aModeSwitchIsNotDrawnAtAll() {
        // Plumbing. The setting in force is on the prompt controls; the record keeps
        // the change, the page does not say it, and it is not the line that makes an
        // earlier passing line old either.
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .optionChanged(id: "mode", value: .string("auto"))),
            TranscriptEntry(kind: .userMessage("go")),
            state(.running),
            TranscriptEntry(kind: .optionChanged(id: "mode", value: .string("plan"))),
        ])
        #expect(texts(items) == ["go", "state:running:-"])
    }

    @Test func aModeSwitchDoesNotSplitARunOfToolCalls() {
        let items = TranscriptEntry.display([
            call("t1", "Read the file"),
            TranscriptEntry(kind: .optionChanged(id: "mode", value: .string("plan"))),
            call("t2", "Write the file"),
        ])
        #expect(texts(items) == ["<tools>"])
        #expect(items[0].hiddenToolCallCount == 1)
    }

    @Test func endingsAndExplanationsAreNotMoments() {
        // `.finished` is not among them: it is not drawn at all, so it is neither a
        // moment nor a line that stays.
        let items = TranscriptEntry.display([
            state(.stopped, .maxTokens),
            note("Branched from Fix the build."),
            state(.stopped, .cancelled),
            state(.waitingOnUser),
            TranscriptEntry(kind: .permissionAnswered(optionID: "allow", optionName: "Allow")),
            note("\(RuntimeNote.starting("Claude")) and then some"),
            message("Done"),
        ])
        #expect(items.count == 7, "an ending, a branch, a wait, an answer and a note in its own words all stay")
    }

    @Test func theDaemonStoppingIsAMomentOnlyOnceItHasBeenPickedBackUp() {
        // Stopped for good: the line is the last word and stays.
        let stopped = TranscriptEntry.display([
            TranscriptEntry(kind: .userMessage("do it")),
            note(RuntimeNote.stoppedWithDaemon),
            state(.stopped, .daemonGone),
        ])
        #expect(texts(stopped) == ["do it", "state:stopped:daemonGone"])
        // A crash, by contrast, is never a moment: it stays however the story goes on.
        let crashed = TranscriptEntry.display([
            state(.stopped, .processDied),
            message("Back"),
        ])
        #expect(texts(crashed) == ["state:stopped:processDied", "Back"])
    }

    @Test func aLineDrawnAsNothingDoesNotSupersedeAnything() {
        let items = TranscriptEntry.display([
            state(.running),
            TranscriptEntry(kind: .unrecognised(.string("from a newer build"))),
        ])
        #expect(texts(items) == ["state:running:-", "<unrecognised>"])
    }

    @Test func aRunOfToolCallsSupersedesAPassingLine() {
        let items = TranscriptEntry.display([
            state(.running),
            call("t1", "Read the file"),
        ])
        #expect(texts(items) == ["<tools>"])
    }
}
