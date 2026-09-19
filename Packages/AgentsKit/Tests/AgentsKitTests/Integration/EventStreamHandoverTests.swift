import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What happens to a session's events when the daemon lets the session go.
///
/// A turn ends on one task and the session's events are read on another. The moment
/// the turn ends the daemon hands the runtime back, and handing it back used to begin
/// by cancelling the reader. Cancelling a reader ends the stream it is reading: what
/// was already in the buffer still arrives, but everything said from that instant on
/// is yielded into a stream nobody will ever read again and is gone without trace.
///
/// "From that instant on" is not a small window. The runtime is handed back *before*
/// the session is closed, and closing it is a conversation of its own: cancel the
/// turn, close the session, wait for the process. A runtime with anything left to say
/// — a tool call marked cancelled, a final usage line — says it there.
@Suite("Letting go of a session without losing what it said", .timeLimit(.minutes(1)))
struct EventStreamHandoverTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsHandoverTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    /// The whole record, never a page of it: the question here is always what is
    /// missing, and a page limit would answer it wrongly.
    private func record(_ core: DaemonCore, _ id: UUID) async -> [TranscriptEntry] {
        (try? await core.transcript(.init(agentID: id, limit: 10_000)))?.entries ?? []
    }

    private func saidBy(_ entries: [TranscriptEntry]) -> [String] {
        entries.compactMap { if case .agentMessage(_, let text, _) = $0.kind { return text } else { return nil } }
    }

    /// A runtime's last words. It is being closed, it has one more thing to say, and
    /// the only chance to hear it is now.
    @Test func theLastThingARuntimeSaysWhileItIsClosingReachesTheRecord() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [FakeACPAgent.chunk("during the turn")]
        script.updatesOnClose = [FakeACPAgent.chunk("on the way out")]
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the runtime was handed back") { await core.live[id] == nil }
        // Said and then heard are two things, so this waits rather than asserting into
        // a race. What it is waiting for is something the old shape never delivered at
        // all: the stream it would have arrived down was ended by the cancel before
        // the session was even asked to close.
        await eventually("the runtime's last words reached the record") {
            await saidBy(record(core, id)).contains("on the way out")
        }
        #expect(await saidBy(record(core, id)).contains("during the turn"))
    }

    /// Stopped mid-sentence. Everything the agent had already said is the user's, and
    /// a stop is not a reason to lose any of it — nor to go on writing it down after
    /// the daemon has said the agent is stopped and gone quiet.
    @Test func nothingAlreadySaidIsLostWhenTheUserStops() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        // A turn that will not end on its own, so the stop is what ends it.
        script.turnDelay = .seconds(30)
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        guard let runtime = launcher.lastAgent else {
            Issue.record("the fake runtime was never made"); return
        }
        // Said all in one breath, so the reader is still working through it when the
        // stop arrives. A plan update costs the reader far more than a chunk does —
        // it rewrites the agent, saves it and tells every window before appending —
        // which is what puts the reader behind the runtime rather than alongside it.
        let count = 200
        for i in 0..<count {
            await runtime.emit(FakeACPAgent.chunk("chunk-\(i)"))
            await runtime.emit(["sessionUpdate": "plan_update", "planId": .string("plan-\(i)"),
                                "entries": [["content": .string("step \(i)"), "status": "pending"]]])
        }

        try await core.stop(id)

        // No waiting. Stop has returned, the runtime is gone and the stream is over:
        // whatever is not on the record now is not coming.
        let entries = await record(core, id)
        let said = saidBy(entries)
        let missing = (0..<count).map { "chunk-\($0)" }.filter { !said.contains($0) }
        #expect(missing.isEmpty,
                "stopping lost \(missing.count) of \(count) things the agent had said, from \(missing.first ?? "-")")
        let plans = entries.filter { if case .planUpdated = $0.kind { return true } else { return false } }
        #expect(plans.count == count, "and \(count - plans.count) of its plan updates")
    }

    /// The other half of the bargain. Draining rather than cancelling only works if
    /// the stream is always ended, and the only thing that ended it used to be a
    /// process dying. A session let go by being closed — every one in this suite, and
    /// every one the daemon releases at the end of a turn — has to end its stream too,
    /// or the reader waits for ever and the daemon leaks a task per agent.
    @Test func theListenerStopsWhenASessionIsClosedWithoutItsProcessExiting() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        // Long enough that the session is still live and still being read when we go
        // looking for the reader.
        script.turnDelay = .seconds(30)
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        guard let draining = await eventuallySome("the listener", { await core.eventTasks[id] }) else { return }

        // A fake runtime has no process, so nothing will ever report an exit. Closing
        // is the only ending this session gets.
        try await core.stop(id)
        #expect(await core.live[id] == nil)
        #expect(await core.eventTasks[id] == nil, "the listener is not left in the table")
        #expect(draining.isCancelled == false, "drained, not cancelled out from under")

        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await draining.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(ended, "the listener ended on its own rather than outliving the session")

        await core.shutDown()
    }
}
