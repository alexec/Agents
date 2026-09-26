import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The phone's `DaemonClient` over the relay, through a fake iCloud, to a real daemon on
/// its own socket — the whole of 046's carrying, with nothing but CloudKit left out.
///
/// The host polls every 20 ms rather than every second so a test is not at iCloud's
/// pace; everything else is as shipped.
@Suite("The relay, end to end", .serialized)
struct RelayEndToEndTests {
    /// A link that hands over one transport it was given.
    struct GivenLink: DaemonLink {
        let transport: any LineTransport
        func transport() async throws -> any LineTransport { transport }
    }

    final class Rig: @unchecked Sendable {
        let core: DaemonCore
        let server: DaemonServer
        let launcher: FakeLauncher
        let locations: StoreLocations
        let work: URL
        let cloud = FakeRelayCloud()
        let mac = DeviceKey.ephemeral()
        let host: RelayHostCore
        var running: Task<Void, Never>?

        init(script: FakeACPAgent.Script = .init(), window: TimeInterval = 0.05) async throws {
            // Short, because a Unix socket's path has room for 104 bytes.
            let root = URL(fileURLWithPath: "/tmp/r46-\(UUID().uuidString.prefix(8))")
            locations = StoreLocations(root: root)
            try locations.createDirectories()
            work = root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            launcher = FakeLauncher(script: script)
            let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                                  discovery: .findsEverything, launcher: launcher)
            self.core = core
            await core.loadFromDisk()
            server = DaemonServer(url: locations.socket) { context, method, params in
                await core.handle(method: method, params: params, from: context.surface, connection: context.id)
            }
            try server.start()
            let server = server
            await core.setBroadcaster { method, params in server.broadcast(method, params) }
            let link = SocketLink(locations: locations)
            host = RelayHostCore(channel: FakeRelayChannel(cloud: cloud), key: mac,
                                 openDaemon: { try await link.transport() },
                                 window: window, livePoll: 0.02, idlePoll: 0.02)
            let host = host
            running = Task { await host.run() }
        }

        /// A paired phone with a client connected over the relay.
        func phone(paired: Bool = true, key: DeviceKey = .ephemeral(), id: UUID = UUID(),
                   onTrouble: @escaping @Sendable (RelayTrouble) -> Void = { _ in }) async throws
            -> (client: DaemonClient, transport: RelayTransport, id: UUID) {
            if paired { await host.pair(id, key: key.publicKey) }
            let transport = RelayTransport(channel: FakeRelayChannel(cloud: cloud), device: id, key: key,
                                           macKey: mac.publicKey, pollEvery: .milliseconds(20), onTrouble: onTrouble)
            try await transport.open(timeout: paired ? max(.seconds(5), Eventually.timeout) : .seconds(1))
            let client = DaemonClient(link: GivenLink(transport: transport))
            try await client.connect(startIfNeeded: false)
            return (client, transport, id)
        }

