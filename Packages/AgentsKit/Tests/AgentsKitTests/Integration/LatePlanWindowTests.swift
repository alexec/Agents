import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// 052, R2: Claude's plan window can be read after the refusal it explains. It still
/// gives the refusal its time, so a wait is made on it and not on the one-hour guess.
@Suite("A plan window that comes late")
struct LatePlanWindowTests {
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: nil))

    private func core() throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LatePlanWindow-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        return (core, work)
    }

    @Test func itGivesARecentRefusalItsTime() async throws {
        let (core, work) = try core()
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude]))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        let now = Date()
        var out = AllowanceState(credentialKey: "claude:sign-in", entryID: claude.id, since: now)
        out.markOut(.allowanceSpent, until: nil, payment: claude.payment, now: now, from: .typedFailure)
        await core.setAllowanceState(out)

        let back = now.addingTimeInterval(3 * 3600)
        await core.notePlanWindow(RateLimitInfo(status: "rejected", resetsAt: back), agentID: id)
        let state = try #require(await core.allowanceStates().first)
        #expect(state.knownReturn == back)
    }

    @Test func aWindowThatIsNotARefusalChangesNothing() async throws {
        let (core, work) = try core()
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude]))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        let now = Date()
        var out = AllowanceState(credentialKey: "claude:sign-in", entryID: claude.id, since: now)
        out.markOut(.allowanceSpent, until: nil, payment: claude.payment, now: now, from: .typedFailure)
        await core.setAllowanceState(out)
        await core.notePlanWindow(RateLimitInfo(status: "allowed", resetsAt: now.addingTimeInterval(3600)), agentID: id)
        #expect(await core.allowanceStates().first?.knownReturn == nil)
    }
}
