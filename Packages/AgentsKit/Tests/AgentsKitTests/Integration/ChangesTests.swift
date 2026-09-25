import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What an agent changed, as the daemon answers it (035).
///
/// A fake runtime sends its edits the way Claude does — each diff twice, then the
/// ending — and the daemon's list has to come out as the conversation shows them.
@Suite("What an agent changed", .timeLimit(.minutes(1)))
struct ChangesTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsChangesTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work.resolvingSymlinksInPath())
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    private func launcher(sending updates: [JSONValue]) -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.updates = updates
        return FakeLauncher(script: script)
    }

    private func write(_ text: String, to name: String, in folder: URL) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @discardableResult
    private func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repository(at folder: URL) throws {
        try git(["init", "-q", "-b", "main"], in: folder)
        try git(["config", "user.email", "test@example.com"], in: folder)
        try git(["config", "user.name", "Test"], in: folder)
        _ = try write("seed\n", to: "seed.txt", in: folder)
        try git(["add", "."], in: folder)
        try git(["commit", "-q", "-m", "seed"], in: folder)
    }

    /// Wait for the turn's edits to reach the list.
    private func list(_ core: DaemonCore, _ id: UUID, count: Int) async -> ChangesList? {
        await eventuallySome("\(count) changed files") {
            guard let list = try? await core.changesList(.init(agentID: id)),
                  list.files.count == count, !list.files.contains(where: \.inProgress) else { return nil }
            return list
        }
    }

    @Test func reportedEditsAreListedInOrderWithoutGit() async throws {
        let (locations, work) = try temporary()
        let a = try write("one\nthree\n", to: "a.swift", in: work)
        let b = try write("# New\n", to: "b.md", in: work)
        let updates = FakeACPAgent.claudeEdit(id: "e1", path: a, oldText: "one\n", newText: "one\ntwo\n")
            + FakeACPAgent.claudeEdit(id: "e2", path: b, oldText: nil, newText: "# New\n")
            + FakeACPAgent.claudeEdit(id: "e3", path: a, oldText: "two\n", newText: "three\n")
            + FakeACPAgent.claudeEdit(id: "e4", path: a, oldText: "x", newText: "y", ending: "failed")
        let core = try core(launcher(sending: updates), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let listed = try #require(await list(core, id, count: 2))
        #expect(listed.files.map(\.path) == [a, b])
        #expect(listed.files[0].editCount == 2, "the failed edit is not one")
        #expect(listed.files[0].state == .modified)
        #expect(listed.files[0].source == .reported)
        #expect(listed.files[0].relativePath == "a.swift")
        #expect(listed.files[1].state == .added)
        #expect(listed.files[1].firstLine == 1)
        #expect(listed.git == .unavailable(.notARepository))
        #expect(listed.reportsEdits)

        let detail = try await core.changesFile(.init(agentID: id, path: a))
        #expect(detail.edits.map(\.toolCallID) == ["e1", "e3"])
        #expect(detail.edits.first?.oldText == "one\n")

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.changesFile(.init(agentID: id, path: work.appending(path: "c.swift").path))
        }
    }

    @Test func anAgentThatChangedNothingSaysSo() async throws {
        let (locations, work) = try temporary()
        let core = try core(launcher(sending: [FakeACPAgent.chunk("hello")]), locations: locations)
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        let listed = try await core.changesList(.init(agentID: id))
        #expect(listed.files.isEmpty)
        #expect(!listed.reportsEdits)
    }

    @Test func aFileDeletedAfterItsEditsIsMarkedAndKeepsThem() async throws {
        let (locations, work) = try temporary()
        let a = try write("x\n", to: "a.swift", in: work)
        let core = try core(launcher(sending: FakeACPAgent.claudeEdit(id: "e1", path: a,
                                                                      oldText: "w\n", newText: "x\n")),
                            locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        _ = try #require(await list(core, id, count: 1))
        try FileManager.default.removeItem(atPath: a)

        let listed = try await core.changesList(.init(agentID: id))
        #expect(listed.files.first?.state == .deleted)
        let detail = try await core.changesFile(.init(agentID: id, path: a))
        #expect(detail.edits.count == 1)
    }

    @Test func aStartInARepositoryRecordsWhereItStarted() async throws {
        let (locations, work) = try temporary()
        try repository(at: work)
        let head = try git(["rev-parse", "HEAD"], in: work)
        let core = try core(launcher(sending: []), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let point = try #require(await eventuallySome("the starting point was taken") {
            await core.agent(id)?.startingPoint
        })
        #expect(point.commit == head)
        #expect(point.repository.resolvingSymlinksInPath().path == work.path)
    }

    @Test func aStartOutsideARepositoryRecordsNothing() async throws {
        let (locations, work) = try temporary()
        let core = try core(launcher(sending: []), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        #expect(await core.agent(id)?.startingPoint == nil)
    }
}
