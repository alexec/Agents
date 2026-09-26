import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `branch.moved`, from the project's own `.git` (042 R9).
@Suite("Branch events", .timeLimit(.minutes(1)))
struct BranchEventTests {
    private func git(_ arguments: [String], in folder: URL) async throws {
        let outcome = try await GitProcess(arguments, in: folder).run()
        #expect(outcome.succeeded, "git \(arguments.joined(separator: " ")): \(outcome.errors)")
    }

    private func repository() async throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsBranches-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: work)
        try await git(["config", "user.email", "test@example.com"], in: work)
        try await git(["config", "user.name", "Test"], in: work)
        try await commit("first", in: work)
        return (StoreLocations(root: root.appendingPathComponent("store")), Project.standardize(work))
    }

    private func commit(_ message: String, in folder: URL) async throws {
        try message.write(to: folder.appendingPathComponent("\(message).txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: folder)
        try await git(["commit", "-q", "-m", message], in: folder)
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    private func moved(_ core: DaemonCore) async -> [Event] {
        await core.eventLog.events.filter { $0.name == "branch.moved" }
    }

    @Test func theFirstLookSeedsAndACommitOnMainIsAMove() async throws {
        let (locations, work) = try await repository()
        let core = try await core(locations)
        await core.checkBranches(in: work)
        #expect(await moved(core).isEmpty, "nothing is invented for before anybody looked")
        try await commit("second", in: work)
        await core.checkBranches(in: work)
        let events = await moved(core)
        #expect(events.count == 1)
        #expect(events.first?.details["branch"] == "main")
        #expect(events.first?.details["from"] != events.first?.details["to"])
    }

    @Test func aBranchNobodyWorksOnIsNotWatched() async throws {
        let (locations, work) = try await repository()
        let core = try await core(locations)
        await core.checkBranches(in: work)
        try await git(["checkout", "-q", "-b", "feature"], in: work)
        try await commit("on-feature", in: work)
        await core.checkBranches(in: work)
        #expect(await moved(core).isEmpty)
    }

    @Test func aMoveWhileTheDaemonWasDownIsRaisedWhenNoticed() async throws {
        let (locations, work) = try await repository()
        let first = try await core(locations)
        await first.checkBranches(in: work)
        try await commit("while-down", in: work)
        let again = try await core(locations)
        await again.checkBranches(in: work)
        #expect(await moved(again).count == 1)
    }

    @Test func theWatchSeesACommit() async throws {
        let (locations, work) = try await repository()
        let core = try await core(locations)
        await core.watchBranches(in: work)
        try await Task.sleep(for: .milliseconds(300))
        try await commit("watched", in: work)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline, await moved(core).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(await moved(core).count == 1)
        await core.stopWatchingAllBranches()
    }
}
