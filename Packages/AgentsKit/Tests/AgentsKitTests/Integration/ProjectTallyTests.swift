import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Each project's summary is kept as its agents change rather than counted again from
/// every agent there has ever been (#164). These check the kept numbers against the long
/// way round, `rebuiltProjects`, after every one of many random changes, and that a page
/// at a time lists the same agents a single list would.
@Suite("Project tallies", .timeLimit(.minutes(2)))
struct ProjectTallyTests {
    /// The same changes every run, so a failure can be run again.
    private struct Dice: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsTallyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func folders(_ root: URL, count: Int) throws -> [URL] {
        try (0..<count).map { n in
            let url = root.appendingPathComponent("p\(n)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return Project.standardize(url)
        }
    }

    private static let states: [AgentState] = [.starting, .running, .waitingOnUser, .finished, .stopped, .archived]
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// A random agent, or a random change to one: state, folder, times, cost, report.
    private func randomAgent(_ agent: Agent?, in folders: [URL], dice: inout Dice) -> Agent {
        var agent = agent ?? Agent(runtimeID: "claude", cwd: folders.randomElement(using: &dice)!,
                                   title: "agent", state: .finished,
                                   createdAt: Self.base.addingTimeInterval(Double(Int.random(in: 0..<500, using: &dice))),
                                   lastActivityAt: Self.base)
        switch Int.random(in: 0..<6, using: &dice) {
        case 0:
            agent.state = Self.states.randomElement(using: &dice)!
            agent.archivedAt = agent.state == .archived ? Self.base : nil
        case 1: agent.cwd = folders.randomElement(using: &dice)!
        case 2:
            // Earlier as well as later: an agent that held its project's newest activity
            // can move back, which is the one number that has to be found again.
            agent.lastActivityAt = Self.base.addingTimeInterval(Double(Int.random(in: 0..<1_000, using: &dice)))
        case 3:
            let currency = ["USD", "EUR"].randomElement(using: &dice)!
            if Bool.random(using: &dice) {
                agent.costToDate[currency] = Decimal(Int.random(in: 0..<500, using: &dice)) / 100
            } else {
                agent.costToDate[currency] = nil
            }
            agent.lastTurnUsage = Bool.random(using: &dice) ? TurnUsage(totalTokens: 10) : nil
        case 4:
            agent.report = Bool.random(using: &dice)
                ? WorkReport(outcome: [.done, .needsAnswer, .stuck].randomElement(using: &dice)!, message: "said", at: Self.base)
                : nil
        default:
            agent.createdAt = Self.base.addingTimeInterval(Double(Int.random(in: 0..<500, using: &dice)))
        }
        return agent
    }

    private func byFolder(_ summaries: [DaemonAPI.ProjectSummary]) -> [URL: DaemonAPI.ProjectSummary] {
        Dictionary(summaries.map { ($0.folder, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func keptSummariesMatchTheFullCountAfterEveryChange() async throws {
        let (locations, root) = try temporary()
        let folders = try folders(root, count: 4)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        var dice = Dice(state: 164)
        var ids: [UUID] = []
        for step in 0..<600 {
            let roll = Int.random(in: 0..<10, using: &dice)
            if ids.isEmpty || roll < 3 {
                let agent = randomAgent(nil, in: folders, dice: &dice)
                ids.append(agent.id)
                await core.changed(agent)
            } else if roll == 9 {
                // Gone altogether, as a deleted agent goes.
                let id = ids.remove(at: Int.random(in: 0..<ids.count, using: &dice))
                await core.forgetForTest(id)
            } else {
                let id = ids.randomElement(using: &dice)!
                let before = await core.agent(id)
                await core.changed(randomAgent(before, in: folders, dice: &dice))
            }
            let kept = byFolder(await core.allProjects())
            let rebuilt = byFolder(await core.rebuiltProjects())
            #expect(kept == rebuilt, "step \(step)")
            if kept != rebuilt { return }
            // What the windows were last told of each project is what it is now.
            for (folder, summary) in await core.lastProjectSent where rebuilt[folder] != nil {
                #expect(summary == rebuilt[folder], "told at step \(step)")
            }
        }
    }

    @Test func pagesListWhatOneListWould() async throws {
        let (locations, root) = try temporary()
        let folders = try folders(root, count: 3)  // index-ok: three, or it throws
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        var dice = Dice(state: 165)
        for n in 0..<250 {
            var agent = randomAgent(nil, in: folders, dice: &dice)
            agent.state = n % 3 == 0 ? .archived : .finished
            // Ties on activity, so the id has to order them.
            agent.lastActivityAt = Self.base.addingTimeInterval(Double(n / 4))
            await core.changed(agent)
        }
        // Live only, everywhere: what a window lists on connect.
        var request: DaemonAPI.ListRequest? = .init(includeArchived: false, limit: 7, lean: true)
        var paged: [Agent] = []
        while let asking = request {
            let page = await core.listAgents(asking)
            #expect(page.count <= 7)
            paged += page
            request = asking.next(after: page)
        }
        let live = await core.allAgents(includeArchived: false)
        #expect(paged.map(\.id) == live.map(\.id))

        // Archived, one project at a time: what an Archived fold asks.
        let folder = folders[0]
        request = .init(archivedOnly: true, folder: folder, limit: 5, lean: true)
        paged = []
        while let asking = request {
            let page = await core.listAgents(asking)
            paged += page
            request = asking.next(after: page)
        }
        let archived = await core.allAgents().filter { $0.state == .archived && $0.projectFolder == folder }
        #expect(paged.map(\.id) == archived.map(\.id))
        #expect(!archived.isEmpty)

        // A list of everything is the live agents, at most a page of them.
        let everything = await core.listAgents(.init())
        #expect(everything.allSatisfy { $0.state != .archived })
        #expect(everything.count == min(live.count, DaemonAPI.ListRequest.defaultLimit))

        // One agent, archived or not, is found without the rest.
        if let one = archived.first {
            #expect(await core.listAgents(.whole(one.id)).map(\.id) == [one.id])
        }
    }
}

extension DaemonCore {
    /// Out of memory only, for a test that only counts.
    func forgetForTest(_ id: UUID) {
        guard let agent = agents.removeValue(forKey: id) else { return }
        projectChanged(forAgentIn: agent.projectFolder)
    }
}
