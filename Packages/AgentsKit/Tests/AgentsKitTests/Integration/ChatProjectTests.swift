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

    /// A core on a fresh root, with this home or none, holding these agents as a restart
    /// arrives at them.
    private func core(home: URL?, seeded: [Agent] = []) async throws -> DaemonCore {
        var locations = StoreLocations(root: try temporary("root"))
        locations.personalHome = home
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        let core = DaemonCore(store: store,
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

    // FR-006 (Alex, 2026-10-07): a server has no personal home, and keeps its chat project
    // in its account's home, for that alone.
    @Test func aServerKeepsItsChatProjectInItsAccountsHome() async throws {
        let home = try temporary("server-home")
        let core = try await core(home: nil)
        await core.setServerChatHome(home)
        await core.ensureChatProject()

        let folder = chatFolder(home)
        #expect(await core.allProjects().first { $0.isChat == true }?.folder == folder)
        #expect(await core.chatProjectState() == .ready(folder: folder))
        #expect(await core.locations.personalHome == nil, "nothing else of ~/.agents is laid out")
        #expect(!fileManager.fileExists(atPath: home.appending(path: ".claude").path))
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

    // The chat project starts pinned, without a write; unpinning it is kept, as is
    // pinning another.
    @Test func theChatProjectIsPinnedUntilUnpinned() async throws {
        let home = try temporary("home")
        let other = Project.standardize(try temporary("other"))
        let core = try await core(home: home)
        await core.ensureChatProject()
        _ = try await core.addProject(other)
        let chat = chatFolder(home)

        func pins() async -> [URL: Bool] {
            Dictionary(uniqueKeysWithValues: await core.allProjects().map { ($0.folder, $0.project.isPinned) })
        }
        #expect(await pins() == [chat: true, other: false])
        #expect(await core.projectRecords()[chat]?.pinned == nil, "the default, not a choice")

        #expect(try await core.setPinned(.init(folder: chat, pinned: false)).project.isPinned == false)
        #expect(try await core.setPinned(.init(folder: other, pinned: true)).project.isPinned)
        #expect(await pins() == [chat: false, other: true])

        await core.ensureChatProject()
        #expect(await pins() == [chat: false, other: true], "a restart leaves the person's choice")

        // A folder that is not a project is refused.
        await #expect(throws: JSONRPCError.self) {
            try await core.setPinned(.init(folder: URL(filePath: "/nowhere/at/all"), pinned: true))
        }
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

    // US2 scenario 3, FR-004: the sentence is the person's once written.
    @Test func anEditedAgentsMdIsLeftAsThePersonLeftIt() async throws {
        let home = try temporary("home")
        let core = try await core(home: home)
        await core.ensureChatProject()
        let agentsMd = chatFolder(home).appending(path: "AGENTS.md")
        try "# AGENTS.md\n\nMine now.\n".write(to: agentsMd, atomically: true, encoding: .utf8)

        await core.ensureChatProject()

        #expect(try String(contentsOf: agentsMd, encoding: .utf8) == "# AGENTS.md\n\nMine now.\n")
    }

    // US2 scenario 1, SC-003: what a chat saved outlives the chat.
    @Test func aFileOutlivesTheChatThatWroteIt() async throws {
        let home = try temporary("home")
        let folder = chatFolder(home)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try "socks".write(to: folder.appending(path: "packing-list.md"), atomically: true, encoding: .utf8)
        var chat = Agent(runtimeID: "claude", cwd: folder, title: "Packing", state: .archived,
                         createdAt: Date(timeIntervalSinceNow: -3600), lastActivityAt: Date(timeIntervalSinceNow: -3600),
                         endedReason: .endTurn)
        chat.archivedAt = Date(timeIntervalSinceNow: -1800)
        chat.archivedReason = .byUser
        let core = try await core(home: home, seeded: [chat])
        await core.ensureChatProject()

        try await core.delete(chat.id, because: .person)

        #expect(try String(contentsOf: folder.appending(path: "packing-list.md"), encoding: .utf8) == "socks")
        #expect(await core.allProjects().first?.isChat == true, "the project stays, with its file")
    }

    // US5 scenario 3, FR-013: a chat asking for a worktree is told why not.
    @Test func aMoveIntoAWorktreeIsRefusedWithASentence() async throws {
        let home = try temporary("home")
        let folder = chatFolder(home)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let chat = Agent(runtimeID: "claude", cwd: folder, title: "A chat", state: .finished, endedReason: .endTurn)
        let core = try await core(home: home, seeded: [chat])
        await core.ensureChatProject()

        await #expect {
            _ = try await core.move(DaemonAPI.MoveRequest(agentID: chat.id, target: .newWorktree(name: nil)))
        } throws: { error in
            (error as? JSONRPCError)?.message == "Moving needs a git repository, and chat is not in one."
        }
    }

    // US5 scenario 1: no worktree choice, because the list says there is no repository.
    @Test func theWorktreeListSaysItIsNotARepository() async throws {
        let home = try temporary("home")
        let core = try await core(home: home)
        await core.ensureChatProject()

        let listed = await core.listWorktrees(for: chatFolder(home))
        #expect(listed == .notARepository)
    }
}
