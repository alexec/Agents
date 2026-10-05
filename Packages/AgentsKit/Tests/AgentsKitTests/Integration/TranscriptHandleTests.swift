import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A transcript is held open only while a runtime writes to it (#209). Archiving let the
/// runtime go, which closed it, and then wrote the state line, which opened it again for
/// the daemon's life: one descriptor per archive. A failed pick-up's note and a fork's
/// copy did the same.
@Suite("Transcript handles", .timeLimit(.minutes(1)))
struct TranscriptHandleTests {
    private func setUp() throws -> (DaemonCore, AgentStore, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsTranscriptHandles-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let store = try AgentStore(locations: locations)
        // A runtime that can branch, for the fork.
        var script = FakeACPAgent.Script()
        script.sessionCapabilities = ["close": [:], "list": [:], "fork": [:]]
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything,
                              launcher: FakeLauncher(script: script))
        return (core, store, root, work)
    }

    @Test func archivingTwentyFinishedAgentsLeavesNoTranscriptOpen() async throws {
        let (core, store, root, work) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        await core.loadFromDisk()
        var ids: [UUID] = []
        for i in 0..<20 {
            ids.append(try await core.start(.init(runtimeID: "claude", cwd: Project.standardize(work),
                                                  prompt: "go \(i)")))
        }
        for id in ids {
            await eventually("agent \(id) finished and let its runtime go") {
                let finished = await core.agent(id)?.state == .finished
                let released = await core.live[id] == nil
                return finished && released
            }
        }
        for id in ids { try await core.archive(id) }
        for id in ids { #expect(await core.agent(id)?.state == .archived) }
        await eventually("no transcript is held open") { await store.openTranscripts == 0 }
    }

    @Test func aForkWithNoRuntimeLeavesItsCopyClosed() async throws {
        let (core, store, root, work) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        await core.loadFromDisk()
        let id = try await core.start(.init(runtimeID: "claude", cwd: Project.standardize(work), prompt: "go"))
        await eventually("it finished and let its runtime go") {
            let finished = await core.agent(id)?.state == .finished
            let released = await core.live[id] == nil
            return finished && released
        }
        let copy = try await core.fork(agentID: id)
        #expect(await core.live[copy] == nil)
        #expect(await !store.holdsTranscript(of: copy))
        let entries = try await core.transcript(.init(agentID: copy)).entries
        #expect(!entries.isEmpty, "the copy was written all the same")
    }
}
