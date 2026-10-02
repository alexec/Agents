import Foundation
import Testing
@testable import AgentsKitCore

/// Finer matching (073): agent context, any of, codes, and values checked, through
/// the one matcher a wait and a trigger share.
@Suite("Event patterns, finer")
struct EventPatternFinerTests {
    private let folder = URL(fileURLWithPath: "/tmp/project")

    private func event(_ name: String, _ details: [String: String] = [:]) -> Event {
        Event(position: 1, name: name, at: Date(timeIntervalSince1970: 0),
              scope: .project(folder: folder), sentence: "", details: details)
    }

    /// An agent event as the daemon raises one: the agent and its context, then its own.
    private func about(_ name: String, labels: String = "", runtime: String = "claude",
                       startedBy: String = "person", _ own: [String: String] = [:]) -> Event {
        event(name, ["agent": UUID().uuidString, "labels": labels, "runtime": runtime, "started_by": startedBy]
            .merging(own) { $1 })
    }

    private func pattern(_ name: String, _ filters: [String: DetailFilter] = [:]) throws -> EventPattern {
        try EventPattern.parse(name, filters: filters).get()
    }

    private func any(_ values: String...) -> DetailFilter { DetailFilter(anyOf: values)! }

    // MARK: SC-001: each trigger fires on its event and not on a near miss

    @Test func t1FinishedLabelledBugAndParked() throws {
        let t1 = try pattern("agent.finished", ["labels": "bug", "afterwards": "park"])
        #expect(t1.matches(about("agent.finished", labels: "bug,p1", ["outcome": "done", "afterwards": "park"])))
        #expect(!t1.matches(about("agent.finished", labels: "bug", ["afterwards": "stay"])))
        #expect(!t1.matches(about("agent.finished", labels: "perf", ["afterwards": "park"])))
        #expect(!t1.matches(about("agent.finished", ["afterwards": "park"])))
    }

    @Test func t2ClaudeFailedForAQuotaReason() throws {
        let t2 = try pattern("agent.failed", ["runtime": "claude", "reason": any("allowance_spent", "rate_limited")])
        #expect(t2.matches(about("agent.failed", ["reason": "allowance_spent"])))
        #expect(t2.matches(about("agent.failed", ["reason": "rate_limited"])))
        #expect(!t2.matches(about("agent.failed", runtime: "codex", ["reason": "allowance_spent"])))
        #expect(!t2.matches(about("agent.failed", ["reason": "process_died"])))
    }

    @Test func t4FinishedDoneOrNothingToDo() throws {
        let t4 = try pattern("agent.finished", ["outcome": any("done", "nothing_to_do")])
        #expect(t4.matches(about("agent.finished", ["outcome": "nothing_to_do"])))
        #expect(!t4.matches(about("agent.finished", ["outcome": "stuck"])))
        #expect(!t4.matches(about("agent.finished")))
    }

    @Test func t6AWorkflowsAgentFailed() throws {
        let t6 = try pattern("agent.failed", ["started_by": "workflow"])
        #expect(t6.matches(about("agent.failed", startedBy: "workflow", ["reason": "process_died"])))
        #expect(!t6.matches(about("agent.failed", startedBy: "agent", ["reason": "process_died"])))
    }

    @Test func t9NightlyCompletedStuckOrPartlyDone() throws {
        let t9 = try pattern("workflow.completed", ["workflow": "nightly", "outcome": any("stuck", "partly_done")])
        #expect(t9.matches(event("workflow.completed", ["workflow": "nightly", "outcome": "stuck"])))
        #expect(!t9.matches(event("workflow.completed", ["workflow": "nightly", "outcome": "done"])))
        #expect(!t9.matches(event("workflow.completed", ["workflow": "weekly", "outcome": "stuck"])))
        #expect(!t9.matches(event("workflow.completed", ["workflow": "nightly"])))
    }

    @Test func t10ArchivedByYouLabelledBugOrRegression() throws {
        let t10 = try pattern("agent.archived", ["by": "you", "labels": any("bug", "regression")])
        #expect(t10.matches(about("agent.archived", labels: "regression", ["by": "you"])))
        #expect(!t10.matches(about("agent.archived", labels: "bug", ["by": "agent"])))
        #expect(!t10.matches(about("agent.archived", labels: "docs", ["by": "you"])))
    }

    @Test func t12TheSimulatorLeaseExpired() throws {
        let t12 = try pattern("lease.released", ["resource": "simulator", "how": "expired"])
        #expect(t12.matches(event("lease.released", ["resource": "simulator", "how": "expired"])))
        #expect(!t12.matches(event("lease.released", ["resource": "simulator", "how": "released"])))
    }

