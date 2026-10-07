import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The chat project (#229): `~/.agents/chat`, made once by each host's daemon so a chat
/// needs no project picked. Every test hands in a home made for it, or none: nothing
/// here reads `$HOME` or `AGENTS_PERSONAL_HOME`.
@Suite("Chat project", .timeLimit(.minutes(1)))
struct ChatProjectTests {
    private let fileManager = FileManager.default

    private func temporary(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChatProjectTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A core on a fresh root, with this home or none.
    private func core(home: URL?) async throws -> DaemonCore {
        var locations = StoreLocations(root: try temporary("root"))
        locations.personalHome = home
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        return core
    }

    /// The folder in the form the daemon keeps it in.
    private func chatFolder(_ home: URL) -> URL {
        Project.standardize(Project.standardize(home).appending(path: ".agents/chat"))
    }

    /// Every file under a folder, with its contents and when it last changed.
    private func snapshot(_ folder: URL) -> [String: (Data?, Date?)] {
        var files: [String: (Data?, Date?)] = [:]
        let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            files[url.path] = (try? Data(contentsOf: url), modified)
        }
        return files
    }

    // FR-002: a scratch root never reaches a real home.
    @Test func noPersonalHomeMakesNothing() async throws {
        let core = try await core(home: nil)
        await core.ensureChatProject()

        #expect(await core.allProjects().isEmpty)
        #expect(await core.chatProjectState() == .noPersonalHome)
    }

    // US1 scenario 1, FR-001, FR-004, FR-010
    @Test func aFreshHomeGetsTheChatProjectMarked() async throws {
        let home = try temporary("home")
        let core = try await core(home: home)
        await core.ensureChatProject()

        let folder = chatFolder(home)
        #expect(fileManager.fileExists(atPath: folder.appending(path: ".agents").path))
        let agentsMd = try String(contentsOf: folder.appending(path: "AGENTS.md"), encoding: .utf8)
        #expect(agentsMd.contains("This folder is shared by every chat on this host."))

        let projects = await core.allProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.folder == folder)
        #expect(projects.first?.name == "chat")
        #expect(projects.first?.isChat == true)
        #expect(await core.chatProjectState() == .ready(folder: folder))
    }

    // US1 scenario 2, FR-003
    @Test func aSecondStartChangesNothing() async throws {
        let home = try temporary("home")
        let core = try await core(home: home)
        await core.ensureChatProject()
        let folder = chatFolder(home)
        try "kept".write(to: folder.appending(path: "note.md"), atomically: true, encoding: .utf8)
        let before = snapshot(folder)

        await core.ensureChatProject()

        let after = snapshot(folder)
        #expect(Set(before.keys) == Set(after.keys))
        for (path, (data, modified)) in before {
            #expect(after[path]?.0 == data, "\(path) changed")
            #expect(after[path]?.1 == modified, "\(path) was written again")
        }
    }

    // Edge case: a folder the person made by hand is used as it is.
    @Test func aHandMadeFolderIsAdopted() async throws {
        let home = try temporary("home")
        let folder = chatFolder(home)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try "mine".write(to: folder.appending(path: "mine.md"), atomically: true, encoding: .utf8)
        let core = try await core(home: home)
        await core.ensureChatProject()

        #expect(try String(contentsOf: folder.appending(path: "mine.md"), encoding: .utf8) == "mine")
        #expect(await core.allProjects().first?.isChat == true)
    }

    // Only the chat project is marked; an ordinary project is not.
    @Test func onlyTheChatProjectIsMarked() async throws {
        let home = try temporary("home")
        let other = Project.standardize(try temporary("other"))
        let core = try await core(home: home)
        await core.ensureChatProject()
        _ = try await core.addProject(other)

        let marks = Dictionary(uniqueKeysWithValues: await core.allProjects().map { ($0.folder, $0.isChat) })
        #expect(marks[chatFolder(home)] == true)
        #expect(marks[other] == .some(nil))
    }

    // US3 scenario 3, FR-003, FR-011
    @Test func anArchivedChatProjectStaysArchived() async throws {
        let home = try temporary("home")
        let core = try await core(home: home)
        await core.ensureChatProject()
        let folder = chatFolder(home)
        _ = try await core.archiveProject(folder)
        let before = snapshot(folder)

        await core.ensureChatProject()

        #expect(await core.allProjects().first?.project.isArchived == true)
        #expect(await core.chatProjectState() == .archived(folder: folder))
        #expect(Set(snapshot(folder).keys) == Set(before.keys))

        _ = try await core.unarchiveProject(folder)
        #expect(await core.chatProjectState() == .ready(folder: folder))
    }

    // Edge case: the person deleted the folder. It comes back empty, not laid out again.
    @Test func aLiveRecordWhoseFolderWentGetsItBack() async throws {
        let home = try temporary("home")
        let core = try await core(home: home)
        await core.ensureChatProject()
        let folder = chatFolder(home)
        try fileManager.removeItem(at: folder)

        await core.ensureChatProject()

        #expect(DaemonCore.isDirectory(folder))
        #expect(!fileManager.fileExists(atPath: folder.appending(path: "AGENTS.md").path))
        #expect(await core.chatProjectState() == .ready(folder: folder))
    }

    // Edge case, FR-005: a file in the way is said, and nothing else is held up.
    @Test func aFileInTheWayIsAFailureNotAStop() async throws {
        let home = try temporary("home")
        let folder = chatFolder(home)
        try fileManager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not a folder".write(to: folder, atomically: true, encoding: .utf8)
        let other = Project.standardize(try temporary("other"))
        let core = try await core(home: home)
        await core.ensureChatProject()
        _ = try await core.addProject(other)

        guard case .failed(let message) = await core.chatProjectState() else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("is a file"))
        #expect(await core.allProjects().map(\.folder) == [other])
    }

    // FR-014: an older reader decodes a summary with the mark; a summary without one has no key.
    @Test func theMarkIsOnlyOnTheWireWhenTrue() throws {
        var summary = DaemonAPI.ProjectSummary(project: Project(folder: URL(filePath: "/tmp/x")), name: "x",
                                               exists: true, lastActivityAt: Date(), counts: [:])
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any]
        #expect(plain?["isChat"] == nil)
        summary.isChat = true
        let marked = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(DaemonAPI.ProjectSummary.self, from: marked).isChat == true)
    }
}
