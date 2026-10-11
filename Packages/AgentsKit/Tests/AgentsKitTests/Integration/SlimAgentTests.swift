import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The daemon stops carrying archived agents it is not using (051, US6): slim in memory,
/// read at start from one index, whole again while someone reads them, and nothing kept
/// from their live days once archived.
@Suite("Slim archived agents", .timeLimit(.minutes(1)))
struct SlimAgentTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSlimTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func core(_ locations: StoreLocations, seeded: [Agent] = [], clock: Clock = Clock(),
                      launcher: FakeLauncher = FakeLauncher(script: .init())) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded {
            try await store.save(agent)
            try await store.append(TranscriptEntry(kind: .userMessage("hello")), for: agent.id)
        }
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything,
                              launcher: launcher, now: { clock.now })
        await core.loadFromDisk()
        return core
    }

    private func agent(_ work: URL, state: AgentState, title: String = "one") -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: work, title: title, state: state, endedReason: .endTurn,
                          archivedReason: state == .archived ? .byUser : nil,
                          archivedAt: state == .archived ? Date(timeIntervalSince1970: 1_799_900_000) : nil)
        agent.availableCommands = [SlashCommand(name: "review", description: "Review the code")]
        agent.advertisedOptions = []
        return agent
    }

    private func onDisk(_ locations: StoreLocations, _ id: UUID) throws -> Agent {
        try StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: locations.record(id)))
    }

    // MARK: Slim in memory, whole on disk

    @Test func afterStartArchivedAgentsAreSlimAndLiveOnesWhole() async throws {
        let (locations, work) = try temporary()
        let archived = agent(work, state: .archived), live = agent(work, state: .finished)
        let core = try await core(locations, seeded: [archived, live])
        #expect(await core.agent(archived.id)?.isSlim == true)
        #expect(await core.agent(archived.id)?.availableCommands.isEmpty == true)
        #expect(await core.agent(live.id)?.isSlim == false)
        #expect(await core.agent(live.id)?.availableCommands.map(\.name) == ["review"])
    }

    @Test func readingItMakesItWholeAndTenMinutesUnreadSlimsItAgain() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let archived = agent(work, state: .archived)
        let core = try await core(locations, seeded: [archived], clock: clock)

        _ = try await core.transcript(.init(agentID: archived.id))
        #expect(await core.agent(archived.id)?.isSlim == false)
        #expect(await core.agent(archived.id)?.availableCommands.map(\.name) == ["review"])

        clock.now = clock.now.addingTimeInterval(9 * 60)
        await core.slimIdle()
        #expect(await core.agent(archived.id)?.isSlim == false)
        clock.now = clock.now.addingTimeInterval(2 * 60)
        await core.slimIdle()
        #expect(await core.agent(archived.id)?.isSlim == true)
    }

    @Test func aWindowWatchingItKeepsItWhole() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let archived = agent(work, state: .archived)
        let core = try await core(locations, seeded: [archived], clock: clock)
        try await core.reportPresence(.init(watching: archived.id, active: true), from: .mac, connection: UUID())
        await eventually("the watched agent was made whole") { await core.agent(archived.id)?.isSlim == false }
        clock.now = clock.now.addingTimeInterval(60 * 60)
        await core.slimIdle()
        #expect(await core.agent(archived.id)?.isSlim == false)
    }

    @Test func unarchivingBringsBackTheLists() async throws {
        let (locations, work) = try temporary()
        let archived = agent(work, state: .archived)
        let core = try await core(locations, seeded: [archived])
        try await core.unarchive(archived.id)
        #expect(await core.agent(archived.id)?.isSlim == false)
        #expect(await core.agent(archived.id)?.availableCommands.map(\.name) == ["review"])
    }

    @Test func changingASlimAgentKeepsItsListsOnDisk() async throws {
        let (locations, work) = try temporary()
        let archived = agent(work, state: .archived)
        let core = try await core(locations, seeded: [archived])
        await core.markRead(archived.id)
        await core.flushSaves()
        #expect(try onDisk(locations, archived.id).availableCommands.map(\.name) == ["review"])
    }

    // MARK: The index

    @Test func theSecondStartReadsArchivedAgentsFromTheIndex() async throws {
        let (locations, work) = try temporary()
        let archived = agent(work, state: .archived, title: "from the record")
        _ = try await core(locations, seeded: [archived])
        #expect(FileManager.default.fileExists(atPath: locations.archiveIndex.path))

        // A record that could not be read, but no newer than its entry: start never opens it.
        let record = locations.record(archived.id)
        try Data("not json".utf8).write(to: record)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: record.path)
        let again = try await core(locations)
        #expect(await again.agent(archived.id)?.title == "from the record")
    }

    /// The hourly check writes `archive.json` only when the index changed: on a big
    /// archive it is megabytes a time (#177).
    @Test func theHourlyCheckLeavesAnUnchangedIndexAlone() async throws {
        let (locations, work) = try temporary()
        let archived = agent(work, state: .archived)
        let live = agent(work, state: .finished, title: "live")
        let core = try await core(locations, seeded: [archived, live])
        await core.checkRetention()
        // Gone from disk, so any write at all would show.
        try FileManager.default.removeItem(at: locations.archiveIndex)

        await core.checkRetention()
        await core.checkRetention()
        #expect(!FileManager.default.fileExists(atPath: locations.archiveIndex.path),
                "nothing changed, so nothing was written")

        try await core.archive(live.id)
        await core.checkRetention()
        #expect(ArchiveIndex(locations: locations).load()?[live.id] != nil, "a change is written")
    }

    @Test func aRecordNewerThanItsEntryWins() async throws {
        let (locations, work) = try temporary()
        let archived = agent(work, state: .archived, title: "old title")
        _ = try await core(locations, seeded: [archived])
        var renamed = try onDisk(locations, archived.id)
        renamed.title = "new title"
        try StoreCoding.encoder.encode(renamed).write(to: locations.record(archived.id))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)],
                                              ofItemAtPath: locations.record(archived.id).path)
        let again = try await core(locations)
        #expect(await again.agent(archived.id)?.title == "new title")
    }

    @Test func aFolderTheIndexDoesNotNameIsReadAndACorruptIndexIsRebuilt() async throws {
        let (locations, work) = try temporary()
        let first = agent(work, state: .archived, title: "first")
        _ = try await core(locations, seeded: [first])
        let later = agent(work, state: .archived, title: "later")
        try await AgentStore(locations: locations).save(later)
        let again = try await core(locations)
        #expect(await again.agent(later.id)?.title == "later")

        try Data("garbage".utf8).write(to: locations.archiveIndex)
        let rebuilt = try await core(locations)
        #expect(await rebuilt.agent(first.id)?.title == "first")
        #expect(ArchiveIndex(locations: locations).load()?[first.id] != nil)
    }

    // MARK: What archiving lets go of

    @Test func archivingLetsGoOfEverythingHeldForItLiveExceptTheStopCount() async throws {
        let (locations, work) = try temporary()
        let live = agent(work, state: .finished)
        let core = try await core(locations, seeded: [live])
        await core.fillLiveState(for: live.id)
        #expect(await !core.liveStateKeys(for: live.id).isEmpty)
        try await core.archive(live.id)
        #expect(await core.liveStateKeys(for: live.id) == [])
        #expect(await core.stops[live.id] != nil)
    }

    /// P20261011-1: a prompt's pictures stayed in `lastPrompts` after its agent was
    /// archived, so the daemon grew by every attachment ever sent until it restarted.
    @Test func archivingLetsGoOfThePromptsAndTheirPictures() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations)
        let picture = Attachment.image(Data(repeating: 7, count: 1 << 20), mimeType: "image/png", name: "a.png")
        var ids: [UUID] = []
        for _ in 0..<5 {
            let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "look"))
            await eventually("it finished") { await core.agent(id)?.state == .finished }
            try await core.prompt(.init(agentID: id, text: "and this", attachments: [picture]))
            await eventually("it finished again") {
                let finished = await core.agent(id)?.state == .finished
                let held = await core.heldPromptBytes(for: id)
                return finished && held >= 1 << 20
            }
            ids.append(id)
        }
        for id in ids { try await core.archive(id) }
        for id in ids { #expect(await core.liveStateKeys(for: id) == []) }
        #expect(await core.lastPrompts.count == 0)
        #expect(await core.heldPromptBytes() == 0)
    }

    /// P20261011-1's measurement, run by hand: 50 prompt-with-a-picture → archive cycles,
    /// then the bytes `lastPrompts` holds and the process's footprint, printed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTS_MEASURE_HELD_PROMPTS"] != nil))
    func measureWhatFiftyArchivedPicturePromptsLeaveHeld() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations)
        let footprintBefore = Self.footprint()
        for cycle in 0..<50 {
            // Different bytes each time, so no two pictures share storage.
            let picture = Attachment.image(Data(repeating: UInt8(cycle), count: 1 << 20),
                                           mimeType: "image/png", name: "a.png")
            let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "look"))
            await eventually("it finished") { await core.agent(id)?.state == .finished }
            try await core.prompt(.init(agentID: id, text: "and this", attachments: [picture]))
            await eventually("it finished again") {
                let finished = await core.agent(id)?.state == .finished
                let held = await core.lastPrompts[id]?.blocks.count ?? 0
                return finished && held > 1
            }
            try await core.archive(id)
        }
        let held = await core.heldPromptBytes()
        let grown = (Self.footprint() - footprintBefore) / 1_048_576
        print("MEASURE held-prompt-bytes=\(held) lastPrompts=\(await core.lastPrompts.count) footprint-growth-mb=\(grown)")
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    @Test func workStillUnwindingAfterAnArchiveDoesNothingToTheAgent() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        let core = try await core(locations, launcher: FakeLauncher(script: script))
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "long job"))
        await eventually("it is working") { await core.agent(id)?.state == .running }
        try await core.prompt(.init(agentID: id, text: "then this"))
        try await core.archive(id)
        let entries = try await core.transcript(.init(agentID: id)).entries.count
        try await Task.sleep(for: .milliseconds(900))
        #expect(await core.agent(id)?.state == .archived)
        #expect(try await core.transcript(.init(agentID: id)).entries.count == entries)
    }
}

