import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Every limit and position a client can send on `agents/turns` and `agents/transcript`
/// (#200). One `agents/turns` with `limit: -1` trapped on a backwards range and took the
/// host down with every agent on it; nonsense is now refused in words, a huge page is cut
/// to the ceiling, and the daemon goes on serving.
@Suite("Page limits and positions", .serialized, .timeLimit(.minutes(1)))
struct PageBoundsTests {
    private func ask(_ text: String) -> TranscriptEntry { TranscriptEntry(kind: .userMessage(text)) }
    private func said(_ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: .agentMessage(messageID: nil, text: text))
    }

    /// A conversation of `turns` finished turns of two entries each, and one still open.
    private func conversation(_ turns: Int) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        for n in 0..<turns { entries += [ask("Q\(n)"), said("A\(n)")] }
        return entries + [ask("Open")]
    }

    private func store() throws -> (AgentStore, StoreLocations) {
        let root = FileManager.default.temporaryDirectory.appending(path: "bounds-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        return (try AgentStore(locations: locations), locations)
    }

    private func refusal(_ body: () async throws -> some Any) async -> JSONRPCError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? JSONRPCError
        }
    }

    // MARK: The store, asked directly

    /// The store is what trapped. Whatever reaches it, it answers with a page.
    @Test func theStoreNeverMakesABackwardsRange() async throws {
        let (store, locations) = try store()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let id = UUID()
        try await store.appendAll(conversation(5), for: id)

        for (before, limit) in [(nil, -1), (nil, Int.min), (-5, 10), (Int.min, 5), (2, -3), (Int.max, -1)] {
            let turns = try await store.turns(for: id, before: before, limit: limit)
            #expect(turns.turns.isEmpty, "turns before \(String(describing: before)), limit \(limit)")
            let page = try await store.transcript(for: id, before: before, limit: limit)
            #expect(page.entries.isEmpty, "transcript before \(String(describing: before)), limit \(limit)")
        }
        #expect(try await store.turns(for: id, limit: Int.max).turns.count == 5)
        #expect(try await store.transcript(for: id, limit: Int.max).entries.count == 11)
    }

    /// The turns before a page are made in the background after it is answered. A
    /// transcript that goes meanwhile (its agent deleted) ends that, rather than the host.
    @Test func turnsMadeInTheBackgroundSurviveTheTranscriptGoing() async throws {
        let (store, locations) = try store()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let id = UUID()
        try await store.appendAll(conversation(30), for: id)
        _ = try await store.turns(for: id, limit: 3)
        try FileManager.default.removeItem(at: locations.transcript(id))
        await store.fillTurns(for: id)
        #expect(try await store.turns(for: id).turns.isEmpty)
    }

    // MARK: The host's calls

    @Test func negativeLimitsAndPositionsAreRefusedInWords() async throws {
        let (store, locations) = try store()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let id = UUID()
        try await store.appendAll(conversation(5), for: id)
        let core = DaemonCore(store: store, locations: locations)

        let turnsLimit = await refusal { try await core.turns(.init(agentID: id, limit: -1)) }
        #expect(turnsLimit?.code == JSONRPCError.invalidParams)
        #expect(turnsLimit?.message == "limit must be 0 or more, not -1.")
        let turnsBefore = await refusal { try await core.turns(.init(agentID: id, before: -1)) }
        #expect(turnsBefore?.code == JSONRPCError.invalidParams)
        #expect(turnsBefore?.message == "before must be 0 or more, not -1.")

        let pageLimit = await refusal { try await core.transcript(.init(agentID: id, limit: Int.min)) }
        #expect(pageLimit?.code == JSONRPCError.invalidParams)
        let pageBefore = await refusal { try await core.transcript(.init(agentID: id, before: -3)) }
        #expect(pageBefore?.code == JSONRPCError.invalidParams)
        let pageFrom = await refusal { try await core.transcript(.init(agentID: id, from: -1)) }
        #expect(pageFrom?.code == JSONRPCError.invalidParams)
        #expect(pageFrom?.message == "from must be 0 or more, not -1.")
    }

    @Test func aZeroLimitIsAnEmptyPage() async throws {
        let (store, locations) = try store()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let id = UUID()
        try await store.appendAll(conversation(5), for: id)
        let core = DaemonCore(store: store, locations: locations)

        let turns = try await core.turns(.init(agentID: id, limit: 0))
        #expect(turns.turns.isEmpty)
        #expect(turns.firstTurn == 5)
        #expect(turns.openStart == 10)
        let page = try await core.transcript(.init(agentID: id, limit: 0))
        #expect(page.entries.isEmpty)
        #expect(page.total == 11)
        let fromPage = try await core.transcript(.init(agentID: id, limit: 0, from: 4))
        #expect(fromPage.entries.isEmpty)
    }

    @Test func aHugeLimitIsCutToTheCeiling() async throws {
        let (store, locations) = try store()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let id = UUID()
        // Two entries a turn: past both ceilings.
        let turnCount = DaemonAPI.TranscriptRequest.limitCeiling / 2 + 50
        try await store.appendAll(conversation(turnCount), for: id)
        let core = DaemonCore(store: store, locations: locations)

        let turns = try await core.turns(.init(agentID: id, limit: Int.max))
        #expect(turns.turns.count == DaemonAPI.TurnsRequest.limitCeiling)
        #expect(turns.firstTurn == turnCount - DaemonAPI.TurnsRequest.limitCeiling)
        // A position past the end is the end.
        let past = try await core.turns(.init(agentID: id, before: Int.max, limit: 3))
        #expect(past.turns.map { $0.ask?.text } == ["Q547", "Q548", "Q549"])

        let page = try await core.transcript(.init(agentID: id, limit: Int.max))
        #expect(page.entries.count == DaemonAPI.TranscriptRequest.limitCeiling)
        #expect(page.firstIndex == page.total - DaemonAPI.TranscriptRequest.limitCeiling)
        // A whole long turn asked for at once comes back as its last page.
        let turn = try await core.transcript(.init(agentID: id, before: page.total, limit: Int.max, from: 0))
        #expect(turn.entries.count == DaemonAPI.TranscriptRequest.limitCeiling)
        #expect(turn.firstIndex == page.total - DaemonAPI.TranscriptRequest.limitCeiling)
    }

    // MARK: Over the socket

    /// Socket paths live in a 104-byte struct, so the root is kept short on purpose.
    private func shortLocations() throws -> StoreLocations {
        let root = URL(fileURLWithPath: "/tmp/agb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StoreLocations(root: root)
    }

    private func client(to locations: StoreLocations) async throws -> JSONRPCConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            locations.socket.path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        #expect(result == 0, "could not reach the daemon socket")
        let connection = JSONRPCConnection(transport: FDTransport(socket: fd))
        await connection.start()
        return connection
    }

    /// Every bad request a paired client could send, over the real socket: each is answered
    /// with invalid params, and the daemon still answers a ping and a good page after.
    @Test func badRequestsAreAnsweredAndTheDaemonGoesOnServing() async throws {
        let locations = try shortLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let id = UUID()
        try await AgentStore(locations: locations).appendAll(conversation(5), for: id)
        let daemon = try Daemon(locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }
        let connection = try await client(to: locations)
        let agent = JSONValue.string(id.uuidString)

        let bad: [(String, JSONValue)] = [
            (DaemonAPI.Method.agentsTurns, ["agentID": agent, "limit": -1]),
            (DaemonAPI.Method.agentsTurns, ["agentID": agent, "before": -1]),
            (DaemonAPI.Method.agentsTurns, ["agentID": agent, "limit": .int(Int.min)]),
            (DaemonAPI.Method.agentsTurns, ["agentID": agent, "limit": 1.5]),
            (DaemonAPI.Method.agentsTurns, ["agentID": agent, "limit": "ten"]),
            (DaemonAPI.Method.agentsTurns, ["agentID": agent, "limit": 1e30]),
            (DaemonAPI.Method.agentsTranscript, ["agentID": agent, "limit": -1]),
            (DaemonAPI.Method.agentsTranscript, ["agentID": agent, "before": -1]),
            (DaemonAPI.Method.agentsTranscript, ["agentID": agent, "from": -1]),
            (DaemonAPI.Method.agentsTranscript, ["agentID": agent, "limit": 2.5]),
            (DaemonAPI.Method.agentsTranscript, ["agentID": agent, "before": "the end"]),
        ]
        for (method, params) in bad {
            do {
                _ = try await connection.call(method, params, timeout: .seconds(10))
                Issue.record("\(method) \(params) was answered with a page")
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCError.invalidParams, "\(method) \(params): \(error.message)")
            }
        }

        do {
            _ = try await connection.call(DaemonAPI.Method.agentsTurns, ["agentID": agent, "limit": "ten"])
        } catch let error as JSONRPCError {
            #expect(error.message == "TurnsRequest: limit is not a whole number.")
        }

        _ = try await connection.call(DaemonAPI.Method.ping, timeout: .seconds(10))
        let huge = try await connection.call(DaemonAPI.Method.agentsTurns, ["agentID": agent, "limit": .int(Int.max)],
                                             timeout: .seconds(10))
        #expect(huge["turns"]?.arrayValue?.count == 5)
        let empty = try await connection.call(DaemonAPI.Method.agentsTranscript, ["agentID": agent, "limit": 0],
                                              timeout: .seconds(10))
        #expect(empty["entries"]?.arrayValue?.isEmpty == true)
        await connection.close()
    }
}
