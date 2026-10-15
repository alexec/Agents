import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The host awarding milestones (#984): from a call a phone or a browser makes, and from
/// the records it reads, kept in `achievements.json` and read back after a restart.
@Suite("Milestones on the host", .timeLimit(.minutes(1)))
struct MilestonesDaemonTests {
    private func makeCore(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    private func temporary() throws -> StoreLocations {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsMilestones-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StoreLocations(root: root)
    }

    @Test func aDeviceCallingIsAPairingAndTheMacIsNot() async throws {
        let locations = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let core = try await makeCore(locations)
        _ = await core.handle(method: DaemonAPI.Method.ping, params: nil, role: .control)
        #expect(await core.milestones().earned.isEmpty)
        _ = await core.handle(method: DaemonAPI.Method.ping, params: nil, from: .device(UUID()), role: .device)
        #expect(await core.milestones().has(.firstPairing))
        #expect(!(await core.milestones().has(.firstRemoteAnswer)))

        // Kept, and read back by the next daemon.
        let again = try await makeCore(locations)
        #expect(await again.milestones().has(.firstPairing))
    }

    @Test func aFailedAnswerFromADeviceEarnsNothing() async throws {
        let locations = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let core = try await makeCore(locations)
        _ = await core.handle(method: DaemonAPI.Method.elicitationsAnswer, params: ["nonsense": true],
                              from: .device(UUID()), role: .device)
        #expect(await core.milestones().earned.isEmpty)
    }

    @Test func aRunningWorkspaceIsACloudHost() {
        func listed(_ state: String, host: String? = nil) -> DaemonAPI.AgentWorkspaces {
            .init(providers: [.init(id: ProviderID(rawValue: "do"), name: "DigitalOcean", canMake: true, canDelete: true,
                                    workspaces: [.init(id: "w", name: "box", state: state, hostState: host)])])
        }
        #expect(DaemonCore.anyRunning(listed("running")))
        #expect(DaemonCore.anyRunning(listed("unknown", host: "online")))
        #expect(!DaemonCore.anyRunning(listed("stopped", host: "offline")))
    }
}
