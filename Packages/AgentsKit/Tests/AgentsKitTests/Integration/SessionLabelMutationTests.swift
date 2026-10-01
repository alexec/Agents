import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Session label mutations", .timeLimit(.minutes(1)))
struct SessionLabelMutationTests {
    private final class Broadcasts: @unchecked Sendable {
        private let lock = NSLock()
        private var moments: [Date] = []
        func record() { lock.lock(); moments.append(Date()); lock.unlock() }
        var latest: Date? { lock.lock(); defer { lock.unlock() }; return moments.last }
    }
    private func core() async throws -> (DaemonCore, AgentStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SessionLabels-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let store = try AgentStore(locations: locations)
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return (core, store, Project.standardize(folder))
    }

    @Test func createChangeAndPersist() async throws {
        let (core, store, folder) = try await core()
        let broadcasts = Broadcasts()
        await core.setBroadcaster { method, _ in
            if method == DaemonAPI.Notification.agentChanged { broadcasts.record() }
        }
        let id = try await core.start(.init(runtimeID: "claude", cwd: folder,
                                            prompt: "Review login", labels: [" Review "]))
        #expect(await core.agent(id)?.labels.map(\.value) == ["Review"])
        #expect(await core.agent(id)?.labels.first?.owner == .person)
        let before = Date()
        let changed = try await core.setSessionLabels(.init(agentID: id, add: ["Urgent"], remove: ["review"]))
        #expect(changed.labels.map(\.value) == ["Urgent"])
        #expect(broadcasts.latest.map { $0.timeIntervalSince(before) < 5 } == true)
        let tail = await core.saveTail
        await tail?.value
        #expect(try await store.load(id).agent.labels.map(\.value) == ["Urgent"])
    }

    @Test func anInvalidChangeLeavesEveryLabelUntouched() async throws {
        let (core, _, folder) = try await core()
        let id = try await core.start(.init(runtimeID: "claude", cwd: folder,
                                            prompt: "Review", labels: ["Review"]))
        do {
            _ = try await core.setSessionLabels(.init(agentID: id, add: ["New", String(repeating: "x", count: 25)],
                                                       remove: ["Review"]))
            Issue.record("the invalid change was accepted")
        } catch {}
        #expect(await core.agent(id)?.labels.map(\.value) == ["Review"])
    }

    @Test func archiveRestoreAndANewChatKeepTheirOwnLabels() async throws {
        let (core, _, folder) = try await core()
        let id = try await core.start(.init(runtimeID: "claude", cwd: folder,
                                            prompt: "Original", labels: ["Original"]))
        try await core.archive(id)
        #expect(await core.agent(id)?.labels.map(\.value) == ["Original"])
        try await core.unarchive(id)
        #expect(await core.agent(id)?.labels.map(\.value) == ["Original"])
        let next = try await core.start(.init(runtimeID: "claude", cwd: folder, prompt: "Continue the work"))
        #expect(await core.agent(next)?.labels.isEmpty == true)
    }

    @Test func projectsHaveSeparateVocabularies() async throws {
        let (core, _, folder) = try await core()
        let other = folder.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try await core.start(.init(runtimeID: "claude", cwd: folder,
                                       prompt: "A", labels: ["Review"]))
        _ = try await core.start(.init(runtimeID: "claude", cwd: other, prompt: "B"))
        let agents = await core.allAgents()
        #expect(SessionLabelPolicy.vocabulary(in: folder, agents: agents).map(\.value) == ["Review"])
        #expect(SessionLabelPolicy.vocabulary(in: other, agents: agents).isEmpty)
    }

    @Test func serverDaemonAndMacDaemonKeepLabelMutationsIsolated() async throws {
        let (mac, _, folder) = try await core()
        let (server, _, _) = try await core()
        let onServer = try await server.start(.init(runtimeID: "claude", cwd: folder,
                                                    prompt: "Hosted work", labels: ["Hosted"]))
        let onMac = try await mac.start(.init(runtimeID: "claude", cwd: folder,
                                              prompt: "Local work", labels: ["Local"]))
        _ = try await server.setSessionLabels(.init(agentID: onServer, add: ["Ready"]))
        #expect(await server.agent(onServer)?.labels.map(\.value) == ["Hosted", "Ready"])
        #expect(await mac.agent(onMac)?.labels.map(\.value) == ["Local"])
        do {
            _ = try await mac.setSessionLabels(.init(agentID: onServer, add: ["Crossed"]))
            Issue.record("a Mac daemon changed a server session")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.noSuchAgent)
        }
    }

    @Test func vocabularyIncludesArchivedLabelsUntilTheirFinalUseIsRemoved() async throws {
        let (core, _, folder) = try await core()
        let id = try await core.start(.init(runtimeID: "claude", cwd: folder,
                                            prompt: "Old review", labels: ["Review"]))
        try await core.archive(id)
        #expect(await core.labelVocabulary(.init(folder: folder)) == ["Review"])
        _ = try await core.setSessionLabels(.init(agentID: id, remove: ["review"]))
        #expect(await core.labelVocabulary(.init(folder: folder)).isEmpty)
    }
}
