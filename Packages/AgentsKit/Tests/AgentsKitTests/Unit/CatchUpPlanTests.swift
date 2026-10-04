import Foundation
import Testing
@testable import AgentsKitCore

/// A client catching up after a connection asks for what is on screen and no more, and
/// lets go of what no screen shows (#175).
@Suite("Catch-up plan and letting go")
struct CatchUpPlanTests {
    // MARK: The plan

    @Test func theProjectListAloneIsOneCall() {
        #expect(CatchUpPlan(chat: nil, onScreen: []).steps == [.snapshot])
    }

    @Test func anOpenChatComesNextThenThePagesParts() {
        let chat = UUID()
        let plan = CatchUpPlan(chat: chat, onScreen: [.costs, .workflows, .runtimes])
        // The snapshot first, the chat second, then the parts in a fixed order.
        #expect(plan.steps == [.snapshot, .chat(chat), .part(.workflows), .part(.runtimes), .part(.costs)])
        #expect(plan.parts == [.workflows, .runtimes, .costs])
    }

    // MARK: What is on screen

    @Test func nothingIsReadWhileDisconnectedAndTheCatchUpReadsWhatIsShown() {
        var parts = OnScreenParts()
        let r1 = parts.appeared([.workflows, .pins]).isEmpty
        #expect(r1)
        let plan = parts.plan(chat: nil)
        #expect(plan.parts == [.workflows, .pins])
        // Read on this connection: shown again, not read again.
        let r2 = parts.appeared([.workflows]).isEmpty
        #expect(r2)
        // A part not read yet is read as its page appears.
        let r3 = parts.appeared([.costs, .workflows])
        #expect(r3 == [.costs])
    }

    @Test func aPageThatHasGoneIsNotCaughtUpOn() {
        var parts = OnScreenParts()
        _ = parts.plan(chat: nil)
        _ = parts.appeared([.workflows])
        _ = parts.appeared([.workflows, .leases])
        parts.disappeared([.workflows, .leases])
        // One page still shows workflows.
        #expect(parts.onScreen == [.workflows])
        parts.disappeared([.workflows])
        #expect(parts.onScreen.isEmpty)
        parts.connectionLost()
        let r4 = parts.plan(chat: nil).steps
        #expect(r4 == [.snapshot])
    }

    @Test func aLostConnectionForgetsWhatWasRead() {
        var parts = OnScreenParts()
        _ = parts.plan(chat: nil)
        _ = parts.appeared([.runtimes])
        parts.connectionLost()
        let plan = parts.plan(chat: nil)
        #expect(plan.parts == [.runtimes])
    }

    @Test func aChangeOffScreenIsReadWhenAPageShowsIt() {
        var parts = OnScreenParts()
        _ = parts.plan(chat: nil)
        _ = parts.appeared([.runtimes])
        let r5 = parts.changed(.runtimes)
        #expect(r5)
        parts.disappeared([.runtimes])
        let not24 = parts.changed(.runtimes)
        #expect(!not24)
        let r6 = parts.appeared([.runtimes])
        #expect(r6 == [.runtimes])
    }

    // MARK: Caches

