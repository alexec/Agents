import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A runtime that dies mid-turn, as the daemon sees it (#163).
///
/// Its exit is heard first and the runtime forgotten, which closes the transcript; the
/// turn then fails, and its ending ("stopped answering") is written after that close.
/// That write reopened the transcript and nothing closed it again: the seventh
/// descriptor kept per dead runtime, beside the six pipe ends `RuntimeExitTests` covers.
@Suite("A runtime that dies mid-turn", .timeLimit(.minutes(1)))
struct RuntimeDiesMidTurnTests {
    @Test func theAgentStopsAndItsTranscriptIsLetGo() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDiesMidTurn-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let store = try AgentStore(locations: locations)
        let gate = TurnGate()
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything,
                              launcher: FakeLauncher(script: .init(gate: gate)))
        await core.loadFromDisk()

        let id = try await core.start(.init(runtimeID: "claude", cwd: Project.standardize(work), prompt: "go"))
        await eventually("the turn is under way") { gate.turnsArrived == 1 }
        let session = try #require(await core.live[id])

        // The process going, as `RuntimeProcess` reports it. The fake's end of the wire
        // stays open, as a grandchild holding stdout would keep it: the session has to
        // close the connection itself for the turn to fail at all.
        await session.noteExit(status: 9)

        await eventually("the agent is stopped") { await core.agent(id)?.state == .stopped }
        await eventually("nothing holds the runtime") { await core.live[id] == nil }
        // The turn's own ending, written after the exit's: what used to reopen the file.
        await eventually("the failed turn wrote its ending") {
            let entries = (try? await core.transcript(.init(agentID: id)).entries) ?? []
            return entries.contains { if case .runtimeNote(let text) = $0.kind { text.contains("stopped answering") } else { false } }
        }
        await eventually("the transcript is closed") { await !store.holdsTranscript(of: id) }
        gate.open()
    }

    private func eventually(_ what: String, _ check: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: Eventually.timeout)
        while ContinuousClock.now < deadline {
            if await check() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("never happened: \(what)")
    }
}
