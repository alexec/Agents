import Foundation
import Testing
@testable import AgentsKitCore

/// Assessing a runtime (#47): the steps, the brief, and the score the daemon gives from its
/// own record. Each failure here is a way a runtime could look integrated and not be.
@Suite("Assessing a runtime")
struct RuntimeAssessmentTests {
    let me = UUID()
    let helper = UUID()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let report = "/tmp/work/.agents/reviews/runtimes/claude-2027-01-15.md"
    let scopeFile = "/tmp/root/assessments/scope-abcd.txt"

    func t(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func call(_ at: Double, _ method: String, _ args: [String: JSONValue], ok: Bool = true,
              answer: String = "ok", agentID: UUID? = nil) -> AppToolCall {
        AppToolCall(at: t(at), method: method, ok: ok, arguments: .object(args), answer: answer, agentID: agentID)
    }

    func entry(_ at: Double, _ kind: TranscriptEntry.Kind) -> TranscriptEntry {
        TranscriptEntry(at: t(at), kind: kind)
    }

    func event(_ position: Int64, _ name: String, _ details: [String: String],
               publisher: UUID? = nil) -> Event {
        Event(position: position, name: name, at: t(Double(position)), scope: .project(URL(filePath: "/tmp/work")),
              sentence: name, details: details, publisher: publisher.map { EventPublisher(agentID: $0, title: "me") })
    }

    var reportText: String {
        RuntimeAssessment.steps.map { "| `\($0.id)` | passed |" }.joined(separator: "\n") + "\nwords: plum lantern 47"
    }

    /// Everything a well-integrated runtime leaves behind.
    func goodRecord() -> RuntimeAssessmentVerifier.Record {
        let s = { (v: String) in JSONValue.string(v) }
        let calls: [AppToolCall] = [
            call(1, DaemonAPI.Method.agentsShowFile, ["file": .object(["path": s(report)])],
                 answer: "claude-2027-01-15.md is open, empty, in the files pane"),
            call(2, DaemonAPI.Method.leasesLease, ["name": s("assess-abcd")]),
            call(3, DaemonAPI.Method.leasesList, [:]),
            call(4, DaemonAPI.Method.leasesRelease, ["name": s("assess-abcd")]),
            call(5, DaemonAPI.Method.agentsManageWorkflows, ["action": s("list")]),
            call(5.1, DaemonAPI.Method.agentsManageWorkflows, ["action": s("write"), "workflowID": s("assess-abcd"),
                                                               "content": s(RuntimeAssessment.throwawayWorkflow)],
                 answer: "Created assess-abcd. It will not run until they approve it on the project page."),
            call(5.2, DaemonAPI.Method.agentsManageWorkflows, ["action": s("list")]),
            call(5.3, DaemonAPI.Method.agentsManageWorkflows, ["action": s("remove"), "workflowID": s("assess-abcd")],
                 answer: "assess-abcd is gone. It will not run again."),
            call(6, DaemonAPI.Method.dashboardSetTile, ["arguments": .object([:])]),
            call(7, DaemonAPI.Method.dashboardRead, [:]),
            call(8, DaemonAPI.Method.dashboardRemoveTile, ["id": s("assess-claude")]),
            call(9, DaemonAPI.Method.eventsPublish, ["name": s(RuntimeAssessment.pingEvent)]),
            call(10, DaemonAPI.Method.eventsWait, ["events": .array([s(RuntimeAssessment.pingEvent)]), "from": .int(4)],
                 answer: "custom.assess_ping happened at 10:00"),
            call(10.1, DaemonAPI.Method.eventsWait, ["events": .array([s(RuntimeAssessment.neverEvent)])],
                 answer: "Still waiting for custom.assess_never, since 10:00."),
            call(10.2, DaemonAPI.Method.eventsCancel, [:], answer: "Stopped waiting for custom.assess_never."),
            call(11, DaemonAPI.Method.agentsAskForm, ["questions": .array([
                .object(["id": s("pick"), "prompt": s("Pick one"),
                         "options": .array([.object(["id": s("a")]), .object(["id": s("b")])])]),
                .object(["id": s("words"), "prompt": s("Type any short phrase")]),
            ])], answer: "pick: a\nwords: plum lantern 47"),
            call(20, DaemonAPI.Method.agentsStartHelper, ["prompt": s("Reply OK")], agentID: helper),
            call(21, DaemonAPI.Method.agentsListHelpers, [:]),
            call(22, DaemonAPI.Method.agentsFinishTurn, ["outcome": s("blocked"), "message": s("waiting"),
                                                        "waitingOn": .array([s(helper.uuidString)]),
                                                        "title": s("Assess Claude"),
                                                        "prompts": .array([.object(["label": s("x"), "prompt": s("y")])])]),
            call(40, DaemonAPI.Method.agentsParkHelper, ["agentID": s(helper.uuidString)]),
            call(41, DaemonAPI.Method.agentsArchiveHelper, ["agentID": s(helper.uuidString)]),
            call(42, DaemonAPI.Method.eventsWait, ["events": .array([s(RuntimeAssessment.neverEvent)]), "untilMinutes": .int(1)],
                 answer: "Still waiting for custom.assess_never."),
            call(90, DaemonAPI.Method.agentsFinishTurn, ["outcome": s("blocked"), "message": s("waiting for the timeout"), "prompts": .array([])]),
            call(110, DaemonAPI.Method.agentsFinishTurn, ["outcome": s("blocked"), "message": s("checking again"),
                                                         "checkAgainInMinutes": .int(1), "prompts": .array([])]),
            call(175, DaemonAPI.Method.agentsFinishTurn, ["outcome": s("partly_done"), "message": s("moving"),
                                                         "move": .object(["target": .object(["newWorktree": .object(["name": s("assess-abcd")])]),
                                                                          "removeLeft": .bool(false)]),
                                                         "prompts": .array([])]),
            call(177, DaemonAPI.Method.agentsListSessions, [:],
                 answer: "- \(me.uuidString): “Assess Claude” (you) — Claude, Working."),
            call(177.5, DaemonAPI.Method.agentsReadSession, ["session": s(me.uuidString.lowercased())],
                 answer: "# “Assess Claude”\n- Id: \(me.uuidString)\n"),
            call(178, DaemonAPI.Method.agentsFinishTurn, ["outcome": s("partly_done"), "message": s("moving back"),
                                                         "move": .object(["target": .object(["projectFolder": .object([:])]),
                                                                          "removeLeft": .bool(true)]),
                                                         "prompts": .array([])]),
            call(180, DaemonAPI.Method.agentsFinishTurn, ["outcome": s("done"), "message": s("all passed"),
                                                         "afterwards": s("park"), "prompts": .array([])]),
        ]
        let form = ElicitationRequest(agentID: me, mode: .form(ElicitationSchema(properties: [])))
        let transcript: [TranscriptEntry] = [
            entry(0, .stateChanged(.running, reason: nil)),
            entry(11, .elicitationAsked(form)),
            entry(12, .elicitationAnswered(id: form.id, summary: "answered",
                                           answers: [.init(question: "Pick one", answer: "Alpha"),
                                                     .init(question: "Type any short phrase", answer: "plum lantern 47")])),
            entry(13, .elicitationAsked(ElicitationRequest(agentID: me, mode: .form(ElicitationSchema(properties: []))))),
            entry(14, .elicitationAnswered(id: UUID(), summary: "answered", answers: [])),
            entry(22, .workReported(WorkReport(outcome: .blocked, message: "waiting", at: t(22)))),
            entry(23, .stateChanged(.finished, reason: .endTurn)),
            entry(35, .userMessage("The block you reported has cleared: every agent you were waiting on has finished.", from: .app)),
            entry(35, .stateChanged(.running, reason: nil)),
            entry(90, .workReported(WorkReport(outcome: .blocked, message: "waiting", at: t(90)))),
            entry(91, .stateChanged(.finished, reason: .endTurn)),
            entry(103, .userMessage("Your wait for custom.assess_never timed out at 10:01 with no match.", from: .app)),
            entry(103, .stateChanged(.running, reason: nil)),
            entry(110, .workReported(WorkReport(outcome: .blocked, message: "checking", at: t(110)))),
            entry(111, .stateChanged(.finished, reason: .endTurn)),
            entry(171, .userMessage("The time you asked to check again has come.", from: .app)),
            entry(171, .stateChanged(.running, reason: nil)),
            entry(175, .workReported(WorkReport(outcome: .partlyDone, message: "moving", at: t(175)))),
            entry(175.5, .stateChanged(.finished, reason: .endTurn)),
            entry(176, .runtimeNote("Moved from the project folder to worktree assess-abcd on assess-abcd, from main.")),
            entry(176, .stateChanged(.running, reason: nil)),
            entry(177.6, .toolCall(ToolCall(toolCallID: "w1", title: "Write \(scopeFile)", status: "pending"))),
            entry(177.7, .permissionAsked(scopeCard)),
            entry(177.8, .permissionAnswered(optionID: "reject", optionName: "Reject")),
            entry(178, .workReported(WorkReport(outcome: .partlyDone, message: "moving back", at: t(178)))),
            entry(178.5, .stateChanged(.finished, reason: .endTurn)),
            entry(179, .runtimeNote("Moved from worktree assess-abcd to the project folder. Removed the worktree assess-abcd and its branch.")),
            entry(179, .stateChanged(.running, reason: nil)),
            entry(180, .workReported(WorkReport(outcome: .done, message: "all passed", at: t(180)))),
            entry(181, .stateChanged(.finished, reason: .endTurn)),
        ]
        let events = [
            event(2, "lease.granted", ["agent": me.uuidString, "resource": "assess-abcd"]),
            event(4, "lease.released", ["how": "released", "resource": "assess-abcd"]),
            event(9, RuntimeAssessment.pingEvent, [:], publisher: me),
            event(40, "agent.parked", ["agent": helper.uuidString]),
        ]
        var helperAgent = Agent(id: helper, runtimeID: "claude", cwd: URL(filePath: "/tmp/work"), state: .archived)
        helperAgent.startedByAgent = me
        helperAgent.archivedAt = t(41)
        helperAgent.archivedReason = .byAgent
        return .init(agentID: me, runtimeID: "claude", escalationTool: "AskUserQuestion",
                     calls: calls, transcript: transcript, events: events, helpers: [helperAgent],
                     leasesHeld: [], reportPath: report, reportText: reportText,
                     start: .init(agentID: me, runtimeID: "claude", runtimeVersion: "claude-agent-acp 0.81.2",
                                  host: "this Mac (test)", reportPath: report, scopePath: scopeFile, shortID: "abcd"),
                     title: "Assess Claude")
    }

    var scopeCard: PermissionRequest {
        PermissionRequest(agentID: me, toolCall: ToolCall(toolCallID: "w1", title: "Write \(scopeFile)"),
                          options: [.init(optionID: "allow", name: "Allow", kind: .allowOnce),
                                    .init(optionID: "reject", name: "Reject", kind: .rejectOnce)])
    }

    func verdicts(_ record: RuntimeAssessmentVerifier.Record) -> [String: RuntimeAssessmentScore.Verdict] {
        Dictionary(uniqueKeysWithValues: RuntimeAssessmentVerifier.score(record).checks.map { ($0.id, $0.verdict) })
    }

    @Test func aWellIntegratedRuntimePassesEveryStep() {
        let score = RuntimeAssessmentVerifier.score(goodRecord())
        for check in score.checks {
            #expect(check.verdict == .passed, "\(check.id): \(check.evidence)")
        }
        #expect(score.passed)
        #expect(score.summary == "15 of 15 passed")
        #expect(score.note.contains("claude (claude-agent-acp 0.81.2, on this Mac (test))"))
        #expect(score.table.contains("| `helpers` | Helpers | passed |"))
    }

    @Test func theReportIsNotTakenForTheRecord() {
        // A report that says passed for every step, and a record of nothing.
        var record = goodRecord()
        record.calls = []
        record.transcript = []
        let v = verdicts(record)
        for id in ["show_file", "leases", "workflows", "dashboard", "events", "ask_form", "own_ask", "helpers", "wait", "ending",
                   "worktree", "sessions", "scope"] {
            #expect(v[id] == .failed, "\(id)")
        }
    }

    @Test func aLeaseGrantedToSomebodyElseIsNotThisAgents() {
        var record = goodRecord()
        record.events[0].details["agent"] = UUID().uuidString
        #expect(verdicts(record)["leases"] == .failed)
    }

    /// A quick helper ends before its starter blocks on it; the daemon refuses the block,
    /// saying so, and that counts as the helper having finished.
    @Test func aHelperThatFinishedBeforeTheBlockStillPasses() {
        var record = goodRecord()
        let i = record.calls.firstIndex { $0.arguments?["waitingOn"] != nil }!
        record.calls[i].ok = false
        record.calls[i].answer = "Nothing was recorded: “Reply OK” has already ended (complete — OK). Use what it said rather than waiting on it."
        record.transcript.removeAll { if case .userMessage(let text, _, _) = $0.kind { return text.contains("has cleared") } else { return false } }
        let v = verdicts(record)
        #expect(v["helpers"] == .passed)
        #expect(v["ending"] == .passed)
    }

    @Test func aLeaseLeftHeldFails() {
        var record = goodRecord()
        record.leasesHeld = ["assess-abcd"]
        #expect(verdicts(record)["leases"] == .failed)
    }

    @Test func aFileShownAfterItWasWrittenFails() {
        var record = goodRecord()
        record.calls[0].answer = "claude-2027-01-15.md is open in the files pane"
        #expect(verdicts(record)["show_file"] == .failed)
    }

    @Test func anAnswerChangedOnTheWayBackFails() {
        var record = goodRecord()
        let i = record.calls.firstIndex { $0.method == DaemonAPI.Method.agentsAskForm }!
        record.calls[i].answer = "pick: a\nwords: plum"
        #expect(verdicts(record)["ask_form"] == .failed)
    }

    @Test func aRuntimeWithNoAskOfItsOwnIsNotOfferedRatherThanFailed() {
        var record = goodRecord()
        record.escalationTool = nil
        record.transcript.removeAll { if case .elicitationAsked = $0.kind, $0.at == t(13) { return true } else { return false } }
        #expect(verdicts(record)["own_ask"] == .notOffered)
        record.escalationTool = "AskUserQuestion"
        #expect(verdicts(record)["own_ask"] == .failed)
    }

    @Test func aTurnThatEndsWithoutAnAccountFails() {
        var record = goodRecord()
        record.transcript.removeAll { if case .workReported = $0.kind, $0.at == t(90) { return true } else { return false } }
        let score = RuntimeAssessmentVerifier.score(record)
        let ending = score.checks.first { $0.id == "ending" }!
        #expect(ending.verdict == .failed)
        #expect(ending.evidence.contains("1 turn ended without an account"))
    }

    @Test func noCheckAgainTimeFails() {
        var record = goodRecord()
        record.calls.removeAll { $0.arguments?["checkAgainInMinutes"] != nil }
        #expect(verdicts(record)["ending"] == .failed)
    }

    @Test func aHelperNotArchivedByAnAgentFails() {
        var record = goodRecord()
        record.helpers[0].archivedReason = .byUser
        #expect(verdicts(record)["helpers"] == .failed)
    }

    @Test func aWaitThatNeverTimedOutBackFails() {
        var record = goodRecord()
        record.transcript.removeAll { if case .userMessage(let text, _, _) = $0.kind { return text.contains("timed out") } else { return false } }
        #expect(verdicts(record)["wait"] == .failed)
    }

    @Test func thePublishedEventMustBeOnTheLog() {
        var record = goodRecord()
        record.events.removeAll { $0.name == RuntimeAssessment.pingEvent }
        #expect(verdicts(record)["events"] == .failed)
    }

    @Test func aReportThatLeavesOutAStepFails() {
        var record = goodRecord()
        record.reportText = "words: plum lantern 47"
        #expect(verdicts(record)["report"] == .failed)
    }

    @Test func aThrowawayLeftInTheProjectFails() {
        var record = goodRecord()
        record.workflowLeft = true
        #expect(verdicts(record)["workflows"] == .failed)
    }

    @Test func aThrowawayWrittenLiveFails() {
        var record = goodRecord()
        let i = record.calls.firstIndex { $0.arguments?["action"]?.stringValue == "write" }!
        record.calls[i].answer = "Changed assess-abcd. It is live now."
        #expect(verdicts(record)["workflows"] == .failed)
    }

    /// A project already full of workflows waiting for an OK refuses anybody's write.
    @Test func aFullProjectIsNotOfferedTheWorkflowWrite() {
        var record = goodRecord()
        let i = record.calls.firstIndex { $0.arguments?["action"]?.stringValue == "write" }!
        record.calls[i].ok = false
        record.calls[i].answer = "Nothing was written: a, b, c are waiting for their OK in this project."
        #expect(verdicts(record)["workflows"] == .notOffered)
    }

    @Test func aWaitNeverCancelledFails() {
        var record = goodRecord()
        record.calls.removeAll { $0.method == DaemonAPI.Method.eventsCancel }
        #expect(verdicts(record)["events"] == .failed)
    }

    @Test func aWorktreeLeftBehindFails() {
        var record = goodRecord()
        record.transcript = record.transcript.map { entry in
            guard case .runtimeNote(let text) = entry.kind, text.contains("to the project folder") else { return entry }
            return TranscriptEntry(at: entry.at, kind: .runtimeNote("Moved from worktree assess-abcd to the project folder. Kept the worktree assess-abcd: it has changes."))
        }
        #expect(verdicts(record)["worktree"] == .failed)
        record = goodRecord()
        record.worktreeNow = "assess-abcd"
        #expect(verdicts(record)["worktree"] == .failed)
    }

    @Test func aProjectOutsideGitIsNotOfferedTheWorktree() {
        var record = goodRecord()
        let i = record.calls.firstIndex { $0.arguments?["move"]?["target"]?["newWorktree"] != nil }!
        record.calls[i].ok = false
        record.calls[i].answer = "Moving needs a git repository, and work is not in one."
        #expect(verdicts(record)["worktree"] == .notOffered)
    }

    @Test func readingAnotherSessionIsNotReadingYourOwn() {
        var record = goodRecord()
        let i = record.calls.firstIndex { $0.method == DaemonAPI.Method.agentsReadSession }!
        record.calls[i].arguments = .object(["session": .string(UUID().uuidString)])
        #expect(verdicts(record)["sessions"] == .failed)
    }

    @Test func aWriteOutsideTheProjectWithoutAskingFails() {
        var record = goodRecord()
        record.transcript.removeAll { if case .permissionAsked = $0.kind { return true } else { return false } }
        record.scopeWritten = true
        let v = verdicts(record)
        #expect(v["scope"] == .failed)
        #expect(v["permissions"] == .failed)
    }

    /// A runtime whose own sandbox refuses the write never asks: in scope, and nothing to answer.
    @Test func aWriteRefusedWithoutACardIsInScopeAndNotOfferedACard() {
        var record = goodRecord()
        record.transcript.removeAll { if case .permissionAsked = $0.kind { return true } else { return false } }
        let v = verdicts(record)
        #expect(v["scope"] == .passed)
        #expect(v["permissions"] == .notOffered)
    }

    @Test func aRejectedCardThatWritesAnywayFails() {
        var record = goodRecord()
        record.scopeWritten = true
        let v = verdicts(record)
        #expect(v["scope"] == .passed)
        #expect(v["permissions"] == .failed)
    }

    @Test func anAllowedCardWrites() {
        var record = goodRecord()
        record.transcript = record.transcript.map { entry in
            guard case .permissionAnswered = entry.kind else { return entry }
            return TranscriptEntry(at: entry.at, kind: .permissionAnswered(optionID: "allow", optionName: "Allow"))
        }
        #expect(verdicts(record)["permissions"] == .failed)
        record.scopeWritten = true
        #expect(verdicts(record)["permissions"] == .passed)
    }

    @Test func theCheapestModelIsPickedByName() {
        let option = ConfigOption(id: "model", name: "Model", category: "model",
                                  kind: .select([ConfigChoiceGroup(name: nil, choices: [
                                      .init(value: .string("default"), name: "Default (recommended)"),
                                      .init(value: .string("sonnet"), name: "Sonnet 5"),
                                      .init(value: .string("haiku"), name: "Haiku 4.5"),
                                  ])]))
        #expect(RuntimeAssessment.cheapestModel(in: [option]) == "haiku")
        #expect(RuntimeAssessment.cheapestModel(in: []) == nil)
    }

    @Test func theReportGoesUnderReviewsRuntimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let path = RuntimeAssessment.reportPath(project: URL(filePath: "/tmp/work"), runtimeID: "codex",
                                                date: start, calendar: calendar)
        #expect(path.path == "/tmp/work/.agents/reviews/runtimes/codex-2027-01-15.md")
    }