    @Test func t14GeminiOrGrokFailed() throws {
        let t14 = try pattern("agent.failed", ["runtime": any("gemini", "grok")])
        #expect(t14.matches(about("agent.failed", runtime: "grok", ["reason": "process_died"])))
        #expect(!t14.matches(about("agent.failed", runtime: "claude", ["reason": "process_died"])))
    }

    @Test func w1AWaitForADeployLabelledFinish() throws {
        let w1 = try pattern("agent.finished", ["labels": "deploy", "outcome": "done"])
        #expect(w1.matches(about("agent.finished", labels: "deploy", ["outcome": "done"])))
        #expect(!w1.matches(about("agent.finished", labels: "deploy", ["outcome": "stuck"])))
        #expect(!w1.matches(about("agent.finished", labels: "", ["outcome": "done"])))
    }

    @Test func aWholeSubjectNarrowsByStarterAndOnlyWhereTheDetailIsCarried() throws {
        let started = try pattern("agent.*", ["started_by": "workflow"])
        #expect(started.matches(about("agent.parked", startedBy: "workflow")))
        #expect(!started.matches(about("agent.parked")))
        let outcome = try pattern("agent.*", ["outcome": "done"])
        #expect(outcome.matches(about("agent.finished", ["outcome": "done"])))
        #expect(!outcome.matches(about("agent.started")))
    }

    @Test func aCustomEventsLabelsAreItsPublishersAndNotASet() throws {
        let custom = try pattern("custom.ship", ["labels": "bug"])
        #expect(!custom.matches(event("custom.ship", ["labels": "bug,p1"])))
        #expect(custom.matches(event("custom.ship", ["labels": "bug"])))
    }

    // MARK: US4: a wrong value is named

