import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A device reading an agent's folder through the daemon (034).
///
/// The phone has no disk to read, so the daemon reads for it, with the same readers the
/// Mac's pane uses and behind the same boundary as `show_file`. What is checked here is
/// that boundary, what comes back, and that a watch belongs to the connection that
/// asked for it and to nobody else.
@Suite("Reading files for a device", .timeLimit(.minutes(1)))
struct FilesRequestTests {
    /// What went out, and to whom: the addressed door evaluated against the connection
    /// ids a test says are there.
    actor Deliveries {
        private var sent: [(method: String, params: JSONValue?, to: Set<UUID>)] = []

        func record(_ method: String, _ params: JSONValue?, to: Set<UUID>) {
            sent.append((method, params, to))
        }

        func changes(for connection: UUID) -> [DaemonAPI.FilesChangedNotification] {
            sent.compactMap { item in
                guard item.method == DaemonAPI.Notification.filesChanged, item.to.contains(connection) else { return nil }
                return try? item.params?.decode(DaemonAPI.FilesChangedNotification.self)
            }
        }

        func clear() { sent = [] }
    }

    private let phone = UUID()
    private let otherPhone = UUID()

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsFilesRequestTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work.resolvingSymlinksInPath())
    }

    private func core(locations: StoreLocations, deliveries: Deliveries) async throws -> (DaemonCore, FakeLauncher) {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(50)
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: launcher)
        await core.setBroadcaster { _, _ in }
        let connections = [phone, otherPhone]
        await core.setAddressedBroadcaster { method, params, wanted in
            let to = Set(connections.filter { wanted(.init(id: $0, surface: .device($0))) })
            Task { await deliveries.record(method, params, to: to) }
        }
        await core.setConnectionCount(1)
        return (core, launcher)
    }

    private func started(_ core: DaemonCore, in work: URL) async throws -> UUID {
        try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: The boundary

    @Test func outsideTheFoldersIsRefusedWithShowFilesSentence() async throws {
        let (locations, work) = try temporary()
        let (core, _) = try await core(locations: locations, deliveries: Deliveries())
        let id = try await started(core, in: work)
        let outside = locations.root.appendingPathComponent("elsewhere.md")
        try write("secret", to: outside)
        let scope = await core.agents[id]!.folderScope

        do {
            _ = try await core.readFile(.init(agentID: id, path: outside.path))
            Issue.record("read outside the folders")
        } catch let error as JSONRPCError {
            #expect(error.message == scope.refusal(for: outside.path))
        }
        await #expect(throws: JSONRPCError.self) {
            try await core.listFiles(.init(agentID: id, folder: locations.root.path))
        }
    }

    @Test func aLinkThatLeadsOutIsRefusedNotFollowed() async throws {
        let (locations, work) = try temporary()
        let (core, _) = try await core(locations: locations, deliveries: Deliveries())
        let id = try await started(core, in: work)
        let outside = locations.root.appendingPathComponent("elsewhere.md")
        try write("secret", to: outside)
        let link = work.appendingPathComponent("innocent.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        await #expect(throws: JSONRPCError.self) {
            try await core.readFile(.init(agentID: id, path: link.path))
        }
    }

    @Test func anAgentThatIsNotHereIsRefused() async throws {
        let (locations, work) = try temporary()
        let (core, _) = try await core(locations: locations, deliveries: Deliveries())
        await #expect(throws: JSONRPCError.self) {
            try await core.listFiles(.init(agentID: UUID(), folder: work.path))
        }
    }

    // MARK: What comes back

    @Test func aFolderIsListedFoldersFirst() async throws {
        let (locations, work) = try temporary()
        let (core, _) = try await core(locations: locations, deliveries: Deliveries())
        let id = try await started(core, in: work)
        try write("b", to: work.appendingPathComponent("b.txt"))
        try write("a", to: work.appendingPathComponent("zeta/inner.txt"))

        let listing = try await core.listFiles(.init(agentID: id, folder: work.path))
        let names = listing.entries.map(\.name)
        #expect(names.first == "zeta")
        #expect(names.contains("b.txt"))
        #expect(listing.omitted == 0)

        // And it survives the wire, which is the point of it.
        let carried = try JSONValue.encoding(listing).decode(DirectoryListing.self)
        #expect(carried.entries.map(\.name) == names)
    }

    @Test func aFileIsReadAsWhatItIs() async throws {
        let (locations, work) = try temporary()
        let (core, _) = try await core(locations: locations, deliveries: Deliveries())
        let id = try await started(core, in: work)
        let plan = work.appendingPathComponent("plan.md")
        try write("# Plan\n", to: plan)

        let first = try await core.readFile(.init(agentID: id, path: plan.path))
        guard case .text(let text, _, _, _) = first else { Issue.record("not text"); return }
        #expect(text == "# Plan\n")
        #expect(try await core.readFile(.init(agentID: id, path: plan.path, knownStamp: first.stamp))
                == .unchanged(first.stamp))

        let picture = work.appendingPathComponent("d.svg")
        try write(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#, to: picture)
        guard case .image = try await core.readFile(.init(agentID: id, path: picture.path)) else {
            Issue.record("not a picture"); return
        }
    }

    @Test func goneAndFolderAreSaidNotShown() async throws {
        let (locations, work) = try temporary()
        let (core, _) = try await core(locations: locations, deliveries: Deliveries())
        let id = try await started(core, in: work)

        do {
            _ = try await core.readFile(.init(agentID: id, path: work.appendingPathComponent("nope.md").path))
            Issue.record("read a file that is not there")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.fileGone)
        }
        do {
            _ = try await core.readFile(.init(agentID: id, path: work.path))
            Issue.record("read a folder as a file")
        } catch let error as JSONRPCError {
            #expect(error.message == "That is a folder.")
        }
        do {
            _ = try await core.listFiles(.init(agentID: id, folder: work.appendingPathComponent("gone").path))
            Issue.record("listed a folder that is not there")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.fileGone)
        }
    }

    // MARK: Watching

    @Test func aChangeIsToldOnlyToTheConnectionWatching() async throws {
        let (locations, work) = try temporary()
        let deliveries = Deliveries()
        let (core, _) = try await core(locations: locations, deliveries: deliveries)
        let id = try await started(core, in: work)

        try await core.watchFiles(.init(agentID: id, folder: work.path), connection: phone)
        #expect(await core.fileWatchCount == 1)
        // FSEvents takes a moment to start listening; a write before then is not seen.
        try await Task.sleep(for: .milliseconds(300))
        try write("new", to: work.appendingPathComponent("notes.md"))

        let seen = await eventuallySome("the watching phone was told") {
            let changes = await deliveries.changes(for: phone)
            return changes.isEmpty ? nil : changes
        }
        #expect(seen?.first?.agentID == id)
        #expect(await deliveries.changes(for: otherPhone).isEmpty)
    }

    @Test func aWatchEndsWithItsInterestOrItsConnection() async throws {
        let (locations, work) = try temporary()
        let deliveries = Deliveries()
        let (core, _) = try await core(locations: locations, deliveries: deliveries)
        let id = try await started(core, in: work)
        let request = DaemonAPI.FilesWatchRequest(agentID: id, folder: work.path)

        try await core.watchFiles(request, connection: phone)
        try await core.watchFiles(request, connection: otherPhone)
        #expect(await core.fileWatchCount == 1, "one watch per root, shared")

        await core.unwatchFiles(request, connection: phone)
        #expect(await core.fileWatchCount == 1, "still wanted by the other")

        await core.connectionEnded(otherPhone)
        #expect(await core.fileWatchCount == 0)

        await deliveries.clear()
        try write("after", to: work.appendingPathComponent("late.md"))
        try await Task.sleep(for: .milliseconds(600))
        #expect(await deliveries.changes(for: phone).isEmpty)
        #expect(await deliveries.changes(for: otherPhone).isEmpty)
    }

    @Test func aSubfolderIsWatchedUnderItsRoot() async throws {
        let (locations, work) = try temporary()
        let (core, _) = try await core(locations: locations, deliveries: Deliveries())
        let id = try await started(core, in: work)
        try write("x", to: work.appendingPathComponent("src/a.swift"))

        try await core.watchFiles(.init(agentID: id, folder: work.path), connection: phone)
        try await core.watchFiles(.init(agentID: id, folder: work.appendingPathComponent("src").path),
                                  connection: phone)
        #expect(await core.fileWatchCount == 1)
    }
}