    @Test func theLeastRecentlyUsedGoesFirst() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        let read = cache.value(for: "a")
        #expect(read == 1)
        cache.set(3, for: "c")
        #expect(cache.count == 2)
        #expect(cache.peek("b") == nil)
        #expect(cache.peek("a") == 1)
        #expect(cache.peek("c") == 3)
        // Peeking does not count as use.
        _ = cache.peek("a")
        cache.set(4, for: "d")
        #expect(Set(cache.keys) == ["c", "d"])
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func archivedAgentsOutsideTheOpenProjectAreLetGo() {
        let here = URL(filePath: "/work/here", directoryHint: .isDirectory)
        let there = URL(filePath: "/work/there", directoryHint: .isDirectory)
        func agent(_ folder: URL, _ state: AgentState) -> Agent {
            Agent(runtimeID: "claude", cwd: folder, title: "a", state: state)
        }
        let archivedHere = agent(here, .archived)
        let archivedThere = agent(there, .archived)
        let openThere = agent(there, .archived)
        let liveThere = agent(there, .running)
        let all = [archivedHere, archivedThere, openThere, liveThere]
        let letGo = ClientHolding.archivedToLetGo(all, project: here, chat: openThere.id)
        #expect(letGo == [archivedThere.id])
        // No project open: every archived one but the open chat.
        #expect(Set(ClientHolding.archivedToLetGo(all, project: nil, chat: nil))
                == [archivedHere.id, archivedThere.id, openThere.id])
    }

    // MARK: The widget's file

    @Test func theSameCountIsWrittenAgainOnceItGrowsOld() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let old = AttentionSnapshot(writtenAt: at, total: 2, sessions: [])
        #expect(AttentionSnapshot(writtenAt: at, total: 2, sessions: []).needsWriting(over: nil))
        #expect(!AttentionSnapshot(writtenAt: at.addingTimeInterval(60), total: 2, sessions: []).needsWriting(over: old))
        #expect(AttentionSnapshot(writtenAt: at.addingTimeInterval(60), total: 3, sessions: []).needsWriting(over: old))
        #expect(AttentionSnapshot(writtenAt: at.addingTimeInterval(AttentionSnapshot.staleness / 3), total: 2,
                                  sessions: []).needsWriting(over: old))
    }

    @Test func theStoreDoesNotReadTheFileBackWhenTold() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let first = AttentionSnapshot(writtenAt: at, total: 1, sessions: [])
        #expect(AttentionSnapshotStore.write(first, into: folder))
        let same = AttentionSnapshot(writtenAt: at.addingTimeInterval(1), total: 1, sessions: [])
        #expect(!AttentionSnapshotStore.write(same, into: folder, over: first))
        #expect(!AttentionSnapshotStore.write(same, into: folder))
    }

    // MARK: The device log

    @Test func theLogRollsOverAtItsLimitAndKeepsOneBefore() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = RollingLog(url: folder.appendingPathComponent("remote.log"), limit: 1_024)
        #expect(log.previous.lastPathComponent == "remote.1.log")
        for n in 0..<100 { log.append("link: attempt \(n) failed") }
        log.flush()
        let size = { (url: URL) in
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        }
        #expect(size(log.url) > 0 && size(log.url) <= 1_024)
        #expect(size(log.previous) > 0 && size(log.previous) <= 1_024)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.hasSuffix("link: attempt 99 failed\n"))
        // Every line stamped with when it was said.
        let line = try #require(text.split(separator: "\n").first)
        #expect(line.contains("T") && line.contains("Z link: attempt"))
    }

    // MARK: Folder watches

    /// A host that answers every call with `{}` and counts what it was asked.
    final class Counting: DaemonLink, @unchecked Sendable {
        private let lock = NSLock()
        private var methods: [String] = []
        var asked: [String] { lock.withLock { methods } }

        func transport() async throws -> any LineTransport {
            let (near, far) = PairedTransport.pair()
            _ = Task { [self] in
                for try await line in far.lines() {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = object["id"] as? Int, let method = object["method"] as? String else { continue }
                    lock.withLock { methods.append(method) }
                    try? far.write(line: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
                }
            }
            return near
        }
    }

    @Test @MainActor func aFolderIsWatchedWhileAPaneShowsItAndOnlyThatIsWatchedAgain() async throws {
        let host = Counting()
        let client = DaemonClient(link: host)
        try await client.connect(startIfNeeded: false)
        let files = RemoteFiles(client: client, patience: .seconds(5))
        let agent = UUID()
        let shown = URL(filePath: "/work/a"), gone = URL(filePath: "/work/b")
        await files.watch(agentID: agent, folder: shown)
        await files.watch(agentID: agent, folder: shown)
        await files.watch(agentID: agent, folder: gone)
        #expect(host.asked.filter { $0 == DaemonAPI.Method.filesWatch }.count == 2)
        await files.unwatch(agentID: agent, folder: gone)
        // One of the two panes on `shown` goes: still watched.
        await files.unwatch(agentID: agent, folder: shown)
        #expect(files.watching.map(\.folder) == [shown.path])
        #expect(host.asked.filter { $0 == DaemonAPI.Method.filesUnwatch }.count == 1)
        await files.reconnected()
        #expect(host.asked.filter { $0 == DaemonAPI.Method.filesWatch }.count == 3)
        await files.unwatch(agentID: agent, folder: shown)
        #expect(files.watching.isEmpty)
        #expect(files.anyChange[agent] == nil)
    }
}
