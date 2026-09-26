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
        script.updatesOnFirstTurnOnly = true
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

    /// Wait for the turn's edits to reach the list: `count` files and `edits` edits in
    /// all, none still being made. Waiting for the turn to end is not enough — its
    /// updates are written as they are heard, and a list read between two edits is a
    /// true list of fewer.
    private func list(_ core: DaemonCore, _ id: UUID, count: Int, edits: Int? = nil) async -> ChangesList? {
        await eventuallySome("\(count) changed files") {
            guard let list = try? await core.changesList(.init(agentID: id)),
                  list.files.count == count, !list.files.contains(where: \.inProgress),
                  edits.map({ $0 == list.files.reduce(0) { $0 + $1.editCount } }) ?? true
            else { return nil }
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

        let listed = try #require(await list(core, id, count: 2, edits: 3))
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

    // MARK: Git (US3, US4)

    /// A repository with `a.swift` committed, and an agent in it whose runtime reported
    /// one edit to it and made `b.md`. The disk already holds what those edits made.
    private func agentInRepository(expecting files: Int = 2,
                                   _ launcherUpdates: (String, String) -> [JSONValue] = { a, b in
        FakeACPAgent.claudeEdit(id: "e1", path: a, oldText: "two\n", newText: "TWO\n")
            + FakeACPAgent.claudeEdit(id: "e2", path: b, oldText: nil, newText: "# B\n")
    }) async throws -> (DaemonCore, UUID, URL, String, String, String) {
        let (locations, work) = try temporary()
        try repository(at: work)
        let a = try write("one\ntwo\n", to: "a.swift", in: work)
        try git(["add", "."], in: work)
        try git(["commit", "-q", "-m", "a"], in: work)
        let head = try git(["rev-parse", "HEAD"], in: work)
        let b = work.appending(path: "b.md").path
        let core = try core(launcher(sending: launcherUpdates(a, b)), locations: locations)
        _ = try write("one\nTWO\n", to: "a.swift", in: work)
        _ = try write("# B\n", to: "b.md", in: work)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        _ = await eventuallySome("the starting point was taken") { await core.agent(id)?.startingPoint }
        _ = try #require(await list(core, id, count: files, edits: files))
        return (core, id, work, head, a, b)
    }

    @Test func gitFillsInWhatTheRuntimeDidNotReport() async throws {
        let (core, id, work, head, a, b) = try await agentInRepository()

        var listed = try await core.changesList(.init(agentID: id))
        #expect(listed.git == .shared(since: head))
        #expect(listed.files.map(\.path) == [a, b])
        #expect(listed.files.map(\.source) == [.reportedAndSeen, .reportedAndSeen])
        #expect(listed.files[0].beyondReported == false, "the edit accounts for the file")
        #expect(listed.files[1].state == .added)

        // A formatter runs: it touches the reported file and one nobody reported.
        _ = try write("one\nTWO\nformatted\n", to: "a.swift", in: work)
        let c = try write("let c = 1\n", to: "c.swift", in: work)
        listed = try await core.changesList(.init(agentID: id))
        #expect(listed.files.map(\.path) == [a, b, c])
        #expect(listed.files[0].beyondReported)
        #expect(listed.files[2].source == .seen)
        #expect(listed.files[2].added == 1)
    }

    @Test func whatTheAgentCommittedStaysListed() async throws {
        let (core, id, work, _, a, _) = try await agentInRepository()
        try git(["add", "."], in: work)
        try git(["commit", "-q", "-m", "the agent's work"], in: work)
        let listed = try await core.changesList(.init(agentID: id))
        #expect(listed.files.first?.path == a)
        #expect(listed.files.first?.source == .reportedAndSeen)
        #expect(listed.files.first?.added == 1)
    }

    @Test func noStartingPointMeansUncommittedAgainstHead() async throws {
        let (core, id, _, _, _, _) = try await agentInRepository()
        var agent = try #require(await core.agent(id))
        agent.startingPoint = nil
        await core.changed(agent)
        #expect(try await core.changesList(.init(agentID: id)).git == .sharedFromHead)
    }

    @Test func anAgentsOwnWorktreeIsItsOwnAndASharedOneIsNot() async throws {
        let (core, id, work, head, _, _) = try await agentInRepository()
        var agent = try #require(await core.agent(id))
        agent.worktree = AgentWorktree(name: "w", root: work, branch: "agents/w", project: work,
                                       base: "main", madeByApp: true)
        await core.changed(agent)
        #expect(try await core.changesList(.init(agentID: id)).git == .owned(since: head))

        let other = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "also"))
        #expect(await core.agent(other) != nil)
        #expect(try await core.changesList(.init(agentID: id)).git == .shared(since: head))
    }

    @Test func aBinaryFileIsListedWithoutCounts() async throws {
        let (core, id, work, _, _, _) = try await agentInRepository()
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 1, 2]).write(to: work.appending(path: "image.png"))
        let listed = try await core.changesList(.init(agentID: id))
        let image = try #require(listed.files.first { $0.fileName == "image.png" })
        #expect(image.state == .binary)
        #expect(image.added == nil)
    }

    @Test func aReportedPathOutsideTheRepositoryIsNeverGivenToGit() async throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "outside-\(UUID().uuidString).txt").resolvingSymlinksInPath()
        try Data("x\n".utf8).write(to: outside)
        let (core, id, _, _, _, _) = try await agentInRepository(expecting: 3) { a, b in
            FakeACPAgent.claudeEdit(id: "e1", path: a, oldText: "two\n", newText: "TWO\n")
                + FakeACPAgent.claudeEdit(id: "e2", path: b, oldText: nil, newText: "# B\n")
                + FakeACPAgent.claudeEdit(id: "e3", path: outside.path, oldText: "w\n", newText: "x\n")
        }
        let listed = try #require(await list(core, id, count: 3))
        let row = try #require(listed.files.first { $0.path == outside.path })
        #expect(row.outsideFolder)
        #expect(row.source == .reported)
        let detail = try await core.changesFile(.init(agentID: id, path: outside.path, whole: true))
        #expect(detail.whole == nil)
    }

    @Test func theWholeFileMarksWhatChangedAndNothingElse() async throws {
        let (core, id, _, _, a, b) = try await agentInRepository()
        let whole = try #require(try await core.changesFile(.init(agentID: id, path: a, whole: true)).whole)
        #expect(whole.map(\.kind) == [.context, .removed, .added])
        #expect(whole.map(\.text) == ["one", "two", "TWO"])

        let made = try #require(try await core.changesFile(.init(agentID: id, path: b, whole: true)).whole)
        #expect(made.map(\.kind) == [.added])
    }

    /// SC-005: nothing the pane asks writes to the repository.
    @Test func askingLeavesTheRepositoryAsItWas() async throws {
        let (core, id, work, _, a, _) = try await agentInRepository()
        let index = work.appending(path: ".git/index")
        let bytes = try Data(contentsOf: index)
        let modified = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let status = try git(["-c", "core.fsmonitor=false", "status", "--porcelain"], in: work)
        // `git status` above may itself have refreshed the index; measure from after it.
        let settled = try Data(contentsOf: index)
        let settledDate = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date

        for _ in 0..<3 {
            _ = try await core.changesList(.init(agentID: id))
            _ = try await core.changesFile(.init(agentID: id, path: a))
            _ = try await core.changesFile(.init(agentID: id, path: a, whole: true))
            #expect(!FileManager.default.fileExists(atPath: work.appending(path: ".git/index.lock").path))
        }

        #expect(try Data(contentsOf: index) == settled)
        #expect(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date == settledDate)
        #expect(try git(["status", "--porcelain"], in: work) == status)
        _ = (bytes, modified)
    }

    // MARK: SC-004

    /// Two hundred changed files: the list under a second, a file under half a second.
    /// Measured, and printed, so the numbers can be written down; the bounds are the
    /// spec's, with room for a loaded machine.
    @Test(.flakyUnderLoad) func twoHundredFilesAreQuickToList() async throws {
        let (locations, work) = try temporary()
        try repository(at: work)
        var updates: [JSONValue] = []
        for n in 0..<200 {
            let name = "f\(n).swift"
            _ = try write(String(repeating: "let v\(n) = 1\n", count: 40), to: name, in: work)
            updates += FakeACPAgent.claudeEdit(id: "e\(n)", path: work.appending(path: name).path,
                                               oldText: "let v\(n) = 1\n", newText: "let v\(n) = 2\n")
        }
        try git(["add", "."], in: work)
        try git(["commit", "-q", "-m", "two hundred"], in: work)
        for n in 0..<200 {
            let body = "let v\(n) = 2\n" + String(repeating: "let v\(n) = 1\n", count: 39)
            _ = try write(body, to: "f\(n).swift", in: work)
        }
        let core = try core(launcher(sending: updates), locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        _ = await eventuallySome("the starting point was taken") { await core.agent(id)?.startingPoint }
        _ = try #require(await list(core, id, count: 200, edits: 200))

        let clock = ContinuousClock()
        var listing: [Duration] = []
        for _ in 0..<3 {
            let started = clock.now
            let listed = try await core.changesList(.init(agentID: id))
            listing.append(clock.now - started)
            #expect(listed.files.count == 200)
        }
        let path = work.appending(path: "f199.swift").path
        var file: [Duration] = []
        for _ in 0..<3 {
            let started = clock.now
            _ = try await core.changesFile(.init(agentID: id, path: path, whole: true))
            file.append(clock.now - started)
        }
        print("SC-004 changes/list x200: \(listing)  changes/file whole: \(file)")
        #expect(listing.min()! < .seconds(1))
        #expect(file.min()! < .milliseconds(500))
    }
}
