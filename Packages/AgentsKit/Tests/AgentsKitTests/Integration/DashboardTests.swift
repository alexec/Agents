import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The Dashboard (074), through the daemon: agents keeping tiles with `set_tile`, the files
/// in the project folder, what the host keeps, and the person's Hide, Show and Remove.
/// Agents are written to disk before the daemon reads it, so no runtime is involved.
@Suite("Dashboard", .timeLimit(.minutes(1)))
struct DashboardTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(minutes: Double) { lock.withLock { date = date.addingTimeInterval(minutes * 60) } }
    }

    private struct Setup {
        var core: DaemonCore
        var locations: StoreLocations
        var project: URL
        var clock: Clock
        var tokens: [String: String]
        var ids: [String: UUID]
    }

    /// A project with the named agents in it, each with a token. `worktree` puts one in a
    /// worktree of the project; `workflow` marks one as started by a workflow.
    private func setUp(_ agents: [(name: String, worktree: Bool, workflow: String?, state: AgentState)]) async throws -> Setup {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDashboard-\(UUID().uuidString)", isDirectory: true)
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        let tree = project.appendingPathComponent(".agents/worktrees/lane", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root.appendingPathComponent("root", isDirectory: true))
        try locations.createDirectories()
        let store = try AgentStore(locations: locations)
        var ids: [String: UUID] = [:]
        for agent in agents {
            var record = Agent(runtimeID: "claude", cwd: agent.worktree ? tree : project, title: agent.name,
                               state: agent.state, endedReason: .endTurn,
                               archivedReason: agent.state == .archived ? .byUser : nil,
                               startedByWorkflow: agent.workflow)
            if agent.worktree {
                record.worktree = AgentWorktree(name: "lane", root: tree, branch: "agents/lane", project: project,
                                                base: "main", madeByApp: true)
            }
            try await store.save(record)
            ids[agent.name] = record.id
        }
        let clock = Clock()
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything,
                              launcher: FakeLauncher(), now: { clock.now })
        await core.loadFromDisk()
        var tokens: [String: String] = [:]
        for (name, id) in ids {
            let token = UUID().uuidString
            await core.bindAppToken(token, to: id)
            tokens[name] = token
        }
        return Setup(core: core, locations: locations, project: project, clock: clock, tokens: tokens, ids: ids)
    }

    private func set(_ s: Setup, _ who: String, _ arguments: JSONValue) async throws -> String {
        try await s.core.setTile(DaemonAPI.SetTileRequest(token: s.tokens[who]!, arguments: arguments))
    }

    private func number(_ id: String, _ value: Int, title: String = "Open bugs") -> JSONValue {
        ["id": .string(id), "title": .string(title), "type": "number", "value": .int(value),
         "source": "gh issue list", "good": "down", "section": "Quality"]
    }

    private func file(_ s: Setup, _ id: String) -> URL {
        s.project.appendingPathComponent(".agents/dashboard/\(id).json")
    }

    // MARK: US1

    @Test func aSetWritesTheProjectFileAndTheSnapshotShowsIt() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        let answer = try await set(s, "Lead", number("open_bugs", 4))
        #expect(answer.contains("Set \"open_bugs\""))
        let tile = try TileFile.read(Data(contentsOf: file(s, "open_bugs")))
        #expect(tile.number?.value == 4)
        #expect(tile.keeper == .agent(s.ids["Lead"]!))
        let snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(snapshot.tiles.map(\.id) == ["open_bugs"])
        #expect(snapshot.tiles[0].keeper.name == "Lead")
        #expect(snapshot.tiles[0].setAt == s.clock.now)
        #expect(snapshot.tiles[0].points.count == 1)
    }

    @Test func theSameValueLeavesTheFileAloneAndRefreshesItsAge() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 4))
        let before = try Data(contentsOf: file(s, "open_bugs"))
        let modified = try FileManager.default.attributesOfItem(atPath: file(s, "open_bugs").path)[.modificationDate] as? Date
        s.clock.advance(minutes: 90)
        try await Task.sleep(for: .milliseconds(20))
        let answer = try await set(s, "Lead", number("open_bugs", 4))
        #expect(answer.contains("Unchanged; its age is refreshed."))
        #expect(try Data(contentsOf: file(s, "open_bugs")) == before)
        let after = try FileManager.default.attributesOfItem(atPath: file(s, "open_bugs").path)[.modificationDate] as? Date
        #expect(after == modified)
        let snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(snapshot.tiles[0].setAt == s.clock.now)
        #expect(!snapshot.tiles[0].tile!.description.contains("1800"))
    }

    @Test func anotherAgentsTileIsRefusedNamingItsKeeper() async throws {
        let s = try await setUp([("Lead", false, nil, .finished), ("Helper", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 4))
        await #expect {
            _ = try await set(s, "Helper", number("open_bugs", 9))
        } throws: { error in
            (error as? JSONRPCError)?.message.contains("kept by the agent \u{201C}Lead\u{201D}") == true
        }
        #expect(try TileFile.read(Data(contentsOf: file(s, "open_bugs"))).number?.value == 4)
    }

    @Test func anAgentInAWorktreeWritesTheProjectFolder() async throws {
        let s = try await setUp([("Lane", true, nil, .finished)])
        _ = try await set(s, "Lane", number("lane_tile", 1))
        #expect(FileManager.default.fileExists(atPath: file(s, "lane_tile").path))
        let worktreeCopy = s.project.appendingPathComponent(".agents/worktrees/lane/.agents/dashboard/lane_tile.json")
        #expect(!FileManager.default.fileExists(atPath: worktreeCopy.path))
    }

    @Test func aWorktreesCopyIsNeverRead() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        let copy = s.project.appendingPathComponent(".agents/worktrees/lane/.agents/dashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try TileFile(title: "Old", type: .note, keeper: TileKeeper(agent: UUID().uuidString), note: TileNote(markdown: "x"))
            .fileData().write(to: copy.appendingPathComponent("old.json"))
        #expect(await s.core.dashboardSnapshot(s.project).tiles.isEmpty)
    }

    @Test func manyPostsAtOnceLeaveEveryFileWhole() async throws {
        let names = (1...5).map { "Agent \($0)" }
        let s = try await setUp(names.map { ($0, false, nil, .finished) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, name) in names.enumerated() {
                for round in 0..<20 {
                    group.addTask {
                        let rows: [JSONValue] = (0..<10).map { row in .array([.string("\(name) \(round) \(row)"), .int(row)]) }
                        _ = try await set(s, name, ["id": .string("t\(index)"), "title": .string(name), "type": "table",
                                                    "source": "test", "columns": ["What", "N"], "rows": .array(rows)])
                    }
                }
            }
            try await group.waitForAll()
        }
        for index in 0..<5 {
            let tile = try TileFile.read(Data(contentsOf: file(s, "t\(index)")))
            let owner = tile.table!.rows.map { $0[0].text.split(separator: " ").prefix(2).joined(separator: " ") }
            #expect(Set(owner).count == 1, "rows from one post only")
        }
    }

    // MARK: US2

    @Test func aTilePastItsTimeIsStaleAndAStaleStatusSaysNothing() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", ["id": "live", "title": "Live", "type": "status", "level": "ok",
                                      "line": "f0711855", "stale_after_hours": 1])
        var snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(DashboardModel.shownLevel(snapshot.tiles[0], now: snapshot.now) == .ok)
        s.clock.advance(minutes: 61)
        snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(DashboardModel.isStale(snapshot.tiles[0], now: snapshot.now))
        #expect(DashboardModel.shownLevel(snapshot.tiles[0], now: snapshot.now) == .unknown)
        #expect(DashboardModel.ageWords(snapshot.tiles[0], now: snapshot.now) == "1 hour old")
        #expect(DashboardModel.summary(snapshot).line.isEmpty)
        _ = try await set(s, "Lead", ["id": "live", "title": "Live", "type": "status", "level": "ok",
                                      "line": "f0711855", "stale_after_hours": 1])
        snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(!DashboardModel.isStale(snapshot.tiles[0], now: snapshot.now))
    }

    // MARK: US3

    @Test func hidingSurvivesTheKeepersPostsAndShowBringsItBack() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 4))
        try await s.core.setTileHidden(.init(folder: s.project, id: "open_bugs"), hidden: true)
        let answer = try await set(s, "Lead", number("open_bugs", 3))
        #expect(answer.contains("hidden this tile"))
        #expect(try TileFile.read(Data(contentsOf: file(s, "open_bugs"))).isHidden)
        #expect(DashboardModel.summary(await s.core.dashboardSnapshot(s.project)).tiles == 0)
        try await s.core.setTileHidden(.init(folder: s.project, id: "open_bugs"), hidden: false)
        #expect(try !TileFile.read(Data(contentsOf: file(s, "open_bugs"))).isHidden)
    }

    @Test func removeHoldsUntilTheKeepersNextPostWhichIsToldWhoAndWhen() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 4))
        try await s.core.removeTileByPerson(.init(folder: s.project, id: "open_bugs"), from: .mac)
        #expect(!FileManager.default.fileExists(atPath: file(s, "open_bugs").path))
        #expect(await s.core.dashboardSnapshot(s.project).tiles.isEmpty)
        s.clock.advance(minutes: 30)
        let answer = try await set(s, "Lead", number("open_bugs", 5))
        #expect(answer.contains("had been removed by the person, on the Mac"))
        #expect(answer.contains("posting has put it back"))
        let snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(snapshot.tiles.map(\.id) == ["open_bugs"])
        #expect(snapshot.tiles[0].points.count == 1, "its history went with it")
        let again = try await set(s, "Lead", number("open_bugs", 6))
        #expect(!again.contains("removed"), "told once")
    }

    // MARK: US5

    @Test func aWorkflowsRunsShareItsTiles() async throws {
        let s = try await setUp([("Run 1", false, "nightly", .finished), ("Run 2", false, "nightly", .finished)])
        _ = try await set(s, "Run 1", number("tests", 1200, title: "Tests"))
        _ = try await set(s, "Run 2", number("tests", 1203, title: "Tests"))
        let tile = try TileFile.read(Data(contentsOf: file(s, "tests")))
        #expect(tile.keeper == .workflow("nightly"))
        #expect(tile.number?.value == 1203)
    }

    @Test func anArchivedKeepersTileCanBeTakenOverAndTheHandoverIsKept() async throws {
        let s = try await setUp([("Old lead", false, nil, .archived), ("New lead", false, nil, .finished)])
        let old = s.tokens["Old lead"]!
        _ = try await s.core.setTile(.init(token: old, arguments: number("open_bugs", 4)))
        await #expect(throws: JSONRPCError.self) { _ = try await set(s, "New lead", number("open_bugs", 3)) }
        var arguments = number("open_bugs", 3)
        if case .object(var fields) = arguments { fields["take_over"] = true; arguments = .object(fields) }
        let answer = try await set(s, "New lead", arguments)
        #expect(answer.contains("You keep this tile now"))
        let snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(snapshot.tiles[0].keeper.name == "New lead")
        #expect(snapshot.tiles[0].keeperChanges.count == 1)
    }

    @Test func readDashboardListsEveryTileWithItsKeeperAndPoints() async throws {
        let s = try await setUp([("Lead", false, nil, .finished), ("Helper", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 6))
        s.clock.advance(minutes: 5)
        _ = try await set(s, "Lead", number("open_bugs", 4))
        let read = try await s.core.readDashboard(.init(token: s.tokens["Helper"]!))
        #expect(read.contains("open_bugs — Open bugs [number] in Quality"))
        #expect(read.contains("keeper: Lead"))
        #expect(read.contains("last points: 6 at"))
    }

    // MARK: Files changed outside

    @Test func aHandEditIsShownAndMarkedAndABrokenFileIsABrokenTile() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 4))
        var tile = try TileFile.read(Data(contentsOf: file(s, "open_bugs")))
        tile.number?.value = 99
        try tile.fileData().write(to: file(s, "open_bugs"))
        try Data("{ not json".utf8).write(to: file(s, "broken"))
        let snapshot = await s.core.dashboardSnapshot(s.project)
        let edited = try #require(snapshot.tiles.first { $0.id == "open_bugs" })
        #expect(edited.changedOutside)
        #expect(edited.tile?.number?.value == 99)
        let broken = try #require(snapshot.tiles.first { $0.id == "broken" })
        #expect(broken.tile == nil)
        #expect(broken.problem != nil)
    }

    // MARK: Limits

    @Test func overTheHourlyLimitIsRefusedAndNothingIsWritten() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        for index in 0..<TileLimits.setsPerHour {
            _ = try await set(s, "Lead", number("n\(index % 3)", index))
        }
        await #expect {
            _ = try await set(s, "Lead", number("n9", 1))
        } throws: { error in
            (error as? JSONRPCError)?.message.contains("120 tiles in the last hour") == true
        }
        #expect(!FileManager.default.fileExists(atPath: file(s, "n9").path))
    }

    @Test func checksRefuseInWordsNamingTheField() {
        func refusal(_ arguments: JSONValue) -> String? {
            if case .failure(let problem) = TileCheck.read(arguments) { return problem.message }
            return nil
        }
        #expect(refusal(["id": "Bad Id", "title": "x", "type": "note", "markdown": "x"])?.contains("`id`") == true)
        #expect(refusal(["id": "n", "title": "x", "type": "number", "value": 1])?.contains("`source`") == true)
        #expect(refusal(["id": "s", "title": "x", "type": "status", "level": "green", "line": "x"])?.contains("`level`") == true)
        let rows = JSONValue.array((0..<51).map { _ in .array(["a"]) })
        #expect(refusal(["id": "t", "title": "x", "type": "table", "source": "s", "columns": ["A"], "rows": rows])?
            .contains("at most 50 rows") == true)
        #expect(refusal(["id": "l", "title": "x", "type": "link", "url": "file:///etc/passwd"])?.contains("http") == true)
        #expect(refusal(["id": "n", "title": "x", "type": "note", "markdown": .string(String(repeating: "a", count: 5000))])?
            .contains("4 KB") == true)
        #expect(refusal(["id": "ok", "title": "x", "type": "note", "markdown": "fine"]) == nil)
    }

    // MARK: History

    @Test func compactionKeepsMinutesForAWeekHoursToNinetyDaysAndDaysToAYear() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [TilePoint] = []
        // Every 10 minutes for 400 days.
        var at = now.addingTimeInterval(-400 * 86_400)
        while at <= now {
            points.append(TilePoint(at: at, value: at.timeIntervalSince1970))
            at = at.addingTimeInterval(600)
        }
        let folded = DashboardStore.compacted(points, now: now)
        let week = folded.filter { now.timeIntervalSince($0.at) <= 7 * 86_400 }
        let hours = folded.filter { (7 * 86_400 + 3600...90 * 86_400).contains(now.timeIntervalSince($0.at)) }
        let days = folded.filter { now.timeIntervalSince($0.at) > 91 * 86_400 }
        #expect(week.count >= 7 * 144 - 1)
        #expect((83 * 24 - 30...83 * 24 + 30).contains(hours.count))
        #expect((270...276).contains(days.count))
        #expect(folded.allSatisfy { now.timeIntervalSince($0.at) <= 365 * 86_400 })
        let sent = DashboardStore.downsampled(folded, since: now.addingTimeInterval(-30 * 86_400), limit: 120)
        #expect(sent.count == 120)
        #expect(sent.last == folded.last)
    }

    @Test func theRowSummarySaysTheWorstLiveStatusAndTheFirstNumber() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keeper = KeeperView(kind: .agent, id: "a", name: "Lead", state: .active)
        func view(_ id: String, _ file: TileFile, made: Double, setAgo: Double = 60) -> TileView {
            TileView(id: id, tile: file, made: now.addingTimeInterval(made), setAt: now.addingTimeInterval(-setAgo), keeper: keeper)
        }
        let k = TileKeeper(agent: "a")
        let snapshot = DashboardSnapshot(folder: URL(filePath: "/p"), tiles: [
            view("bugs", TileFile(title: "Open bugs", type: .number, keeper: k, number: TileNumber(value: 4)), made: 2),
            view("live", TileFile(title: "Live", type: .status, keeper: k, status: TileStatus(level: .bad, line: "down")), made: 1),
            view("old", TileFile(title: "Old", type: .status, keeper: k, status: TileStatus(level: .bad, line: "x")), made: 0,
                 setAgo: 2 * 86_400),
        ], now: now)
        let summary = DashboardModel.summary(snapshot)
        #expect(summary.bad == 1)
        #expect(summary.line == "1 needs a look · Open bugs 4")
        #expect(DashboardModel.sections(snapshot).first?.tiles.map(\.id) == ["old", "live", "bugs"])
    }
}

private extension TileFile {
    var description: String { (try? String(data: fileData(), encoding: .utf8)) ?? "" }
}
