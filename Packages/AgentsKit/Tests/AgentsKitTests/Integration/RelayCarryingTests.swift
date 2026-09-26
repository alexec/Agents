import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the relay costs and what it survives, with the daemon's end played by a pipe
/// the test holds (046 US2, US3).
@Suite("What the relay carries", .serialized)
struct RelayCarryingTests {
    /// The Mac's end, with the daemon played by the far side of a pair of pipes.
    final class Rig: @unchecked Sendable {
        let cloud = FakeRelayCloud()
        let mac = DeviceKey.ephemeral()
        let phoneKey = DeviceKey.ephemeral()
        let device = UUID()
        let host: RelayHostCore
        let daemonSide = Pipes()
        var running: Task<Void, Never>?

        /// Every daemon connection the host opens, its far end kept here.
        final class Pipes: @unchecked Sendable {
            private let lock = NSLock()
            private var ends: [PairedTransport] = []
            func add(_ end: PairedTransport) { lock.withLock { ends.append(end) } }
            var latest: PairedTransport? { lock.withLock { ends.last } }
        }

        init(window: TimeInterval = 0.4) async {
            let pipes = daemonSide
            host = RelayHostCore(channel: FakeRelayChannel(cloud: cloud), key: mac,
                                 openDaemon: {
                                     let (near, far) = PairedTransport.pair()
                                     pipes.add(far)
                                     return near
                                 },
                                 window: window, livePoll: 0.02, idlePoll: 0.02)
            await host.pair(device, key: phoneKey.publicKey)
            let host = host
            running = Task { await host.run() }
        }

        func phone() async throws -> RelayTransport {
            let transport = RelayTransport(channel: FakeRelayChannel(cloud: cloud), device: device, key: phoneKey,
                                           macKey: mac.publicKey, pollEvery: .milliseconds(20))
            try await transport.open(timeout: .seconds(5))
            return transport
        }

        func stop() { running?.cancel() }
    }

    @Test func aReplyOfFiveMegabytesArrivesWhole() async throws {
        let rig = await Rig(window: 0.05)
        defer { rig.stop() }
        let phone = try await rig.phone()
        let big = #"{"jsonrpc":"2.0","id":1,"result":""# + String(repeating: "agent ", count: 900_000) + #""}"#
        #expect(big.utf8.count > 5_000_000)
        try rig.daemonSide.latest?.write(line: big)
        var lines = phone.lines().makeAsyncIterator()
        let heard = try await lines.next()
        #expect(heard == big)
    }

    @Test func aBusyTurnIsAFewPostsASecond() async throws {
        let rig = await Rig()
        defer { rig.stop() }
        _ = try await rig.phone()
        let before = await rig.cloud.posts
        let start = Date()
        // Fifty entries a second for two seconds, as a busy Claude turn gives.
        for i in 0..<100 {
            try rig.daemonSide.latest?.write(line: #"{"jsonrpc":"2.0","method":"agent/entry","params":{"n":\#(i)}}"#)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(500))
        let elapsed = Date().timeIntervalSince(start)
        let theMacs = await rig.cloud.posts - before
        // The phone's keep-alives and deletes are not posts; what is counted is the Mac's.
        #expect(Double(theMacs) / elapsed <= 3.5, "\(theMacs) posts in \(elapsed) s")
    }

    @Test func linesArriveInOrderWhateverICloudDoes() async throws {
        let rig = await Rig(window: 0.02)
        defer { rig.stop() }
        await rig.cloud.behave(reverses: true, repeats: true)
        let phone = try await rig.phone()
        for i in 0..<200 {
            try rig.daemonSide.latest?.write(line: #"{"n":\#(i)}"#)
            if i % 20 == 0 { try await Task.sleep(for: .milliseconds(30)) }
        }
        var heard: [String] = []
        for try await line in phone.lines() {
            heard.append(line)
            if heard.count == 200 { break }
        }
        #expect(heard == (0..<200).map { #"{"n":\#($0)}"# })
    }

    @Test func aSendLostWithTheLinkHappensOnceWhenItIsSentAgain() async throws {
        // Carried out by a real core, so the property is the daemon's `once(sendID)`,
        // reached the way the phone's `sendOnce` reaches it: the same params, twice, on
        // two different connections.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-once-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        let agent = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "first"))
        await eventually("the first turn ended") { await core.agent(agent)?.state.holdsRuntime == false }
        for change in 0..<10 {
            let request = DaemonAPI.PromptRequest(agentID: agent, text: "change \(change)", sendID: UUID())
            // First over one link, lost; again over the next.
            _ = try await core.handle(method: DaemonAPI.Method.agentsPrompt,
                                      params: try JSONValue.encoding(request), connection: UUID()).get()
            _ = try await core.handle(method: DaemonAPI.Method.agentsPrompt,
                                      params: try JSONValue.encoding(request), connection: UUID()).get()
        }
        await eventually("every prompt is on the record") {
            let entries = (try? await core.transcript(.init(agentID: agent, limit: 500)).entries) ?? []
            return (0..<10).allSatisfy { change in
                entries.contains { if case .userMessage("change \(change)", _, _) = $0.kind { true } else { false } }
            }
        }
        let entries = try await core.transcript(.init(agentID: agent, limit: 500)).entries
        for change in 0..<10 {
            let count = entries.count { if case .userMessage("change \(change)", _, _) = $0.kind { true } else { false } }
            #expect(count == 1, "change \(change) was said \(count) times")
        }
    }
}
