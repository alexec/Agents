import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a host tells its control plane about whether it is idle (#691 US4, FR-030), for its
/// workspace's stop when idle: a real agent through a real `DaemonCore`, said only on a change.
@Suite("A host says whether it is idle (#691)", .timeLimit(.minutes(1)))
struct HostStatusTests {
    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [DaemonAPI.HostStatus] = []
        func add(_ value: JSONValue) {
            guard let status = try? value.decode(DaemonAPI.HostStatus.self) else { return }
            lock.withLock { said.append(status) }
        }
        var all: [DaemonAPI.HostStatus] { lock.withLock { said } }
    }

    @Test func aTurnMakesItBusyAndItsEndIdleAgain() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsHostStatus-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(600)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        let said = Said()
        await core.deliverStatus { said.add($0) }
        #expect(said.all == [DaemonAPI.HostStatus(idle: true)])

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do a thing"))
        await eventually("it is working") { await core.agent(id)?.state == .running }
        await core.reviseHostStatus()
        #expect(said.all.last?.idle == false)
        #expect(said.all.last?.running.count == 1)

        // Nothing moved: nothing said.
        let before = said.all.count
        await core.reviseHostStatus()
        #expect(said.all.count == before)

        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        await core.reviseHostStatus()
        #expect(said.all.last == DaemonAPI.HostStatus(idle: true))
    }
}
