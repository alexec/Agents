import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Every kind of update the protocol defines, read the way a runtime sends it.
@Suite("Reading session updates")
struct SessionUpdateTests {
    // MARK: Messages

    @Test func aTextChunkIsStoredAsTextTheWayItAlwaysWas() {
        let update = SessionUpdate.decode(["sessionUpdate": "agent_message_chunk",
                                           "messageId": "m1",
                                           "content": ["type": "text", "text": "hello"]])
        guard case .entry(.agentMessage(let id, let text, let blocks)) = update else {
            Issue.record("expected an agent message")
            return
        }
        #expect(id == "m1")
        #expect(text == "hello")
        #expect(blocks.isEmpty, "text-only content needs no blocks on the record")
    }

    @Test func aPictureInAReplyIsKeptRatherThanFlattenedToNothing() {
        // 001 read the text of every block and joined it, so an image became "".
        let update = SessionUpdate.decode(["sessionUpdate": "agent_message_chunk",
                                           "content": [["type": "text", "text": "here: "],
                                                       ["type": "image", "mimeType": "image/png",
                                                        "data": "aGk="]]])
        guard case .entry(.agentMessage(_, let text, let blocks)) = update else {
            Issue.record("expected an agent message")
            return
        }
        #expect(text == "here: ")
        #expect(blocks.count == 2)
        #expect(blocks.last?.requirement == .image)
    }

    // MARK: Tool calls

    @Test func aToolCallCarriesItsContentAndLocations() {
        let update = SessionUpdate.decode([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "t1",
            "title": "Edit notes.txt",
            "name": "Edit",
            "status": "completed",
            "content": [["type": "diff", "path": "/tmp/notes.txt",
                         "oldText": "original", "newText": "edited"]],
            "locations": [["path": "/tmp/notes.txt", "line": 1]],
            "rawOutput": ["ok": true],
        ])
        guard case .entry(.toolCallUpdate(let call)) = update else {
            Issue.record("expected a tool call update")
            return
        }
        #expect(call.name == "Edit")
        #expect(call.diffs.first?.newText == "edited")
        #expect(call.locations.first?.line == 1)
        #expect(call.rawOutput?["ok"]?.boolValue == true)
        #expect(call.rawInput == nil)
    }

    /// A screenshot arrives as content and again as raw output, and the whole update
    /// used to be kept beside both — four copies of the picture in one record. The
    /// parsed fields keep theirs; `raw` keeps only what nothing else took.
    @Test func aToolCallsRawDoesNotCarryItsContentAgain() {
        let picture = String(repeating: "A", count: 2_000)
        let update = SessionUpdate.decode([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "t2",
            "title": "Screenshot",
            "status": "completed",
            "content": [["type": "content",
                         "content": ["type": "image", "mimeType": "image/png", "data": .string(picture)]]],
            "rawInput": ["description": "Take a screenshot"],
            "rawOutput": [["type": "image", "source": ["data": .string(picture)]]],
            "invented": "kept",
        ])
        guard case .entry(.toolCallUpdate(let call)) = update else {
            Issue.record("expected a tool call update")
            return
        }
        #expect(call.content.count == 1)
        #expect(call.rawInput?["description"]?.stringValue == "Take a screenshot")
        #expect(call.rawOutput != nil)
        #expect(call.raw?["content"] == nil)
        #expect(call.raw?["rawInput"] == nil)
        #expect(call.raw?["rawOutput"] == nil)
        #expect(call.raw?["title"]?.stringValue == "Screenshot")
        #expect(call.raw?["invented"]?.stringValue == "kept")
        #expect(call.line == "Take a screenshot")
    }

    /// A record written before the trimming still holds the copies. They are dropped
    /// as the record is read, so an old chat costs no more to open than a new one.
    @Test func aRecordWrittenWithTheCopiesIsTrimmedAsItIsRead() throws {
        let json = """
        {"title":"Screenshot","status":"completed",
         "rawInput":{"description":"Take a screenshot"},
         "rawOutput":[{"data":"PICTURE"}],
         "raw":{"title":"Screenshot","rawInput":{"description":"Take a screenshot"},
                "rawOutput":[{"data":"PICTURE"}],"content":[{"data":"PICTURE"}],"kind":"other"}}
        """
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
        #expect(call.rawInput?["description"]?.stringValue == "Take a screenshot")
        #expect(call.rawOutput != nil)
        #expect(call.raw?["rawInput"] == nil)
        #expect(call.raw?["rawOutput"] == nil)
        #expect(call.raw?["content"] == nil)
        #expect(call.raw?["kind"]?.stringValue == "other")
    }

    // MARK: Usage

    @Test func usageIsReadWithItsCost() {
        // Captured from the Claude adapter on 2026-09-18.
        let update = SessionUpdate.decode(["sessionUpdate": "usage_update",
                                           "used": 30360, "size": 1000000,
                                           "cost": ["amount": 0.243933, "currency": "USD"]])
        guard case .usage(let usage) = update else {
            Issue.record("expected usage")
            return
        }
        #expect(usage.used == 30360)
        #expect(usage.cost?.currency == "USD")
        #expect(usage.fraction.map { $0 < 0.04 } == true)
        #expect(!usage.isCloseToFull)
    }

