import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// How long a start form's runtime lives when nobody starts it (029). Every
/// `agents/options` starts a runtime, and before this nothing let one go unless it was
/// used — one abandoned process each time a form changed on the Mac, and one each time
/// a phone glanced at New agent and put it away.
@Suite("A draft nobody starts is let go", .timeLimit(.minutes(1)))
struct DraftLifetimeTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDraftTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, _ locations: StoreLocations,
                      grace: Duration = .seconds(30)) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher, draftGracePeriod: grace)
    }

    private func closed(_ launcher: FakeLauncher) async -> Bool {
        guard let agent = launcher.lastAgent else { return false }
        return await agent.received.contains(ACP.Method.close)
    }

    @Test func discardingADraftEndsItsRuntime() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations)
        let draft = try await core.options(.init(runtimeID: "claude", cwd: work))

        await core.discardDraft(.init(draftID: draft.draftID))

        #expect(await core.drafts[draft.draftID] == nil)
        #expect(await eventually("the runtime was asked to close") { await closed(launcher) })
    }

    @Test func discardingWhatIsNotThereIsNotAnError() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(), locations)
        // Never known.
        await core.discardDraft(.init(draftID: UUID()))
        // Already used.
        let draft = try await core.options(.init(runtimeID: "claude", cwd: work))
        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go", draftID: draft.draftID))
        await core.discardDraft(.init(draftID: draft.draftID))
        // Already ended.
        let other = try await core.options(.init(runtimeID: "claude", cwd: work))
        await core.discardDraft(.init(draftID: other.draftID))
        await core.discardDraft(.init(draftID: other.draftID))
    }

    @Test func aDraftWhoseConnectionWentIsStillUsableWithinTheGracePeriod() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations, grace: .seconds(30))
        let phone = UUID()
        let draft = try await core.options(.init(runtimeID: "claude", cwd: work), connection: phone)

        await core.orphanDrafts(connection: phone)
        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go", draftID: draft.draftID))

        #expect(launcher.launchCount == 1, "the start used the draft's runtime rather than making another")
    }

    @Test func aDraftWhoseConnectionWentIsEndedAfterTheGracePeriod() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations, grace: .milliseconds(50))
        let phone = UUID()
        let draft = try await core.options(.init(runtimeID: "claude", cwd: work), connection: phone)

        await core.orphanDrafts(connection: phone)

        #expect(await eventually("the draft was let go") { await core.drafts[draft.draftID] == nil })
        #expect(await eventually("its runtime was asked to close") { await closed(launcher) })
    }

    @Test func anotherConnectionGoingLeavesADraftAlone() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(), locations, grace: .milliseconds(20))
        let window = try await core.options(.init(runtimeID: "claude", cwd: work), connection: UUID())
        let workflow = try await core.options(.init(runtimeID: "claude", cwd: work))

        await core.orphanDrafts(connection: UUID())
        try await Task.sleep(for: .milliseconds(150))

        #expect(await core.drafts[window.draftID] != nil)
        #expect(await core.drafts[workflow.draftID] != nil, "a draft with no connection is never orphaned")
    }
}
