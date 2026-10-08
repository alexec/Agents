import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What each connection is told about an agent (#203): a row's worth on every change, and
/// the conversation itself only where it is open.
@Suite("Notification bounds", .timeLimit(.minutes(1)))
struct NotificationBoundsTests {
    /// Every line each connection would have been written, in order.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [UUID: [(method: String, line: String)]] = [:]

        func deliver(_ method: String, _ params: JSONValue?, to connections: [UUID]) {
            let line = (try? JSONRPCCodec.encode(.notification(method: method, params: params))) ?? ""
            lock.withLock { for id in connections { lines[id, default: []].append((method, line)) } }
        }

        func heard(_ method: String, by connection: UUID) -> [String] {
            lock.withLock { (lines[connection] ?? []).filter { $0.method == method }.map(\.line) }
        }

        func clear() { lock.withLock { lines = [:] } }
    }

    private let showing = UUID()
    private let elsewhere = UUID()
    private let silent = UUID()

    private func core(_ wire: Wire, launcher: FakeLauncher = FakeLauncher()) async throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NotificationBounds-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        let everyone = [showing, elsewhere, silent]
        await core.setBroadcaster { method, params in wire.deliver(method, params, to: everyone) }
        await core.setAddressedBroadcaster { method, params, wanted in
            wire.deliver(method, params, to: everyone.filter { wanted(.init(id: $0, surface: .mac)) })
        }
        return (core, Project.standardize(folder))
    }

    /// An agent with the lists of a real runtime: a hundred and fifty commands, about 20 KB.
    private func agentWithLists(_ core: DaemonCore, in folder: URL) async throws -> UUID {
        let id = try await core.start(.init(runtimeID: "claude", cwd: folder, prompt: "Review"))
        var agent = try #require(await core.agent(id))
        agent.availableCommands = (0..<150).map {
            SlashCommand(name: "command-\($0)", description: "What command \($0) does, said at the length runtimes say it.")
        }
        await core.changed(agent)
        return id
    }

    private func eventually(_ what: String, _ check: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if await check() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("never happened: \(what)")
    }

    private func show(_ agentID: UUID?, on connection: UUID, _ core: DaemonCore) async throws {
        try await core.reportPresence(.init(watching: nil, active: false, showing: agentID),
                                      from: .mac, connection: connection)
    }

    @Test func aLabelToggleSendsUnderAKilobyteToEveryConnection() async throws {
        let wire = Wire()
        let (core, folder) = try await core(wire)
        let id = try await agentWithLists(core, in: folder)
        try await show(id, on: showing, core)
        let whole = try JSONEncoder().encode(try #require(await core.agent(id))).count
        #expect(whole > 15_000, "the fixture is the size of a real record")
        wire.clear()

        _ = try await core.setSessionLabels(.init(agentID: id, add: ["Urgent"], remove: []))
        _ = try await core.setSessionLabels(.init(agentID: id, add: [], remove: ["Urgent"]))

        for connection in [showing, elsewhere, silent] {
            let changes = wire.heard(DaemonAPI.Notification.agentChanged, by: connection)
            #expect(changes.count >= 2, "\(changes.count) changes")
            for line in changes { #expect(line.utf8.count < 1_024, "\(line.utf8.count) bytes") }
        }
    }

    @Test func theListsGoWholeOnlyToTheConnectionShowingTheAgentAndOnlyWhenTheyMove() async throws {
        let wire = Wire()
        let (core, folder) = try await core(wire)
        let id = try await agentWithLists(core, in: folder)
        try await show(id, on: showing, core)
        wire.clear()

        var agent = try #require(await core.agent(id))
        agent.availableCommands.append(SlashCommand(name: "new"))
        await core.changed(agent)

        let shown = try #require(wire.heard(DaemonAPI.Notification.agentChanged, by: showing).last)
        let decoded = try JSONValue.parse(Data(shown.utf8))["params"]!.decode(Agent.self)
        #expect(decoded.availableCommands.count == 151)
        #expect(!decoded.listsLeftOut)
        for connection in [elsewhere, silent] {
            let line = try #require(wire.heard(DaemonAPI.Notification.agentChanged, by: connection).last)
            let lean = try JSONValue.parse(Data(line.utf8))["params"]!.decode(Agent.self)
            #expect(lean.availableCommands.isEmpty)
            #expect(lean.listsLeftOut)
        }
    }

    @Test func aConnectionNotShowingTheAgentHearsNoEntry() async throws {
        let wire = Wire()
        let (core, folder) = try await core(wire)
        let id = try await core.start(.init(runtimeID: "claude", cwd: folder, prompt: "Review"))
        try await show(id, on: showing, core)
        try await show(nil, on: elsewhere, core)
        wire.clear()

        await core.record(.agentMessage(messageID: nil, text: "Here is the diff."), for: id)

        #expect(wire.heard(DaemonAPI.Notification.agentEntry, by: showing).count == 1)
        #expect(wire.heard(DaemonAPI.Notification.agentEntry, by: elsewhere).isEmpty)
        #expect(wire.heard(DaemonAPI.Notification.agentEntry, by: silent).isEmpty)
    }

    @Test func anEntryTooBigToSendGoesAsAStubSayingWhereToReadIt() async throws {
        let wire = Wire()
        let (core, folder) = try await core(wire)
        let id = try await core.start(.init(runtimeID: "claude", cwd: folder, prompt: "Review"))
        try await show(id, on: showing, core)
        wire.clear()

        let big = String(repeating: "A line of a file read whole. ", count: 4_000)
        await core.record(.agentMessage(messageID: nil, text: big), for: id)

        let line = try #require(wire.heard(DaemonAPI.Notification.agentEntry, by: showing).last)
        #expect(line.utf8.count < 1_024)
        let note = try JSONValue.parse(Data(line.utf8))["params"]!.decode(DaemonAPI.EntryNotification.self)
        #expect(note.oversized.map { $0 > DaemonAPI.EntryNotification.entryByteLimit } == true)
        let index = try #require(note.index)
        let page = try await core.store.transcript(for: id, before: index + 1, limit: 1)
        #expect(page.entries.first?.id == note.entry.id)
        #expect(page.entries.first?.text == big)
    }

    @Test func terminalOutputGoesOnlyToTheConnectionShowingTheAgent() async throws {
        let wire = Wire()
        // The turn stays open on a question, as a turn running a command does: the
        // terminals go when the agent stops.
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Something"],
                             "options": [["optionId": "allow_once", "name": "Allow", "kind": "allow_once"]]]
        let (core, folder) = try await core(wire, launcher: FakeLauncher(script: script))
        let id = try await core.start(.init(runtimeID: "claude", cwd: folder, prompt: "Review"))
        try await show(id, on: showing, core)
        let service = await core.terminals(for: id)
        _ = try await service.create(command: "echo", args: ["built"], cwd: folder.path, env: nil)
        await eventually("the output reached the connection showing the agent") {
            !wire.heard(DaemonAPI.Notification.agentTerminalOutput, by: showing).isEmpty
        }
        #expect(!wire.heard(DaemonAPI.Notification.agentTerminalOutput, by: showing).isEmpty)
        #expect(wire.heard(DaemonAPI.Notification.agentTerminalOutput, by: elsewhere).isEmpty)

        // Opened later, it is sent what the terminal still holds, whole.
        try await show(id, on: elsewhere, core)
        await eventually("what the terminal holds reached the connection that opened it") {
            !wire.heard(DaemonAPI.Notification.agentTerminalOutput, by: elsewhere).isEmpty
        }
        let caughtUp = try #require(wire.heard(DaemonAPI.Notification.agentTerminalOutput, by: elsewhere).last)
        let note = try JSONValue.parse(Data(caughtUp.utf8))["params"]!.decode(DaemonAPI.TerminalOutputNotification.self)
        #expect(note.whole == true)
        #expect(note.chunk.contains("built"))
    }
}
