import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A project from a Git URL (027), against real git and real repositories, offline.
///
/// People paste `https://` and `ssh://` URLs, so those are what the tests paste. The
/// daemon checks them as pasted and then, in tests only, hands git a local bare
/// repository instead — `setCloneParent(_:rewrite:)`. Everything after that is the
/// real clone, the real move and the real `addProject`.
@Suite("Clone project", .timeLimit(.minutes(1)))
struct CloneProjectTests {
    /// A store, a stand-in home folder, and a place bare repositories live.
    private struct World {
        var locations: StoreLocations
        var home: URL
        var remotes: URL
        var core: DaemonCore
        var heard: CloneBroadcasts
    }

    private func world() async throws -> World {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsCloneTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let remotes = root.appending(path: "remotes", directoryHint: .isDirectory)
        let store = root.appending(path: "store", directoryHint: .isDirectory)
        for folder in [home, remotes, store] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let locations = StoreLocations(root: store)
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        // Any spelling of a repository goes to the bare one with the same path.
        let rewrite: @Sendable (String) -> String = { url in
            let path = GitRemote(url)!.path
            return remotes.appending(path: path.hasSuffix(".git") ? path : path + ".git").path
        }
        await core.setCloneParent(home, rewrite: rewrite)
        let heard = CloneBroadcasts()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.cloneChanged,
                  let notification = try? params?.decode(DaemonAPI.CloneNotification.self) else { return }
            heard.append(notification)
        }
        return World(locations: locations, home: home, remotes: remotes, core: core, heard: heard)
    }

    /// A bare repository at `remotes/<path>` with one commit, and that commit's id.
    @discardableResult
    private func repository(_ world: World, _ path: String, file: String = "README.md") throws -> String {
        let work = world.remotes.appending(path: "work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: work)
        try "hello\n".write(to: work.appending(path: file), atomically: true, encoding: .utf8)
        try git(["add", "."], in: work)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "commit", "-q", "-m", "first"], in: work)
        let bare = world.remotes.appending(path: path)
        try FileManager.default.createDirectory(at: bare.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(["clone", "-q", "--bare", work.path, bare.path], in: world.remotes)
        return try git(["rev-parse", "HEAD"], in: work)
    }

    @discardableResult
    private func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func failure(_ error: any Error) -> JSONRPCError? { error as? JSONRPCError }

    private func stagingIsEmpty(_ world: World) -> Bool {
        let staging = world.locations.root.appending(path: "Clones")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        return left.isEmpty
    }

    // MARK: US1

    @Test func aURLBecomesAProjectInTheHomeFolder() async throws {
        let world = try await world()
        let head = try repository(world, "octocat/Hello-World.git")

        let summary = try await world.core.cloneProject("https://github.com/octocat/Hello-World.git")

        let expected = Project.standardize(world.home.appending(path: "Hello-World"))
        #expect(summary.folder == expected)
        #expect(summary.name == "Hello-World")
        #expect(summary.exists)
        #expect(try git(["rev-parse", "HEAD"], in: expected) == head, "the repository's own history")
        #expect(FileManager.default.fileExists(atPath: expected.appending(path: "README.md").path))
        #expect(await world.core.allProjects().map(\.folder) == [expected])
        #expect(stagingIsEmpty(world))
        #expect(await world.core.allClones().isEmpty)
    }

    @Test func everyWindowHearsTheCloneBeginAndEnd() async throws {
        let world = try await world()
        try repository(world, "acme/widget.git")

        _ = try await world.core.cloneProject("git@github.com:acme/widget.git")

        await eventually("start and finish were both broadcast") { world.heard.all.count == 2 }
        let heard = world.heard.all
        #expect(heard.map(\.finished) == [false, true])
        #expect(heard.first?.clone.url == "git@github.com:acme/widget.git")
        #expect(heard.first?.clone.folder.lastPathComponent == "widget")
    }

    @Test func aCloneHoldsTheDaemonUpUntilItEnds() async throws {
        let world = try await world()
        try repository(world, "acme/widget.git")
        #expect(await world.core.isHoldingAgents == false)
        _ = try await world.core.cloneProject("https://github.com/acme/widget")
        #expect(await world.core.isHoldingAgents == false, "and lets it go afterwards")
    }

    // MARK: US2

    @Test func textThatIsNotAURLIsRefusedBeforeAnythingRuns() async throws {
        let world = try await world()
        await #expect(throws: JSONRPCError.self) {
            _ = try await world.core.cloneProject("/Users/somebody/Code/api")
        }
        do {
            _ = try await world.core.cloneProject("not a url")
        } catch {
            #expect(failure(error)?.code == DaemonAPI.Failure.notACloneURL)
        }
        #expect(world.heard.all.isEmpty, "nothing began")
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.home.path).isEmpty)
    }

    @Test func aRepositoryThatIsNotThereLeavesNothingBehind() async throws {
        let world = try await world()
        do {
            _ = try await world.core.cloneProject("https://github.com/nobody/nothing.git")
            Issue.record("a clone of nothing succeeded")
        } catch {
            let failure = try #require(failure(error))
            #expect(failure.code == DaemonAPI.Failure.cloneFailed)
            #expect(failure.message.contains("There is no repository at github.com/nobody/nothing.git"),
                    "\(failure.message)")
        }
        #expect(!FileManager.default.fileExists(atPath: world.home.appending(path: "nothing").path))
        #expect(await world.core.allProjects().isEmpty)
        #expect(stagingIsEmpty(world))
        #expect(await world.core.allClones().isEmpty)
        await eventually("the failed clone still said it ended") { world.heard.all.last?.finished == true }
    }

    @Test func anUnrelatedFolderInTheWayIsRefusedAndUntouched() async throws {
        let world = try await world()
        try repository(world, "acme/notes.git")
        let mine = world.home.appending(path: "notes")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try "mine\n".write(to: mine.appending(path: "diary.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try await world.core.cloneProject("https://github.com/acme/notes.git")
            Issue.record("cloned over somebody's folder")
        } catch {
            let failure = try #require(failure(error))
            #expect(failure.code == DaemonAPI.Failure.folderInTheWay)
            #expect(failure.message.contains("notes"), "names the folder: \(failure.message)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: mine.path) == ["diary.txt"])
        #expect(await world.core.allProjects().isEmpty)
    }

    @Test func aCheckoutOfADifferentRepositoryIsInTheWayToo() async throws {
        let world = try await world()
        try repository(world, "someone/Hello-World.git")
        try repository(world, "octocat/Hello-World.git")
        _ = try await world.core.cloneProject("https://github.com/someone/Hello-World")
        try git(["remote", "set-url", "origin", "https://github.com/someone/Hello-World"],
                in: world.home.appending(path: "Hello-World"))

        do {
            _ = try await world.core.cloneProject("https://github.com/octocat/Hello-World")
            Issue.record("a fork's checkout was taken for the original")
        } catch {
            #expect(failure(error)?.code == DaemonAPI.Failure.folderInTheWay)
        }
    }

    @Test func aFileInTheWayIsRefused() async throws {
        let world = try await world()
        try "not a folder".write(to: world.home.appending(path: "api"), atomically: true, encoding: .utf8)
        do {
            _ = try await world.core.cloneProject("https://github.com/acme/api.git")
            Issue.record("cloned over a file")
        } catch {
            #expect(failure(error)?.code == DaemonAPI.Failure.folderInTheWay)
        }
    }

    @Test func stagingLeftByADaemonThatDiedIsClearedOnStart() async throws {
        let id = UUID().uuidString.prefix(8)
        let root = URL(fileURLWithPath: "/tmp/agc-\(id)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let leftover = root.appending(path: "Clones/\(UUID().uuidString)/half")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "partial".write(to: leftover.appending(path: "pack"), atomically: true, encoding: .utf8)

        let daemon = try Daemon(locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        try await daemon.start()
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Clones").path))
        await daemon.shutDown()
    }

    // MARK: US3

    @Test func aCheckoutAlreadyThereBecomesTheProjectUnchanged() async throws {
        let world = try await world()
        try repository(world, "octocat/Hello-World.git")
        // Cloned by hand months ago, over SSH, and worked on since.
        let checkout = world.home.appending(path: "Hello-World")
        try git(["clone", "-q", world.remotes.appending(path: "octocat/Hello-World.git").path, checkout.path],
                in: world.home)
        try git(["remote", "set-url", "origin", "git@github.com:octocat/Hello-World.git"], in: checkout)
        try git(["checkout", "-q", "-b", "my-branch"], in: checkout)
        try "edited\n".write(to: checkout.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let before = try git(["status", "--porcelain", "--branch"], in: checkout)

        let summary = try await world.core.cloneProject("https://github.com/octocat/Hello-World.git")

        #expect(summary.folder == Project.standardize(checkout))
        #expect(try git(["status", "--porcelain", "--branch"], in: checkout) == before,
                "branch and working changes exactly as they were")
        #expect(world.heard.all.isEmpty, "nothing was cloned")
    }

    @Test func anArchivedProjectIsBroughtBack() async throws {
        let world = try await world()
        try repository(world, "acme/widget.git")
        let first = try await world.core.cloneProject("https://github.com/acme/widget.git")
        _ = try await world.core.archiveProject(first.folder)
        // The remote the clone recorded is the local bare path the test handed git;
        // point it at what a person would have cloned.
        try git(["remote", "set-url", "origin", "https://github.com/acme/widget.git"], in: first.folder)

        let again = try await world.core.cloneProject("git@github.com:acme/widget.git")
        #expect(again.folder == first.folder)
        #expect(again.project.isArchived == false)
    }

    @Test func aProjectAlreadyAddedIsReturnedAsItIs() async throws {
        let world = try await world()
        try repository(world, "acme/widget.git")
        let first = try await world.core.cloneProject("https://github.com/acme/widget.git")
        try git(["remote", "set-url", "origin", "https://github.com/acme/widget.git"], in: first.folder)

        let again = try await world.core.cloneProject("https://github.com/acme/widget")
        #expect(again.folder == first.folder)
        #expect(await world.core.allProjects().count == 1)
    }
}

private final class CloneBroadcasts: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications: [DaemonAPI.CloneNotification] = []

    func append(_ notification: DaemonAPI.CloneNotification) {
        lock.lock(); defer { lock.unlock() }
        notifications.append(notification)
    }

    var all: [DaemonAPI.CloneNotification] {
        lock.lock(); defer { lock.unlock() }
        return notifications
    }
}
