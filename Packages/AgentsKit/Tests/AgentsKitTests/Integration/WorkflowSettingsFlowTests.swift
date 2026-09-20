import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A workflow that says how it runs, driven through the real daemon.
///
/// The runtime is the fake launcher, so an agent really starts and really finishes
/// without a CLI, a credential or a network — which is what lets these assert on what
/// the runtime was actually told rather than on what we meant to tell it.
@Suite("A workflow that says how it runs", .timeLimit(.minutes(1)))
struct WorkflowSettingsFlowTests {
    // MARK: Scaffolding

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL, _ name: String = "api") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    @discardableResult
    private func write(_ text: String, as workflowID: String, in project: URL) throws -> URL {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = WorkflowFile.url(for: workflowID, in: project)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func core(_ locations: StoreLocations, seeded: [Agent] = [],
                      script: FakeACPAgent.Script = .init()) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        return core
    }
}
