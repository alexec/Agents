import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A project is a folder, and the list of them is worked out rather than kept. These
/// are the properties that make that safe: the union is right, the names are right, and
/// nothing about an agent has to be migrated for its folder to appear.
///
/// Agents are seeded by writing records and loading them, which is exactly how an agent
/// written by an older build arrives.
@Suite("Projects", .timeLimit(.minutes(1)))
struct ProjectsTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    /// Made on disk, and returned in the one form a project's folder is ever in, so a
    /// test compares canonical against canonical rather than against how it was typed.
    private func folder(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func agent(in folder: URL, title: String, state: AgentState = .finished,
                       activity: Date = Date(), created: Date = Date(),
                       lastTurnUsage: TurnUsage? = nil,
                       costToDate: [String: Decimal] = [:]) -> Agent {
        Agent(runtimeID: "claude", cwd: folder, title: title, state: state,
              createdAt: created, lastActivityAt: activity, endedReason: .endTurn,
              lastTurnUsage: lastTurnUsage, costToDate: costToDate)
    }

    /// An agent that ran a turn the runtime priced. The record a finished, costed turn
    /// leaves behind, which is the only part of the turn a total reads.
    private func spent(_ amount: Decimal, _ currency: String = "USD") -> (TurnUsage, [String: Decimal]) {
        (TurnUsage(totalTokens: 10, cost: Cost(amount: amount, currency: currency)),
         [currency: amount])
    }

    /// A core holding these agents, arrived at the way a restart arrives at them.
    private func core(_ locations: StoreLocations, seeded: [Agent] = []) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        let core = DaemonCore(store: store,
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        return core
    }

    @Test func aFolderWithAnAgentIsAProjectWithNothingStored() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [agent(in: work, title: "Fix the parser")])

        let projects = await core.allProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.folder == work)
        #expect(projects.first?.name == "api")
        #expect(projects.first?.exists == true)
    }

    @Test func agentsWrittenBeforeProjectsNeedNoMigration() async throws {
        // The whole of the migration story: an agent record carries its folder, so the
        // project is there the first time anybody asks. Nothing is written to make it
        // so, and the store holds no project record at all.
        let (locations, root) = try temporary()
        let work = try folder(root, "legacy")
        let core = try await core(locations, seeded: [agent(in: work, title: "From an older build")])

        #expect(await core.allProjects().count == 1)
        #expect(ProjectStore(locations: locations).load().isEmpty,
                "a derived project keeps no record")
    }

    @Test func aDerivedProjectIsAsOldAsItsOldestAgent() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let core = try await core(locations, seeded: [
            agent(in: work, title: "First", created: old),
            agent(in: work, title: "Second"),
        ])

        #expect(await core.allProjects().first?.project.addedAt == old)
    }

    @Test func eachAgentCountsInExactlyOneGroup() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Waiting", state: .waitingOnUser),
            agent(in: work, title: "Running", state: .running),
            agent(in: work, title: "Done", state: .finished),
            agent(in: work, title: "Stopped", state: .stopped),
        ])

        let counts = await core.allProjects().first?.counts ?? [:]
        #expect(counts[.needsAttention] == 1)
        #expect(counts[.running] == 1)
        #expect(counts[.finished] == 1)
        #expect(counts[.stopped] == 1)
        #expect(counts.values.reduce(0, +) == 4)
    }

    @Test func twoFoldersWithOneNameAreToldApart() async throws {
        let (locations, root) = try temporary()
        let one = try folder(try folder(root, "work"), "api")
        let two = try folder(try folder(root, "side"), "api")
        let core = try await core(locations, seeded: [
            agent(in: one, title: "One"),
            agent(in: two, title: "Two"),
        ])

        #expect(Set(await core.allProjects().map(\.name)) == ["work/api", "side/api"])
    }

    @Test func aNestedFolderIsItsOwnProject() async throws {
        let (locations, root) = try temporary()
        let api = try folder(root, "api")
        let docs = try folder(api, "docs")
        let core = try await core(locations, seeded: [
            agent(in: api, title: "Outer"),
            agent(in: docs, title: "Inner"),
        ])

        let projects = await core.allProjects()
        #expect(projects.count == 2, "matched by exact folder, never by containment")
        #expect(Set(projects.map(\.name)) == ["api", "docs"])
    }

    @Test func aMissingFolderIsStillListedAndSaysSo() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "gone")
        let core = try await core(locations, seeded: [agent(in: work, title: "Its folder went")])
        try FileManager.default.removeItem(at: work)

        let project = await core.allProjects().first
        #expect(project != nil, "the agents and their transcripts are still the point")
        #expect(project?.exists == false)
    }

    @Test func projectsAreOrderedByNewestActivity() async throws {
        let (locations, root) = try temporary()
        let old = try folder(root, "old")
        let new = try folder(root, "new")
        let core = try await core(locations, seeded: [
            agent(in: old, title: "Old", activity: Date(timeIntervalSince1970: 1_700_000_000)),
            agent(in: new, title: "New", activity: Date(timeIntervalSince1970: 1_800_000_000)),
        ])

        #expect(await core.allProjects().map(\.name) == ["new", "old"])
    }

    @Test func aFolderAddedByHandIsAProjectWithNoAgents() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "empty")
        let core = try await core(locations)

        let added = try await core.addProject(work)
        #expect(added.folder == work)
        #expect(added.counts.values.reduce(0, +) == 0)
        #expect(ProjectStore(locations: locations).load().count == 1,
                "this one cannot be derived, so it is kept")
    }

    @Test func addingTheSameFolderTwiceIsNotAnError() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "twice")
        let core = try await core(locations)

        let first = try await core.addProject(work)
        let second = try await core.addProject(work)
        #expect(first.folder == second.folder)
        #expect(ProjectStore(locations: locations).load().count == 1)
    }

    @Test func addingAFolderThatIsNotThereIsRefused() async throws {
        let (locations, root) = try temporary()
        let core = try await core(locations)
        let missing = root.appendingPathComponent("never", isDirectory: true)

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.addProject(missing)
        }
    }

    @Test func archivingIsRememberedAcrossARestart() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let before = try await core(locations, seeded: [agent(in: work, title: "Done")])
        _ = try await before.archiveProject(work)

        // A second core over the same files is what a restart is.
        let restarted = try await core(locations)
        let project = await restarted.allProjects().first
        #expect(project?.project.isArchived == true)
        #expect(project?.project.archivedAt != nil)
    }

    @Test func anArchivedProjectIsLeftOutWhenItIsNotWanted() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [agent(in: work, title: "Done")])
        _ = try await core.archiveProject(work)

        #expect(await core.allProjects(includeArchived: false).isEmpty)
        #expect(await core.allProjects(includeArchived: true).count == 1)
    }

    @Test func unarchivingBringsItBackUnchanged() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Done"),
            agent(in: work, title: "Stopped", state: .stopped),
        ])

        _ = try await core.archiveProject(work)
        _ = try await core.unarchiveProject(work)

        let project = try #require(await core.allProjects().first)
        #expect(project.project.isArchived == false)
        #expect(project.counts[.finished] == 1, "its agents were never touched")
        #expect(project.counts[.stopped] == 1)
    }

    @Test func unarchivingSomethingThatIsNotArchivedIsRefused() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [agent(in: work, title: "Done")])

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.unarchiveProject(work)
        }
    }

    @Test func aProjectWhoseFolderWentCanStillBeUnarchived() async throws {
        // The agents and their transcripts are the point; `exists` says the rest.
        let (locations, root) = try temporary()
        let work = try folder(root, "gone")
        let core = try await core(locations, seeded: [agent(in: work, title: "Done")])
        _ = try await core.archiveProject(work)
        try FileManager.default.removeItem(at: work)

        let back = try await core.unarchiveProject(work)
        #expect(back.project.isArchived == false)
        #expect(back.exists == false)
    }

    @Test func aTrailingSlashDoesNotMakeASecondProject() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [agent(in: work, title: "One")])
        _ = try await core.addProject(URL(filePath: work.path + "/"))

        #expect(await core.allProjects().count == 1)
    }

    // MARK: What it has cost

    @Test func aFoldersTotalIsEveryAgentInItAddedUp() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let (oneUsage, oneCost) = spent(0.25)
        let (twoUsage, twoCost) = spent(0.75)
        let core = try await core(locations, seeded: [
            agent(in: work, title: "One", lastTurnUsage: oneUsage, costToDate: oneCost),
            agent(in: work, title: "Two", lastTurnUsage: twoUsage, costToDate: twoCost),
        ])

        let project = try #require(await core.allProjects().first)
        #expect(project.costToDate["USD"] == 1.0)
        #expect(project.unmeasuredAgents == 0)
    }

    @Test func archivingAnAgentLeavesTheTotalWhereItWas() async throws {
        // The assertion most likely to catch a future regression: archiving is the one
        // operation that visibly removes an agent from a page, and the money it spent
        // was still spent.
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let (usage, cost) = spent(0.40)
        let one = agent(in: work, title: "Archive me", lastTurnUsage: usage, costToDate: cost)
        let (otherUsage, otherCost) = spent(0.60)
        let core = try await core(locations, seeded: [
            one,
            agent(in: work, title: "Keep me", lastTurnUsage: otherUsage, costToDate: otherCost),
        ])

        let before = try #require(await core.allProjects().first).costToDate
        try await core.archive(one.id)
        let after = try #require(await core.allProjects().first).costToDate

        #expect(before["USD"] == 1.0)
        #expect(after == before, "archiving spends nothing and unspends nothing")
    }

    @Test func anEndedAgentIsStillCounted() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let (usage, cost) = spent(0.30)
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Finished", state: .finished,
                  lastTurnUsage: usage, costToDate: cost),
            agent(in: work, title: "Stopped", state: .stopped,
                  lastTurnUsage: usage, costToDate: cost),
        ])

        #expect(await core.allProjects().first?.costToDate["USD"] == 0.60)
    }

    @Test func twoCurrenciesStayTwoFigures() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let (dollars, dollarCost) = spent(1.0, "USD")
        let (pounds, poundCost) = spent(2.0, "GBP")
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Priced in dollars", lastTurnUsage: dollars, costToDate: dollarCost),
            agent(in: work, title: "Priced in pounds", lastTurnUsage: pounds, costToDate: poundCost),
        ])

        let total = try #require(await core.allProjects().first).costToDate
        #expect(total.count == 2, "nothing converted, nothing combined")
        #expect(total["USD"] == 1.0)
        #expect(total["GBP"] == 2.0)
    }

    @Test func aTurnTheRuntimeWouldNotPriceIsCountedRatherThanZeroed() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Ran, never priced",
                  lastTurnUsage: TurnUsage(totalTokens: 10)),
        ])

        let project = try #require(await core.allProjects().first)
        #expect(project.unmeasuredAgents == 1)
        #expect(project.costToDate.isEmpty, "unmeasurable is not free, and not a zero")
    }

    @Test func aProjectWhereNothingHasFinishedHasNoTotalAndNoWarning() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Started, nothing finished", state: .running),
        ])

        let project = try #require(await core.allProjects().first)
        #expect(project.costToDate.isEmpty)
        #expect(project.unmeasuredAgents == 0, "nothing has happened yet is not unmeasured")
    }

    @Test func theTotalRidesTheNotificationThatAlreadyFires() async throws {
        // FR-005, and the assertion that documents why this feature needs no
        // notification of its own: if it ever fails, somebody has moved the cost
        // banking out from under `changed(_:)`.
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        var script = FakeACPAgent.Script()
        script.usage = ["totalTokens": 10, "cost": ["amount": 0.5, "currency": "USD"]]
        let store = try AgentStore(locations: locations)
        let core = DaemonCore(store: store,
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: script))

        let seen = Broadcasts()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.projectChanged else { return }
            guard let params,
                  let summary = try? params.decode(DaemonAPI.ProjectSummary.self)
            else { return }
            seen.append(summary)
        }

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("a project/changed carried the total") {
            seen.all.contains { $0.costToDate["USD"] == 0.5 }
        }
    }

    @Test func archivingAWholeProjectLeavesItsTotalAndItsPlaceInTheList() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let (usage, cost) = spent(1.25)
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Done", lastTurnUsage: usage, costToDate: cost),
        ])

        _ = try await core.archiveProject(work)
        let project = try #require(await core.allProjects(includeArchived: true).first)
        #expect(project.project.isArchived == true)
        #expect(project.costToDate["USD"] == 1.25, "putting a project away unspends nothing")
    }

    @Test func spendInAFolderNobodyAddedIsStillInsideAProject() async throws {
        // FR-012 discharged: there is no folder an agent can be in that is not a
        // project, so no penny falls outside the union and no "Other" row can ever be
        // populated. Anything that starts filtering this list before totalling would
        // lose money silently.
        let (locations, root) = try temporary()
        let never = try folder(root, "never-added")
        let (usage, cost) = spent(3.0)
        let core = try await core(locations, seeded: [
            agent(in: never, title: "Ran where nobody looked", lastTurnUsage: usage, costToDate: cost),
        ])

        #expect(ProjectStore(locations: locations).load().isEmpty, "derived, not kept")
        let project = try #require(await core.allProjects().first)
        #expect(project.folder == never)
        #expect(project.costToDate["USD"] == 3.0)
    }

    @Test func aProjectWhoseFolderWentStillReportsItsSpend() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "gone")
        let (usage, cost) = spent(0.99)
        let core = try await core(locations, seeded: [
            agent(in: work, title: "Its folder went", lastTurnUsage: usage, costToDate: cost),
        ])
        try FileManager.default.removeItem(at: work)

        let project = try #require(await core.allProjects().first)
        #expect(project.exists == false)
        #expect(project.costToDate["USD"] == 0.99)
    }
}

/// The notifications a test watched go by. `setBroadcaster` is called from whatever
/// context the daemon happens to be on, so what it writes into needs a lock of its own.
private final class Broadcasts: @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [DaemonAPI.ProjectSummary] = []

    func append(_ summary: DaemonAPI.ProjectSummary) {
        lock.lock(); defer { lock.unlock() }
        summaries.append(summary)
    }

    var all: [DaemonAPI.ProjectSummary] {
        lock.lock(); defer { lock.unlock() }
        return summaries
    }
}