extension DaemonCore {
    /// For the tests: an entry in each of the maps archiving must let go of.
    func fillLiveState(for id: UUID) {
        artifactEdits[id] = []
        reportedChanges.set(HeldChanges(), for: id)
        shellWatchers[id] = [UUID()]
        interrupted[id] = .running
        resuming.insert(id)
        sending.insert(id)
        needsBriefing.insert(id)
        held.insert(id)
        shownPlanFiles[id] = ["plan.md"]
        appTokens["token-\(id)"] = id
        lastPrompts[id] = SentPrompt(text: "hello", blocks: [.text("hello")], from: .person, preface: nil,
                                     costBefore: [:])
        latestRateLimit[id] = RateLimitInfo(status: "allowed")
        messageHops[id] = 1
        viewContexts[id] = [UUID(): "a view"]
        thirdPartyCalls[id] = ["call": ThirdPartyCall(candidates: [], call: ToolCall(toolCallID: "call", title: "call"))]
    }

    /// For the tests: the bytes the prompts kept for sending again hold, for one agent
    /// or all of them.
    func heldPromptBytes(for id: UUID? = nil) -> Int {
        lastPrompts.filter { id == nil || $0.key == id }.values.flatMap(\.blocks).reduce(0) { sum, block in
            switch block {
            case .text(let text): sum + text.utf8.count
            case .image(let data, _, _), .audio(let data, _): sum + data.count
            case .resource(_, let text, let blob, _, _): sum + (blob?.count ?? 0) + (text?.utf8.count ?? 0)
            default: sum
            }
        }
    }

    /// For the tests: wait for every queued write to reach the disk.
    func flushSaves() async { await saveTail?.value }
}
