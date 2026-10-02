import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A write the disk refuses (#88), here as a folder this may not write to: the call that
/// asked fails in words with nothing changed, and a write nobody asked for is told to
/// every window. The full disk itself is `DiskFullLiveTests`.
@Suite("Writes the disk refuses", .serialized, .timeLimit(.minutes(1)))
struct WriteRefusalTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWriteRefusal-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: FakeLauncher(script: FakeACPAgent.Script()))
    }

    /// Read-only for the length of `body`, and writable again after, so the folder can
    /// be cleaned up whatever happened.
    private func readOnly<T>(_ folder: URL, _ body: () async throws -> T) async rethrows -> T {
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        return try await body()
    }

    private func refusal(_ body: () async throws -> Void) async -> JSONRPCError? {
        do { try await body(); return nil } catch { return error as? JSONRPCError }
    }

    @Test func aPromptThatCannotBeWrittenFailsAndIsNotQueued() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        await eventually("the first turn ended") { await core.agent(id)?.state == .finished }

        let error = await readOnly(locations.agent(id)) {
            await refusal { try await core.prompt(.init(agentID: id, text: "two")) }
        }
        #expect(error?.code == DaemonAPI.Failure.couldNotSave)
        #expect(error?.message.hasPrefix("Agents is not allowed to write to") == true)
        #expect(error?.message.contains("so your message could not be saved") == true)
        let failure = try #require(try error?.data?.decode(WriteFailure.self))
        #expect(failure.cause == .notAllowed)
        #expect(await core.agent(id)?.queuedPrompts.isEmpty == true, "nothing is waiting that the disk did not keep")
        #expect(await core.agent(id)?.state == .finished, "and no turn began on it")
    }

    @Test func aProjectTheDiskRefusesIsNotHeldAsIfKept() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)

        let error = await readOnly(locations.root) {
            await refusal { _ = try await core.addProject(work) }
        }
        #expect(error?.code == DaemonAPI.Failure.couldNotSave)
        #expect(error?.message.contains("so the project list could not be saved") == true)
        #expect(await core.projectRecords()[Project.standardize(work)] == nil,
                "the cache follows the disk, so a restart finds what the window was told")

        // Room again: the same call keeps it.
        _ = try await core.addProject(work)
        #expect(await core.projectRecords()[Project.standardize(work)] != nil)
    }

    @Test func theDispatcherSaysARefusalInWordsNotAnErrorDomain() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        let params = try JSONValue.encoding(DaemonAPI.ProjectRequest(folder: work))
        let result = await readOnly(locations.root) {
            await core.handle(method: DaemonAPI.Method.projectsAdd, params: params,
                              from: .mac, connection: UUID())
        }
        guard case .failure(let error) = result else {
            Issue.record("the add was kept on a folder that refuses writes")
            return
        }
        #expect(error.code == DaemonAPI.Failure.couldNotSave)
        #expect(!error.message.contains("NSCocoaErrorDomain"))
    }

    @Test func aWriteNobodyAskedForIsToldOnceInAWhile() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        let heard = WriteFailureRecorder()
        await heard.attach(to: core)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        await eventually("the first turn ended") { await core.agent(id)?.state == .finished }

        await readOnly(locations.agent(id)) {
            guard var agent = await core.agent(id) else { Issue.record("the agent is gone"); return }
            agent.title = "Tidy the build"
            await core.changed(agent)
            await core.saveTail?.value
            agent.title = "Tidy the build again"
            await core.changed(agent)
            await core.saveTail?.value
        }
        let told = heard.failures
        #expect(told.count == 1, "one alert for a refusing folder, not one per write")
        #expect(told.first?.cause == .notAllowed)
        #expect(told.first?.message.contains("so the latest state of Tidy the build could not be saved") == true)
    }
}

/// Every `storage/writeFailed` the daemon said.
final class WriteFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [WriteFailure] = []

    func attach(to core: DaemonCore) async {
        await core.setBroadcaster { [weak self] method, params in
            guard method == DaemonAPI.Notification.writeFailed,
                  let failure = try? params?.decode(WriteFailure.self) else { return }
            self?.append(failure)
        }
    }

    private func append(_ failure: WriteFailure) {
        lock.lock(); defer { lock.unlock() }
        heard.append(failure)
    }

    var failures: [WriteFailure] {
        lock.lock(); defer { lock.unlock() }
        return heard
    }
}
