import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A slim archived agent never costs the record its lists (051, research R2), and
/// retiring leaves either the whole agent or its tombstone, never neither (SC-006).
@Suite("Slim records and retiring")
struct AgentStoreSlimTests {
    private func store() throws -> (AgentStore, StoreLocations) {
        let root = FileManager.default.temporaryDirectory.appending(path: "slim-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        return (try AgentStore(locations: locations), locations)
    }

    private func archived() throws -> Agent {
        var agent = try TombstoneTests.archivedAgent()
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

    @Test func retirementFieldsGoWhenTheAgentIsNotArchived() async throws {
        let (store, locations) = try store()
        var agent = try archived()
        agent.retirement = .nextUnderCap
        agent.state = .finished
        agent.endedReason = .endTurn
        agent.archivedReason = nil
        try await store.save(agent)
        let disk = try StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: locations.record(agent.id)))
        #expect(disk.archivedAt == nil && disk.retirement == nil)
    }

    // MARK: Retiring

    @Test func stoppedAfterAnyStepTheAgentIsWholeOrHasATombstone() async throws {
        for step in AgentStore.RetireStep.allCases {
            let (store, locations) = try store()
            let retired = RetiredStore(locations: locations)
            let agent = try archived()
            try await store.save(agent)
            try await store.append(TranscriptEntry(kind: .userMessage("hello")), for: agent.id)

            await store.stop(after: step)
            _ = try? await store.retire(Tombstone(from: agent, retiredAt: Date(), because: .age), into: retired)

            let hasTombstone = retired.loadAll()[agent.id] != nil
            let loaded = await store.loadAll().agents.contains { $0.id == agent.id }
            #expect(hasTombstone, "stopped after \(step): the tombstone is written first")
            if loaded {
                // Still readable means nothing of it was deleted yet.
                #expect(FileManager.default.fileExists(atPath: locations.transcript(agent.id).path))
            }
            // The next start finishes it.
            await store.stop(after: nil)
            await store.finishRetiring([agent.id])
            #expect(!FileManager.default.fileExists(atPath: locations.agent(agent.id).path))
            #expect(await !store.loadAll().agents.contains { $0.id == agent.id })
        }
    }

    @Test func aTombstoneThatCannotBeWrittenDeletesNothing() async throws {
        let (store, locations) = try store()
        let agent = try archived()
        try await store.save(agent)
        // A folder where the file should be: the append cannot open it.
        try FileManager.default.createDirectory(at: locations.retired, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            try await store.retire(Tombstone(from: agent, retiredAt: Date(), because: .age),
                                   into: RetiredStore(locations: locations))
        }
        #expect(FileManager.default.fileExists(atPath: locations.record(agent.id).path))
    }

    @Test func tombstonesReadBackInOrderAndATornLastLineIsSkipped() throws {
        let (_, locations) = try store()
        let retired = RetiredStore(locations: locations)
        var ids: [UUID] = []
        for _ in 0 ..< 5 {
            var agent = try archived()
            agent.id = UUID()
            ids.append(agent.id)
            try retired.append(Tombstone(from: agent, retiredAt: Date(), because: .cap))
        }
        let handle = try FileHandle(forWritingTo: locations.retired)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"torn".utf8))
        try handle.close()
        #expect(Set(retired.loadAll().keys) == Set(ids))
        // And the next append is not glued to the torn line.
        var next = try archived()
        next.id = UUID()
        try retired.append(Tombstone(from: next, retiredAt: Date(), because: .person))
        #expect(retired.loadAll()[next.id] != nil)
    }
}
