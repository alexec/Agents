import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// How many calls a Remote's catch-up makes, and how long it takes, against a real daemon
/// over its socket (#175): the old sequence (`refreshEverything` before #175, replayed
/// call for call) against the new plan (`RemoteModel.runCatchUp`, step for step). A phone's
/// link is slower than a socket, so each is also run with 50 ms added to every request.
///
/// The numbers are printed for the commit; the test holds the new plan to fewer calls.
@Suite("Catch-up, measured", .serialized, .timeLimit(.minutes(5)))
struct CatchUpMeasureTests {
    /// A socket that counts the requests written on it and holds each back `delay`.
    final class Counted: LineTransport, @unchecked Sendable {
        let inner: any LineTransport
        let delay: Duration
        private let queue = DispatchQueue(label: "catch-up.counted")
        private let lock = NSLock()
        private var count = 0
        init(_ inner: any LineTransport, delay: Duration) {
            self.inner = inner
            self.delay = delay
        }
        var requests: Int { lock.withLock { count } }
        func reset() { lock.withLock { count = 0 } }

        func write(line: String) throws {
            if line.contains("\"method\""), line.contains("\"id\"") { lock.withLock { count += 1 } }
            guard delay > .zero else { return try inner.write(line: line) }
            let seconds = Double(delay.components.attoseconds) / 1e18 + Double(delay.components.seconds)
            let inner = inner
            queue.asyncAfter(deadline: .now() + seconds) { try? inner.write(line: line) }
        }
        func lines() -> AsyncThrowingStream<String, any Error> { inner.lines() }
        func close() { inner.close() }
    }

    struct Given: DaemonLink {
        let transport: any LineTransport
        func transport() async throws -> any LineTransport { transport }
    }

    /// The calls the Remote made after every connection before #175, in its order, with
    /// one chat open.
    private func before(_ client: DaemonClient, chat: UUID?) async {
        let none = Optional<String>.none
        _ = try? await client.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                                   returning: [DaemonAPI.ProjectSummary].self)
        _ = try? await client.listAgents(DaemonAPI.ListRequest(includeArchived: false, lean: true))
        for method in [DaemonAPI.Method.permissionsPending, DaemonAPI.Method.elicitationsPending,
                       DaemonAPI.Method.attentionPending, DaemonAPI.Method.agentsResuming,
                       DaemonAPI.Method.costState, DaemonAPI.Method.runtimesAllowances,
                       DaemonAPI.Method.leasesSnapshot] {
            _ = try? await client.call(method, none)
        }
        _ = try? await client.call(DaemonAPI.Method.eventsList, DaemonAPI.EventsListRequest(EventFilter()))
        _ = try? await client.call(DaemonAPI.Method.workflowsList, DaemonAPI.WorkflowsListRequest())
        _ = try? await client.call(DaemonAPI.Method.pinsList, DaemonAPI.Empty())
        for method in [DaemonAPI.Method.runtimesList, DaemonAPI.Method.runtimesAccounts,
                       DaemonAPI.Method.modesRemembered, DaemonAPI.Method.sandboxState] {
            _ = try? await client.call(method, none)
        }
        if let chat { await openChat(client, chat) }
    }

    /// The new plan: the snapshot, the chat, and what the pages on screen show.
    private func after(_ client: DaemonClient, chat: UUID?, onScreen: Set<CatchUpPart>) async {
        let none = Optional<String>.none
        for step in CatchUpPlan(chat: chat, onScreen: onScreen).steps {
            switch step {
            case .snapshot: _ = try? await client.catchUp()
            case .chat(let id): await openChat(client, id)
            case .part(.runtimes):
                _ = try? await client.call(DaemonAPI.Method.runtimesList, none)
                _ = try? await client.call(DaemonAPI.Method.runtimesAccounts, none)
            case .part(.costs): _ = try? await client.call(DaemonAPI.Method.costState, none)
            case .part(.sandbox): _ = try? await client.call(DaemonAPI.Method.sandboxState, none)
            case .part(.leases): _ = try? await client.call(DaemonAPI.Method.leasesSnapshot, none)
            case .part(.workflows): _ = try? await client.call(DaemonAPI.Method.workflowsList, DaemonAPI.WorkflowsListRequest())
            case .part(.pins): _ = try? await client.call(DaemonAPI.Method.pinsList, DaemonAPI.Empty())
            case .part(.allowances): _ = try? await client.call(DaemonAPI.Method.runtimesAllowances, none)
            case .part(.modes): _ = try? await client.call(DaemonAPI.Method.modesRemembered, none)
            }
        }
    }

    /// The open chat, as `loadTranscript` reads it: its record whole, its turns, its page.
    private func openChat(_ client: DaemonClient, _ id: UUID) async {
        _ = try? await client.call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest.whole(id), returning: [Agent].self)
        _ = try? await client.call(DaemonAPI.Method.agentsTurns, DaemonAPI.TurnsRequest(agentID: id))
        _ = try? await client.call(DaemonAPI.Method.agentsTranscript, DaemonAPI.TranscriptRequest(agentID: id, limit: 60))
    }

    @Test func theNewPlanAsksLessThanTheOldSequence() async throws {
        let root = URL(fileURLWithPath: "/tmp/cu-\(UUID().uuidString.prefix(8))")
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        // 30 projects, 3,000 agents of which 600 live: past one page of live agents (#164).
        var folders: [URL] = []
        for n in 0..<30 {
            let folder = root.appendingPathComponent("work/p\(n)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            folders.append(try await core.addProject(folder).folder)
        }
        var chat: UUID?
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for n in 0..<3_000 {
            var agent = Agent(runtimeID: "claude", cwd: folders[n % folders.count], title: "agent \(n)",
                              state: n % 5 == 0 ? .finished : .archived)
            agent.lastActivityAt = base.addingTimeInterval(Double(n))
            agent.archivedAt = agent.state == .archived ? base : nil
            if n == 5 { chat = agent.id }
            await core.changed(agent)
        }

        let server = DaemonServer(url: locations.socket) { context, method, params in
            await core.handle(method: method, params: params, from: context.surface, connection: context.id)
        }
        try server.start()
        defer { server.stop() }

        var lines: [String] = []
        for delay in [Duration.zero, .milliseconds(50)] {
            let counted = Counted(try await SocketLink(locations: locations).transport(), delay: delay)
            let client = DaemonClient(link: Given(transport: counted))
            try await client.connect(startIfNeeded: false)
            for (name, open) in [("project list", nil as UUID?), ("chat open", chat)] {
                let chatParts: Set<CatchUpPart> = open == nil ? [] : [.runtimes, .costs, .sandbox, .leases]
                // Once each to warm up, then measured.
                await before(client, chat: open)
                await after(client, chat: open, onScreen: chatParts)
                counted.reset()
                var clock = ContinuousClock.now
                await before(client, chat: open)
                let oldTime = ContinuousClock.now - clock, oldCalls = counted.requests
                counted.reset()
                clock = ContinuousClock.now
                await after(client, chat: open, onScreen: chatParts)
                let newTime = ContinuousClock.now - clock, newCalls = counted.requests
                lines.append("\(name), +\(delay) per call: before \(oldCalls) calls in \(oldTime); "
                             + "after \(newCalls) calls in \(newTime)")
                #expect(newCalls < oldCalls)
            }
            await client.disconnect()
        }
        print("catch-up measured (#175):\n" + lines.joined(separator: "\n"))
    }
}