    @Test func aWrongValueIsRefusedListingTheRightOnes() {
        let problem = EventPattern.parse("agent.finished", filters: ["outcome": "complete"]).failure
        #expect(problem?.message == "outcome on agent.finished is one of done, nothing_to_do, needs_answer, "
                + "partly_done, stuck, blocked; \"complete\" is not one of them.")
        let listed = EventPattern.parse("agent.finished", filters: ["outcome": any("done", "finished")]).failure
        #expect(listed?.message.hasSuffix("\"finished\" is not one of them.") == true)
        let runtime = EventPattern.parse("agent.failed", filters: ["runtime": "nope"]).failure
        #expect(runtime?.message.contains("claude") == true)
    }

    @Test func openDetailsTakeAnything() throws {
        _ = try pattern("agent.finished", ["labels": "anything at all"])
        _ = try pattern("workflow.ran", ["workflow": "whatever"])
        _ = try pattern("branch.moved", ["branch": "release/1.0"])
        _ = try pattern("custom.ship", ["outcome": "complete"])
    }

    @Test func aWholeSubjectChecksAgainstEveryKindsValues() throws {
        _ = try pattern("agent.*", ["by": "cost_limit"])
        _ = try pattern("agent.*", ["by": "agent"])
        #expect(EventPattern.parse("agent.*", filters: ["by": "nope"]).failure?.message
                == "by on agent.* is one of you, cost_limit, unknown, agent; \"nope\" is not one of them.")
        #expect(EventPattern.parse("agent.*", filters: ["outcome": "complete"]).failure != nil)
    }

    // MARK: US3: today's words are read as codes

    @Test func todaysWordsAreReadAsTheirCodes() throws {
        #expect(try pattern("agent.failed", ["reason": "its allowance ran out"]).filters["reason"] == "allowance_spent")
        #expect(try pattern("agent.failed", ["reason": "Rate limited, and still limited after retrying"])
            .filters["reason"] == "rate_limited")
        #expect(try pattern("agent.stopped", ["by": "stopped by you"]).filters["by"] == "you")
        #expect(try pattern("agent.stopped", ["by": "stopped"]).filters["by"] == "unknown")
        #expect(try pattern("agent.archived", ["by": "another agent"]).filters["by"] == "agent")
        #expect(try pattern("workflow.refused", ["reason": "this chain is already 3 deep"]).filters["reason"]
                == "chain_too_deep")
        #expect(try pattern("workflow.refused", ["reason": "10 workflows are already running, across every project"])
            .filters["reason"] == "over_limit")
        #expect(try pattern("workflow.refused", ["reason": "a run is still going"]).filters["reason"] == "run_in_flight")
    }

    @Test func wordsThatStandForNoCodeAreRefusedNamingTheCodes() {
        let problem = EventPattern.parse("workflow.refused", filters: ["reason": "Line 3 is not a key"]).failure
        #expect(problem?.message.contains("run_in_flight") == true)
        #expect(problem?.message.contains("\"Line 3 is not a key\"") == true)
    }

    @Test func everyCodeIsAValueAndSaysTodaysWords() {
        let failed = EventCatalogue.kind(named: "agent.failed")!.detail("reason")!
        #expect(failed.values == ["max_tokens", "max_turn_requests", "refusal", "process_died", "daemon_gone",
                                  "unrecognised", "stopped_by_agent", "sign_in_refused", "runtime_error",
                                  "allowance_spent", "rate_limited", "sandbox_failed"])
        for reason in EventCatalogue.failedReasons {
            #expect(failed.code(forOldWords: reason.summary!) == reason.code)
        }
        let refused = EventCatalogue.kind(named: "workflow.refused")!.detail("reason")!
        for refusal in [WorkflowRefusal.runInFlight, .chainTooDeep(depth: 4), .archived, .overLimit(.project),
                        .overLimit(.total), .triggerNotSupported(name: "x.y"), .agentUnavailable, .noTriggeringAgent,
                        .missedWhileClosed, .folderGone, .dayLimitReached, .awaitingApproval] {
            #expect(refused.values?.contains(refusal.code) == true, "\(refusal)")
            #expect(refused.code(forOldWords: refusal.message) == refusal.code, "\(refusal)")
        }
    }

    // MARK: Storage and the wire (FR-028, FR-029)

    /// What the previous version decodes a pattern as.
    private struct OldPattern: Codable {
        var name: String
        var filters: [String: String]
    }

    @Test func singleValuesAreStoredExactlyAsBefore() throws {
        let old = OldPattern(name: "agent.finished", filters: ["outcome": "done"])
        let new = try pattern("agent.finished", ["outcome": "done"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(new) == encoder.encode(old))
        #expect(try JSONDecoder().decode(EventPattern.self, from: encoder.encode(old)) == new)
    }

    @Test func aListIsReadBackAndAnOlderBuildReadsItAsNeverMatching() throws {
        let new = try pattern("agent.finished", ["outcome": any("done", "nothing_to_do")])
        let data = try JSONEncoder().encode(new)
        #expect(try JSONDecoder().decode(EventPattern.self, from: data) == new)
        let old = try JSONDecoder().decode(OldPattern.self, from: data)
        #expect(old.filters == ["outcome": "done|nothing_to_do"])
    }

    @Test func aStoredWaitInTodaysWordsStillMatches() throws {
        let stored = Data(#"{"name":"agent.stopped","filters":{"by":"stopped by you"}}"#.utf8)
        let read = try JSONDecoder().decode(EventPattern.self, from: stored)
        #expect(read.matches(about("agent.stopped", ["by": "you"])))
        // Words that stand for nothing are kept as they were, and refuse nothing.
        let odd = Data(#"{"name":"workflow.refused","filters":{"reason":"Line 3 is not a key"}}"#.utf8)
        #expect(try JSONDecoder().decode(EventPattern.self, from: odd).filters["reason"] == "Line 3 is not a key")
    }

    // MARK: Words (FR-022 to FR-025)

    @Test func theSummarySaysEachFilterInWords() throws {
        #expect(try pattern("agent.finished", ["labels": "bug", "afterwards": "park"]).summary
                == "An agent in this project ended a turn having done its work (labelled bug, and parked)")
        #expect(try pattern("agent.finished", ["outcome": any("done", "nothing_to_do")]).summary
                == "An agent in this project ended a turn having done its work (done or nothing to do)")
        #expect(try pattern("agent.failed", ["runtime": any("gemini", "grok")]).summary
                == "An agent in this project ended in an error (on Gemini or Grok)")
        #expect(try pattern("agent.failed", ["reason": any("allowance_spent", "rate_limited")]).summary
                == "An agent in this project ended in an error (its allowance ran out or "
                + "rate limited, and still limited after retrying)")
        #expect(try pattern("agent.*", ["started_by": "workflow"]).summary
                == "Anything about agents (started by a workflow)")
        #expect(try pattern("agent.finished", ["afterwards": "stay"]).summary
                == "An agent in this project ended a turn having done its work (not parked)")
        #expect(try pattern("workflow.completed", ["workflow": "nightly"]).summary
                == "A workflow's run in this project finished (workflow nightly)")
    }

    @Test func theLabelAndTheTriggerTextWriteAListOneLine() throws {
        let t4 = try pattern("agent.finished", ["outcome": any("done", "nothing_to_do")])
        #expect(t4.label == "agent.finished outcome done|nothing_to_do")
        #expect(t4.asTrigger == "on:\n  - agent.finished:\n      outcome: [done, nothing_to_do]")
    }

    @Test func copyAsTriggerLeavesOutTheAgentAndItsContext() {
        let finished = about("agent.finished", labels: "bug", ["outcome": "done"])
        #expect(EventPattern.matching(finished).asTrigger == "on:\n  - agent.finished:\n      outcome: done")
        let custom = event("custom.ship", ["labels": "bug", "agent": "x"])
        #expect(EventPattern.matching(custom).filters == ["labels": "bug", "agent": "x"])
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
