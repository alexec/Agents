import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The app-owned files in `.agents` wait for the person's OK when changed outside the app
/// (#502): the approved copy goes on being used, the change names who made it, and Keep
/// or Undo settles it.
@Suite("App-owned files wait for an OK", .timeLimit(.minutes(1)))
struct GuardedFilesTests {
    private struct Setup {
        var core: DaemonCore
        var project: URL
        var lead: UUID
        var root: URL
    }

    private func setUp() async throws -> Setup {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsGuarded-\(UUID().uuidString)", isDirectory: true)
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root.appendingPathComponent("root", isDirectory: true))
        try locations.createDirectories()
        let store = try AgentStore(locations: locations)
        let lead = Agent(runtimeID: "claude", cwd: project, title: "Lead", state: .finished, endedReason: .endTurn)
        try await store.save(lead)
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        _ = try await core.addProject(project)
        return Setup(core: core, project: project, lead: lead.id, root: root)
    }

    private func write(_ text: String, _ file: GuardedFile, in project: URL) throws {
        let url = file.url(in: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(_ file: GuardedFile, in project: URL) -> String? {
        try? String(contentsOf: file.url(in: project), encoding: .utf8)
    }

    @Test func aChangeDuringATurnIsNotUsedAndNamesTheAgent() async throws {
        let s = try await setUp()
        _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 2)))
        await s.core.startTurnForTesting(s.lead)

        try write(#"{"helperLimits": {"running": 10}}"#, .projectConfig, in: s.project)
        await s.core.projectFilesChanged([s.project.appending(path: ".agents")], in: s.project)

        #expect(await s.core.helperLimits(in: s.project).running == 2, "the approved copy is what counts")
        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        #expect(change.path == ".agents/project.json")
        #expect(change.changedBy == ["Lead"])
        #expect(change.headline == "Lead changed .agents/project.json")
        // Asked in Lead's session, as a need like any question (#531).
        #expect(change.askedIn == s.lead)
        let need = try #require(await s.core.needs().first { $0.kind == .guardedChange })
        #expect(need.id == .guardedChange(s.project, ".agents/project.json"))
        #expect(need.agentID == s.lead)
        #expect(need.headline.h3 == "Lead changed .agents/project.json")

        await #expect(throws: JSONRPCError.self, "the app does not write over a change nobody kept") {
            _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 3)))
        }

        let reading = try await s.core.readGuardedChange(.init(folder: s.project, path: change.path))
        #expect(reading.lines.contains(GuardedDiffLine(kind: .added, text: #"{"helperLimits": {"running": 10}}"#)))
        #expect(reading.lines.contains { $0.kind == .removed && $0.text.contains(#""running" : 2"#) })

        let kept = try await s.core.keepGuardedChange(.init(folder: s.project, path: change.path, digest: reading.digest))
        #expect(kept.guardedChanges == nil)
        #expect(await s.core.configuredHelperLimits(in: s.project)?.running == 10, "kept, it counts")
        #expect(await !s.core.needs().contains { $0.kind == .guardedChange }, "answered, it is asked no more")
    }

    @Test func undoPutsTheApprovedCopyBack() async throws {
        let s = try await setUp()
        _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 2)))
        let approved = text(.projectConfig, in: s.project)
        await s.core.startTurnForTesting(s.lead)
        try write(#"{"helperLimits": {"running": 10}}"#, .projectConfig, in: s.project)
        await s.core.checkGuardedFiles(in: s.project)

        let reading = try await s.core.readGuardedChange(.init(folder: s.project, path: GuardedFile.projectConfig.path))
        await #expect(throws: JSONRPCError.self, "only the change the person was shown") {
            _ = try await s.core.undoGuardedChange(.init(folder: s.project, path: reading.path, digest: "other"))
        }
        let summary = try await s.core.undoGuardedChange(.init(folder: s.project, path: reading.path, digest: reading.digest))
        #expect(summary.guardedChanges == nil)
        #expect(text(.projectConfig, in: s.project) == approved)
        #expect(await s.core.helperLimits(in: s.project).running == 2)
    }

    @Test func aChangeFirstSeenAtTheEndOfATurnIsThatTurns() async throws {
        let s = try await setUp()
        _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 2)))
        await s.core.startTurnForTesting(s.lead)
        try write(#"{"helperLimits": {"running": 4}}"#, .projectConfig, in: s.project)
        await s.core.endTurnForTesting(s.lead)

        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        #expect(change.changedBy == ["Lead"])
        #expect(await s.core.helperLimits(in: s.project).running == 2)
    }

    @Test func aChangeWithNoTurnRunningIsThePersonsOwn() async throws {
        let s = try await setUp()
        _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 2)))
        try write(#"{"helperLimits": {"running": 4}}"#, .projectConfig, in: s.project)
        await s.core.projectFilesChanged([s.project.appending(path: ".agents")], in: s.project)

        #expect(await s.core.projectSummary(for: s.project)?.guardedChanges == nil)
        #expect(await s.core.helperLimits(in: s.project).running == 4)
    }

    @Test func pinsChangedDuringATurnAreNotShownAndHoldThePinTools() async throws {
        let s = try await setUp()
        let page = s.project.appending(path: "notes.md")
        try Data("# Notes\n".utf8).write(to: page)
        _ = try await s.core.pinByPerson(DaemonAPI.PinRequest(folder: s.project, path: "notes.md"))
        #expect(await s.core.pinViews(s.project).map(\.path) == ["notes.md"])

        await s.core.startTurnForTesting(s.lead)
        try write(#"{"pins": []}"#, .pins, in: s.project)
        await s.core.projectFilesChanged([s.project.appending(path: ".agents")], in: s.project)

        #expect(await s.core.pinViews(s.project).map(\.path) == ["notes.md"], "the approved pins still show")
        await #expect(throws: JSONRPCError.self) {
            try await s.core.unpinByPerson(DaemonAPI.PinPathRequest(folder: s.project, path: "notes.md"))
        }
        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        #expect(change.path == ".agents/pins.json")
        _ = try await s.core.keepGuardedChange(.init(folder: s.project, path: change.path, digest: change.digest))
        #expect(await s.core.pinViews(s.project).isEmpty)
    }

    @Test func aMergedChangeWaitsWithNoTurnRunning() async throws {
        let s = try await setUp()
        try await git(["init", "-q"], in: s.project)
        _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 2)))
        try await git(["add", "-A"], in: s.project)
        try await git(["commit", "-qm", "first"], in: s.project)

        // A commit that changes the file, as a merge or pull brings it.
        try write(#"{"helperLimits": {"running": 4}}"#, .projectConfig, in: s.project)
        try await git(["commit", "-qam", "raise"], in: s.project)
        await s.core.checkGuardedFiles(in: s.project)
        let change = try await waitForChange(s)
        #expect(change.byGit && change.changedBy.isEmpty)
        #expect(change.headline == "A merge or pull changed .agents/project.json")
        // No session to ask it in: the project's own question (#531).
        #expect(change.askedIn == nil)
        let need = try #require(await s.core.needs().first { $0.kind == .guardedChange })
        #expect(need.agentID == nil && need.folder == s.project)
        #expect(NeedID.guardedFolder(fromToken: need.id.token)?.path == s.project.path)
        #expect(await s.core.helperLimits(in: s.project).running == 2)

        // Edited by hand after, not committed: the person's own.
        try write(#"{"helperLimits": {"running": 3}}"#, .projectConfig, in: s.project)
        await s.core.checkGuardedFiles(in: s.project)
        for _ in 0..<200 where await s.core.helperLimits(in: s.project).running != 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await s.core.helperLimits(in: s.project).running == 3)
        #expect(await s.core.projectSummary(for: s.project)?.guardedChanges == nil)
    }

    @Test func anArchivedAgentsChangeIsAskedOfTheProject() async throws {
        let s = try await setUp()
        _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 2)))
        await s.core.startTurnForTesting(s.lead)
        try write(#"{"helperLimits": {"running": 4}}"#, .projectConfig, in: s.project)
        await s.core.endTurnForTesting(s.lead)
        #expect(await s.core.projectSummary(for: s.project)?.guardedChanges?.first?.askedIn == s.lead)

        try await s.core.archive(s.lead)
        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        #expect(change.changedBy == ["Lead"], "still named")
        #expect(change.askedIn == nil, "but asked on the project's page")
        #expect(await s.core.needs().first { $0.kind == .guardedChange }?.agentID == nil)
    }

    @Test func aGuardedNeedIDCodesAndNamesItsProject() throws {
        let folder = URL(filePath: "/tmp/some: project", directoryHint: .isDirectory)
        let id = NeedID.guardedChange(folder, ".agents/pins.json")
        let decoded = try JSONDecoder().decode(NeedID.self, from: JSONEncoder().encode(id))
        #expect(decoded == id)
        #expect(NeedID.guardedFolder(fromToken: id.token)?.path == folder.path)
        #expect(NeedID.guardedFolder(fromToken: NeedID.permission(UUID()).token) == nil)
    }

    /// A banner's token names its project as the project is kept, so a client finds it
    /// (#1367): equal to the standardised folder, not a directory URL with a trailing slash,
    /// whichever form the host sent (`/tmp` or `/private/tmp`, with or without the slash).
    @Test func aGuardedTokensFolderIsTheProjectsOwn() throws {
        // There, because Foundation takes /private off only a path that exists.
        let name = "g1367-\(UUID().uuidString.prefix(8))"
        let made = URL(filePath: "/tmp/\(name)/work")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made.deletingLastPathComponent()) }
        let project = Project.standardize(made)
        for sent in ["file:///tmp/\(name)/work/", "file:///tmp/\(name)/work", "file:///private/tmp/\(name)/work/"] {
            let id = NeedID.guardedChange(URL(string: sent)!, ".agents/project.json")
            #expect(NeedID.guardedFolder(fromToken: id.token) == project, "\(sent)")
        }
    }

    @Test func linesAreMarkedKeptRemovedAndAdded() {
        let lines = GuardedDiffLine.lines(from: "a\nb\nc\n", to: "a\nB\nc\nd\n")
        #expect(lines == [
            .init(kind: .same, text: "a"), .init(kind: .removed, text: "b"), .init(kind: .added, text: "B"),
            .init(kind: .same, text: "c"), .init(kind: .added, text: "d"),
        ])
    }

    /// A lane's worktree, once removed, leaves no state behind (#933): the next save
    /// drops it, unless a change there still waits.
    @Test func aGoneFolderLeavesNoStateUnlessAChangeWaits() async throws {
        let s = try await setUp()
        let lane = Project.standardize(s.root.appendingPathComponent("lane", isDirectory: true))
        let held = Project.standardize(s.root.appendingPathComponent("held", isDirectory: true))
        for folder in [lane, held] {
            try write(#"{"pins": []}"#, .pins, in: folder)
            _ = await s.core.guardedContent(.pins, in: folder)
        }
        await s.core.startTurnForTesting(s.lead)
        try write(#"{"pins": [{}]}"#, .pins, in: held)
        await s.core.markGuardedChanges(in: held, witness: await s.core.agents[s.lead])
        await s.core.endTurnForTesting(s.lead)
        try FileManager.default.removeItem(at: lane)
        try FileManager.default.removeItem(at: held)

        _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 2)))

        let folders = Set(await s.core.guardedRecords().states.map(\.folder))
        #expect(!folders.contains(lane), "gone, with nothing waiting")
        #expect(folders.contains(held), "a waiting change is the person's to settle")
        #expect(folders.contains(s.project))
    }

    /// A project that leaves the list lets go of what was read and sent of it (#933).
    @Test func aProjectThatLeavesLetsGoOfItsCaches() async throws {
        let s = try await setUp()
        let lane = Project.standardize(s.root.appendingPathComponent("lane", isDirectory: true))
        try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: true)
        _ = try await s.core.addProject(lane)
        _ = await s.core.readPins(lane)
        let pinsPath = GuardedFile.pins.url(in: lane).path
        #expect(await s.core.pinsCache[lane] != nil)
        #expect(await s.core.guardedDisk[pinsPath] != nil)

        _ = try await s.core.archiveProject(lane)
        try await s.core.deleteProject(lane)
        _ = await s.core.allProjects()

        #expect(await s.core.pinsCache[lane] == nil)
        #expect(await s.core.guardedDisk[pinsPath] == nil)
        #expect(await s.core.lastProjectSent[lane] == nil)
    }

    private func waitForChange(_ s: Setup) async throws -> GuardedChange {
        for _ in 0..<200 {
            if let change = await s.core.projectSummary(for: s.project)?.guardedChanges?.first { return change }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(nil as GuardedChange?)
    }

    private func git(_ arguments: [String], in folder: URL) async throws {
        let outcome = try await GitProcess(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                                            "-c", "commit.gpgsign=false"] + arguments, in: folder).run()
        guard outcome.succeeded else {
            throw GitWorktrees.Failure(message: "git \(arguments.joined(separator: " ")): \(outcome.errors)")
        }
    }
}

extension DaemonCore {
    /// A turn in flight with no runtime behind it.
    func startTurnForTesting(_ agentID: UUID) {
        turnTasks[agentID] = Task {}
    }

    func endTurnForTesting(_ agentID: UUID) {
        turnTasks.removeValue(forKey: agentID)
        guardedTurnEnded(agentID)
    }
}