    /// The brief names every step, the events, the helper's label, and the ask tool where
    /// there is one; and says not offered where there is none.
    @Test func theBriefNamesEveryStep() {
        let brief = RuntimeAssessment.brief(runtimeID: "claude", runtimeName: "Claude", model: "haiku",
                                            runtimeVersion: "claude-agent-acp 0.81.2", host: "this Mac (test)",
                                            reportPath: report, scopePath: scopeFile, escalationTool: "AskUserQuestion",
                                            agentShortID: "abcd1234", date: "2027-01-15")
        for step in RuntimeAssessment.steps { #expect(brief.contains("`\(step.id)`"), "\(step.id)") }
        for word in [RuntimeAssessment.pingEvent, RuntimeAssessment.neverEvent, RuntimeAssessment.helperLabel,
                     "AskUserQuestion", "assess-abcd1234", "check_again_in_minutes", report, scopeFile,
                     "cancel_wait", "leave_worktree", "read_session", "claude-agent-acp 0.81.2", "this Mac (test)",
                     "on:\n      - custom.assess_never"] {
            #expect(brief.contains(word), "\(word)")
        }
        let none = RuntimeAssessment.brief(runtimeID: "grok", runtimeName: "Grok", model: nil, reportPath: report,
                                           scopePath: scopeFile, escalationTool: nil, agentShortID: "x", date: "d")
        #expect(none.contains("not offered"))
    }

    /// The skill in `.agents/skills/assess-runtime/` names the same steps as the brief.
    @Test func theSkillNamesTheSameSteps() throws {
        var root = URL(filePath: #filePath)
        while root.path != "/" && !FileManager.default.fileExists(atPath: root.appending(path: ".agents/skills").path) {
            root.deleteLastPathComponent()
        }
        let skill = try String(contentsOf: root.appending(path: ".agents/skills/assess-runtime/SKILL.md"), encoding: .utf8)
        for step in RuntimeAssessment.steps { #expect(skill.contains("| `\(step.id)` |"), "\(step.id)") }
    }
}
