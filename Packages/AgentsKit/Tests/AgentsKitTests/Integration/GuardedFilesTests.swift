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

        await #expect(throws: JSONRPCError.self, "the app does not write over a change nobody kept") {
            _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 3)))
        }

        let reading = try await s.core.readGuardedChange(.init(folder: s.project, path: change.path))
        #expect(reading.lines.contains(GuardedDiffLine(kind: .added, text: #"{"helperLimits": {"running": 10}}"#)))
        #expect(reading.lines.contains { $0.kind == .removed && $0.text.contains(#""running" : 2"#) })

        let kept = try await s.core.keepGuardedChange(.init(folder: s.project, path: change.path, digest: reading.digest))
        #expect(kept.guardedChanges == nil)
        #expect(await s.core.configuredHelperLimits(in: s.project)?.running == 10, "kept, it counts")
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

    @Test func linesAreMarkedKeptRemovedAndAdded() {
        let lines = GuardedDiffLine.lines(from: "a\nb\nc\n", to: "a\nB\nc\nd\n")
        #expect(lines == [
            .init(kind: .same, text: "a"), .init(kind: .removed, text: "b"), .init(kind: .added, text: "B"),
            .init(kind: .same, text: "c"), .init(kind: .added, text: "d"),
        ])
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
