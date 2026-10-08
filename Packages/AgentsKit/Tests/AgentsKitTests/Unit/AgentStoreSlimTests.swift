import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A slim archived agent never costs the record its lists (051, research R2), and
/// deleting never leaves half an agent listed (#398).
@Suite("Slim records and deleting")
struct AgentStoreSlimTests {
    static var fixture: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()      // Unit
            .deletingLastPathComponent()      // AgentsKitTests
            .appending(path: "Fixtures/archived-agent.json")
    }

    static func archivedAgent() throws -> Agent {
        try StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: fixture))
    }

    private func store() throws -> (AgentStore, StoreLocations) {
        let root = FileManager.default.temporaryDirectory.appending(path: "slim-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        return (try AgentStore(locations: locations), locations)
    }

    private func archived() throws -> Agent {
        var agent = try Self.archivedAgent()
        agent.id = UUID()
        agent.archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return agent
    }

    @Test func slimmingAndMakingWholeRoundTrip() throws {
        let agent = try archived()
        let slim = agent.slimmed()
        #expect(slim.isSlim)
        #expect(slim.availableCommands.isEmpty && slim.advertisedOptions.isEmpty && slim.plans.isEmpty)
        #expect(slim.madeWhole(from: agent) == agent)
    }

    @Test func savingASlimAgentKeepsTheListsOnDisk() async throws {
        let (store, locations) = try store()
        let agent = try archived()
        try await store.save(agent)
        var slim = agent.slimmed()
        slim.isUnread = !agent.isUnread
        try await store.save(slim)
        let disk = try StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: locations.record(agent.id)))
        #expect(disk.availableCommands == agent.availableCommands)
        #expect(disk.advertisedOptions == agent.advertisedOptions)
        #expect(disk.isUnread == slim.isUnread)
        #expect(!disk.isSlim)
    }

    @Test func aSlimAgentWithNoRecordIsRefused() async throws {
        let (store, locations) = try store()
        let slim = try archived().slimmed()
        await #expect(throws: AgentStore.RecordRefused.slimWithoutRecord(slim.id)) { try await store.save(slim) }
        #expect(!FileManager.default.fileExists(atPath: locations.record(slim.id).path))
    }

    @Test func aWholeAgentSavesAsItAlwaysDid() async throws {
        let (store, locations) = try store()
        let agent = try archived()
        try await store.save(agent)
        let disk = try StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: locations.record(agent.id)))
        #expect(disk == agent)
    }

    @Test func archivedAtGoesWhenTheAgentIsNotArchived() async throws {
        let (store, locations) = try store()
        var agent = try archived()
        agent.state = .finished
        agent.endedReason = .endTurn
        agent.archivedReason = nil
        try await store.save(agent)
        let disk = try StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: locations.record(agent.id)))
        #expect(disk.archivedAt == nil)
    }

    // MARK: Deleting

    @Test func stoppedPartWayTheAgentIsNeverListedAndTheNextStartFinishes() async throws {
        let (store, locations) = try store()
        let agent = try archived()
        try await store.save(agent)
        try await store.append(TranscriptEntry(kind: .userMessage("hello")), for: agent.id)

        await store.stop(afterSettingAside: true)
        await #expect(throws: AgentStore.Stopped.self) { try await store.delete(agent.id) }
        #expect(await !store.loadAll().agents.contains { $0.id == agent.id })
        #expect(await !store.agentIDs().contains(agent.id))

        await store.finishDeleting()
        #expect(!FileManager.default.fileExists(atPath: await store.setAside(agent.id).path))
        #expect(!FileManager.default.fileExists(atPath: locations.agent(agent.id).path))
    }

    @Test func deletingRemovesTheWholeFolder() async throws {
        let (store, locations) = try store()
        let agent = try archived()
        try await store.save(agent)
        try await store.append(TranscriptEntry(kind: .userMessage("hello")), for: agent.id)
        try await store.delete(agent.id)
        #expect(!FileManager.default.fileExists(atPath: locations.agent(agent.id).path))
        // Twice is nothing.
        try await store.delete(agent.id)
    }
}