    @Test func usageWithNoWindowSizeHidesTheMeterRatherThanShowingZero() {
        let usage = Usage(used: 10, size: 0)
        #expect(usage.fraction == nil)
        #expect(!usage.isCloseToFull)
    }

    @Test func closeToFullIsOneNumberInOnePlace() {
        #expect(Usage(used: 84, size: 100).isCloseToFull == false)
        #expect(Usage(used: 85, size: 100).isCloseToFull == true)
    }

    @Test func costIsNeverInvented() {
        let update = SessionUpdate.decode(["sessionUpdate": "usage_update", "used": 1, "size": 2])
        guard case .usage(let usage) = update else {
            Issue.record("expected usage")
            return
        }
        #expect(usage.cost == nil)
    }

    @Test func costsAreKeptPerCurrency() {
        let dollars = Cost(amount: 1.5, currency: "USD")
        #expect(dollars.adding(Cost(amount: 0.5, currency: "USD"))?.amount == 2)
        #expect(dollars.adding(Cost(amount: 0.5, currency: "GBP")) == nil)
    }

    @Test func aTotalIsOneNumberPerCurrency() {
        #expect(Cost.total(of: [:]) == nil, "nothing spent shows nothing, not a zero")

        let one = Cost.total(of: ["USD": 1.5])
        #expect(one?.contains("1.5") == true)

        // Two currencies read as two numbers, in currency order, never added.
        let two = Cost.total(of: ["USD": 1.5, "GBP": 0.5])
        #expect(two?.contains(" · ") == true)
        #expect(two?.firstIndex(of: "·") != nil)
        #expect(two?.hasPrefix("£") == true, "GBP sorts before USD")
    }

    @Test func aRuntimeMayPriceATurnWithoutSayingHowBigItsWindowIs() {
        // Then there is no meter to hang the cost off, and the cost still shows.
        let update = SessionUpdate.decode(["sessionUpdate": "usage_update", "used": 10,
                                           "cost": ["amount": 0.25, "currency": "USD"]])
        guard case .usage(let usage) = update else {
            Issue.record("expected usage")
            return
        }
        #expect(usage.fraction == nil)
        #expect(usage.cost?.amount == 0.25)
    }

    // MARK: Plans

    @Test func aPlanIsReadAsItsSteps() {
        let update = SessionUpdate.decode(["sessionUpdate": "plan",
                                           "entries": [["content": "Read the package",
                                                        "priority": "high", "status": "in_progress"],
                                                       ["content": "Write it down",
                                                        "priority": "low", "status": "pending"]]])
        guard case .plan(let plan) = update else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.entries.count == 2)
        #expect(plan.entries.first?.status == .inProgress)
        #expect(plan.planID == nil)
    }

    @Test func aPlanUpdateReplacesTheOneWithItsId() {
        let first = Plan(planID: "p1", entries: [PlanEntry(content: "one")])
        let second = Plan(planID: "p1", entries: [PlanEntry(content: "one", status: .completed)])
        let other = Plan(planID: "p2", entries: [PlanEntry(content: "elsewhere")])
        var plans = Plan.applying(first, to: [])
        plans = Plan.applying(other, to: plans)
        plans = Plan.applying(second, to: plans)
        #expect(plans.count == 2, "the same id replaces rather than adds")
        #expect(plans.first?.entries.first?.status == .completed)
    }

    @Test func aWithdrawnPlanIsMarkedRatherThanDeleted() {
        let plans = Plan.withdrawing("p1", in: [Plan(planID: "p1", entries: [PlanEntry(content: "one")])])
        #expect(plans.count == 1, "it happened, so it stays on the record")
        #expect(plans.first?.state == .withdrawn)
    }

    @Test func planRemovalNamesThePlan() {
        let update = SessionUpdate.decode(["sessionUpdate": "plan_removed", "planId": "p1"])
        guard case .planRemoved(let id) = update else {
            Issue.record("expected a removal")
            return
        }
        #expect(id == "p1")
    }

    // MARK: Compaction

    @Test func compactionIsShownRatherThanHappeningSilently() {
        let update = SessionUpdate.decode(["sessionUpdate": "compaction_update",
                                           "compactionId": "c1", "status": "completed",
                                           "summary": [["type": "text", "text": "We did three things."]]])
        guard case .entry(.compaction(let status, let summary)) = update else {
            Issue.record("expected compaction")
            return
        }
        #expect(status == "completed")
        #expect(summary.plainText == "We did three things.")
    }

    // MARK: The rest

    @Test func anUpdateWeDoNotKnowIsReportedAndSkipped() {
        guard case .unknown(let kind) = SessionUpdate.decode(["sessionUpdate": "telepathy"]) else {
            Issue.record("expected unknown")
            return
        }
        #expect(kind == "telepathy")
    }

    @Test func anEmptyModeUpdateIsNotAMode() {
        guard case .unknown = SessionUpdate.decode(["sessionUpdate": "current_mode_update"]) else {
            Issue.record("expected unknown")
            return
        }
    }
}
