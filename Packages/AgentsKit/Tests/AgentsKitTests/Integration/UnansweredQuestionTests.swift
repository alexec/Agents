import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// 025 US4: the conversation says a question was never answered.
///
/// An answer writes its own closing line — "You chose Allow", "Answered". A question that
/// died with its runtime, its stop or its daemon wrote nothing at all: the record read
/// "Asked: Delete build/", and then simply went on to the ending, leaving somebody reading
/// back months later to work out from an absence whether it had been answered.
@Suite("A question nobody answered", .timeLimit(.minutes(1)))
struct UnansweredQuestionTests {
    // MARK: Scaffolding

    enum Kind: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case permission, form
        var testDescription: String { rawValue }
    }

    enum Ending: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case runtimeExits, personStops, daemonRestarts
        var testDescription: String { rawValue }
    }

    enum Closing: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case allowed, accepted, declined, cancelled, withdrawnByTheRuntime
        var testDescription: String { rawValue }
        var kind: Kind { self == .allowed ? .permission : .form }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsUnanswered-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    /// A runtime that asks one question, of either kind, mid-turn and waits on it.
    private func asking(_ kind: Kind) -> FakeLauncher {
        var script = FakeACPAgent.Script()
        switch kind {
        case .permission:
            script.permission = ["toolCall": ["title": "Delete build/",
                                              "rawInput": ["description": "Delete the build folder"]],
                                 "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                                             ["optionId": "no", "name": "Reject", "kind": "reject_once"]]]
            return FakeLauncher(script: script)
        case .form:
            script.clientRequests = [(ACP.ClientMethod.createElicitation,
                                      ["elicitationId": "e1", "mode": "form", "message": "Which branch?",
                                       "requestedSchema": ["title": "Which branch?",
                                                           "properties": ["branch": ["type": "string",
                                                                                     "title": "Branch"]],
                                                           "required": ["branch"]]])]
            return FakeLauncher(script: script,
                                capabilities: ACP.ClientCapabilities(elicitationForm: true, elicitationURL: true))
        }
    }

    private func core(_ launcher: FakeLauncher, _ locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    /// An agent holding its question open.
    private func waiting(_ kind: Kind, at locations: StoreLocations,
                         in work: URL) async throws -> (DaemonCore, FakeLauncher, UUID) {
        let launcher = asking(kind)
        let core = try core(launcher, locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "tidy up"))
        await eventually("the agent is waiting on its question") {
            await core.agent(id)?.state == .waitingOnUser
        }
        return (core, launcher, id)
    }

    /// The record, read straight off disk, as a window opened next week would read it.
    private func entries(_ locations: StoreLocations, _ id: UUID) async throws -> [TranscriptEntry] {
        try await AgentStore(locations: locations).transcript(for: id, limit: 500).entries
    }

    private func isUnansweredLine(_ entry: TranscriptEntry) -> Bool {
        if case .runtimeNote(let text) = entry.kind { return text == RuntimeNote.questionWentUnanswered }
        return false
    }

    private func isAsked(_ entry: TranscriptEntry) -> Bool {
        switch entry.kind {
        case .permissionAsked, .elicitationAsked: return true
        default: return false
        }
    }

    private func isStopped(_ entry: TranscriptEntry) -> Bool {
        if case .stateChanged(.stopped, _) = entry.kind { return true }
        return false
    }

    /// End the agent the given way, and hand back the record it left.
    private func end(_ how: Ending, _ core: DaemonCore, _ launcher: FakeLauncher, _ id: UUID,
                     locations: StoreLocations) async throws -> [TranscriptEntry] {
        switch how {
        case .runtimeExits:
            await launcher.lastAgent?.stop()
            await eventually("the runtime's death was noticed") { await core.agent(id)?.state == .stopped }
        case .personStops:
            try await core.stop(id)
            await eventually("stopped") { await core.agent(id)?.state == .stopped }
        case .daemonRestarts:
            // The last daemon going while the agent waits means the *record* says it waits.
            // That is written by a queued task a moment after the question reaches the
            // transcript, and the next daemon reads the record: a restart inside that moment
            // finds an agent that was working, not asking, and rightly says nothing.
            await eventually("the record on disk says the agent is waiting") {
                (try? await AgentStore(locations: locations).load(id))?.agent.state == .waitingOnUser
            }
            // Another daemon on the same root, finding the agent where the last one left it.
            let next = try self.core(FakeLauncher(script: .init()), locations)
            _ = await next.recover()
            await eventually("found dead") { await next.agent(id)?.state == .stopped }
        }
        // Whatever the ending set going — the runtime's own reply to a refused question,
        // say — has had its moment to land.
        try await Task.sleep(for: .milliseconds(200))
        // And the question is not still asking. A question left pending for an agent whose
        // runtime has gone is a need with nothing behind it, shown on the Mac and the
        // phone for an answer nobody can hear.
        if how != .daemonRestarts {
            #expect(await core.pendingPermissionRequests().filter { $0.agentID == id }.isEmpty,
                    "\(how): a permission is still pending for an agent that has ended")
            #expect(await core.pendingElicitations().filter { $0.agentID == id }.isEmpty,
                    "\(how): a form is still pending for an agent that has ended")
        }
        return try await entries(locations, id)
    }

    // MARK: FR-014, FR-015: every way a question can die leaves the line, in order

    @Test(arguments: Kind.allCases, Ending.allCases)
    func aQuestionThatDiesLeavesALineSayingSo(_ kind: Kind, _ how: Ending) async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let (core, launcher, id) = try await waiting(kind, at: locations, in: work)

        let record = try await end(how, core, launcher, id, locations: locations)

        let lines = record.indices.filter { isUnansweredLine(record[$0]) }
        #expect(lines.count == 1, "one question, one line: found \(lines.count)")
        guard let line = lines.first,
              let asked = record.firstIndex(where: isAsked),
              let stopped = record.firstIndex(where: isStopped) else {
            Issue.record("missing a line: \(record.map { String(String(describing: $0.kind).prefix(80)) })")
            return
        }
        #expect(asked < line, "the line closes the question, so it comes after it")
        #expect(line < stopped, "and before the ending, so the record reads in the order it happened")
        if how == .daemonRestarts, let note = record.firstIndex(where: {
            if case .runtimeNote(RuntimeNote.stoppedWithDaemon) = $0.kind { return true } else { return false }
        }) {
            #expect(line < note, "the question, then why the agent stopped, then that it did")
        }
    }

    // MARK: FR-016: a question that closed itself gets no second line

    @Test(arguments: Closing.allCases)
    func aQuestionThatWasClosedGetsNoLine(_ closing: Closing) async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let (core, _, id) = try await waiting(closing.kind, at: locations, in: work)

        switch closing {
        case .allowed:
            let question = try #require(await core.pendingPermissionRequests().first)
            try await core.answerPermission(.init(permissionID: question.id, optionID: "allow"))
        case .accepted, .declined, .cancelled:
            let form = try #require(await core.pendingElicitations().first)
            let action: DaemonAPI.AnswerElicitationRequest.Action =
                closing == .accepted ? .accept : closing == .declined ? .decline : .cancel
            try await core.answerElicitation(.init(requestID: form.id, action: action,
                                                   content: closing == .accepted ? ["branch": "main"] : [:]))
        case .withdrawnByTheRuntime:
            let form = try #require(await core.pendingElicitations().first)
            await core.withdrawElicitation(form.id, agentID: id)
        }
        // Then it ends, as agents do. A question that was answered is not made unanswered
        // by what happens to the agent afterwards.
        try await core.stop(id)
        try await Task.sleep(for: .milliseconds(200))

        let record = try await entries(locations, id)
        let asked = record.filter(isAsked).count
        let lines = record.filter(isUnansweredLine).count
        // The fake asks again on a later turn — the outcome question starts one — and that
        // later question, if the stop cut it off, is honestly unanswered. So the rule is
        // one line per question that was *still open*: never one for the question closed.
        #expect(lines <= asked - 1, "\(closing): \(lines) unanswered lines for \(asked) questions")
        if asked == 1 { #expect(lines == 0) }
    }

    // MARK: It is not a passing line

    /// The chat drops a passing note as soon as anything follows it. This one is always
    /// followed at once by the ending it belongs to, so were it passing it would never be
    /// drawn at all.
    @Test func theLineIsStillDrawnOnceTheEndingFollowsIt() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let (core, launcher, id) = try await waiting(.permission, at: locations, in: work)
        let record = try await end(.runtimeExits, core, launcher, id, locations: locations)

        let drawn = TranscriptEntry.display(record).compactMap { item -> TranscriptEntry? in
            if case .entry(let entry) = item { return entry } else { return nil }
        }
        #expect(drawn.contains(where: isUnansweredLine), "the chat would not show it")
        #expect(RuntimeNote.isPassing(RuntimeNote.questionWentUnanswered) == false)
    }
}
