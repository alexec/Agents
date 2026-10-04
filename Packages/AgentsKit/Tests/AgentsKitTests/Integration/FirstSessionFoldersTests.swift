import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The extra folders an agent is started with reach its very first session (#230).
///
/// They used to go only on a resume or a session made after a restart, so until then
/// the agent's first conversation could not see them.
@Suite("Extra folders on the first session", .timeLimit(.minutes(1)))
struct FirstSessionFoldersTests {
    private func temporary() throws -> (StoreLocations, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsFirstFolders-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work, extra)
    }

    private func core(_ locations: StoreLocations, _ launcher: FakeLauncher) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    private func offering(_ capable: Bool) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        if capable { script.sessionCapabilities["additionalDirectories"] = [:] }
        return script
    }

    private func sent(_ launcher: FakeLauncher) async -> [String]? {
        await launcher.lastAgent?.newSessionParams?["additionalDirectories"]?.arrayValue?
            .compactMap(\.stringValue)
    }

    @Test func aFreshStartSendsThemToARuntimeThatTakesThem() async throws {
        let (locations, work, extra) = try temporary()
        let launcher = FakeLauncher(script: offering(true))
        let core = try core(locations, launcher)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "hello",
                                       additionalDirectories: [extra]))
        #expect(await sent(launcher) == [extra.path])
    }

    /// The form's draft session is made before the folders are known, so a start
    /// naming some makes its own rather than reusing one that never heard of them.
    @Test func aStartAfterTheFormSendsThemToo() async throws {
        let (locations, work, extra) = try temporary()
        let launcher = FakeLauncher(script: offering(true))
        let core = try core(locations, launcher)
        let draft = try await core.options(.init(runtimeID: "copilot", cwd: work))
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "hello",
                                       draftID: draft.draftID, additionalDirectories: [extra]))
        #expect(await sent(launcher) == [extra.path])
    }

    @Test func aRuntimeThatDoesNotTakeThemIsNotSentThem() async throws {
        let (locations, work, extra) = try temporary()
        let launcher = FakeLauncher(script: offering(false))
        let core = try core(locations, launcher)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "hello",
                                       additionalDirectories: [extra]))
        #expect(await launcher.lastAgent?.newSessionParams != nil)
        #expect(await sent(launcher) == nil)
    }
}