        func stop() {
            running?.cancel()
            server.stop()
            try? FileManager.default.removeItem(at: locations.root)
        }
    }

    @Test func aPairedPhoneReachesTheDaemon() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        let (client, _, _) = try await rig.phone()
        _ = try await client.call(DaemonAPI.Method.ping)
        let projects = try await client.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false))
        #expect(projects.arrayValue != nil)
    }

    @Test func aPermissionIsAnsweredFromAway() async throws {
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Write hello.txt"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                                         ["optionId": "no", "name": "Reject", "kind": "reject_once"]]]
        let rig = try await Rig(script: script)
        defer { rig.stop() }
        let id = try await rig.core.start(.init(runtimeID: "claude", cwd: rig.work, prompt: "write a file"))
        await eventually("the agent is waiting on its question") { await rig.core.agent(id)?.state == .waitingOnUser }

        let (client, _, _) = try await rig.phone()
        let pending = try await client.call(DaemonAPI.Method.permissionsPending, Optional<String>.none,
                                            returning: [PermissionRequest].self)
        #expect(pending.map(\.toolCall.title) == ["Write hello.txt"])
        let answer = DaemonAPI.AnswerRequest(permissionID: pending[0].id, optionID: "allow", sendID: UUID())
        _ = try await client.call(DaemonAPI.Method.permissionsAnswer, answer)
        // The same answer again, as a retry across a link change sends it. Carried out a
        // second time it would be refused as already answered, and this would throw.
        _ = try await client.call(DaemonAPI.Method.permissionsAnswer, answer)
        #expect(await !rig.core.pendingPermissionRequests().map(\.id).contains(pending[0].id))
        #expect(try await answers(rig, id) == 1)
    }

    @Test func notificationsReachThePhone() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        let (client, _, _) = try await rig.phone()
        let heard = Heard()
        let listening = Task {
            for await note in client.notifications() { await heard.add(note.method) }
        }
        defer { listening.cancel() }
        _ = try await rig.core.start(.init(runtimeID: "claude", cwd: rig.work, prompt: "hello"))
        await eventually("the agent's changes arrived over the relay") {
            await heard.methods.contains(DaemonAPI.Notification.agentChanged)
        }
    }

    @Test func anUnpairedPhoneIsNotAnswered() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await #expect(throws: RelayTrouble.macNotAnswering) {
            _ = try await rig.phone(paired: false)
        }
        // And nothing was written back to it.
        #expect(await rig.cloud.posts <= 2)
    }

    @Test func aFrameSealedByAnotherKeyIsIgnored() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        let id = UUID()
        await rig.host.pair(id, key: DeviceKey.ephemeral().publicKey)
        // The phone holds a different key from the one the Mac has on record for its id.
        await #expect(throws: RelayTrouble.macNotAnswering) {
            _ = try await rig.phone(paired: false, key: .ephemeral(), id: id)
        }
        let toDevice = await rig.cloud.stored(device: id).filter { $0.direction == .toDevice }
        #expect(toDevice.isEmpty)
    }

    @Test func iCloudOutOfOrderAndTwiceIsStillInOrderAndOnce() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.cloud.behave(reverses: true, repeats: true)
        let (client, _, _) = try await rig.phone()
        for _ in 0..<5 { _ = try await client.call(DaemonAPI.Method.ping) }
        let sendID = UUID()
        let agent = try await rig.core.start(.init(runtimeID: "claude", cwd: rig.work, prompt: "first"))
        await eventually("the first turn ended") { await rig.core.agent(agent)?.state.holdsRuntime == false }
        let request = DaemonAPI.PromptRequest(agentID: agent, text: "again", sendID: sendID)
        _ = try await client.call(DaemonAPI.Method.agentsPrompt, request)
        _ = try await client.call(DaemonAPI.Method.agentsPrompt, request)
        await eventually("the prompt is on the record") { (try? await said(rig, agent, "again")) == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await said(rig, agent, "again") == 1)
    }

    @Test func aForgottenPhoneIsCutOff() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        let troubles = Troubles()
        let (client, _, id) = try await rig.phone(onTrouble: { trouble in Task { await troubles.add(trouble) } })
        _ = try await client.call(DaemonAPI.Method.ping)
        await rig.host.forget(id)
        #expect(await rig.cloud.hasZone(id) == false)
        await eventually("the phone heard it was forgotten") { await troubles.all.contains(.forgotten) }
        await #expect(throws: (any Error).self) { try await client.call(DaemonAPI.Method.ping) }
    }

    private func answers(_ rig: Rig, _ agent: UUID) async throws -> Int {
        try await rig.core.transcript(.init(agentID: agent, before: nil, limit: 500)).entries.count {
            if case .permissionAnswered = $0.kind { true } else { false }
        }
    }

    private func said(_ rig: Rig, _ agent: UUID, _ text: String) async throws -> Int {
        try await rig.core.transcript(.init(agentID: agent, before: nil, limit: 500)).entries.count {
            if case .userMessage(let said, _, from: .person) = $0.kind { said == text } else { false }
        }
    }

    actor Troubles {
        var all: [RelayTrouble] = []
        func add(_ trouble: RelayTrouble) { all.append(trouble) }
    }

    actor Heard {
        var methods: [String] = []
        func add(_ method: String) { methods.append(method) }
    }
}
