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
        try #require(snapshot.tiles.map(\.id) == ["open_bugs"])
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
        try #require(snapshot.tiles.count == 1)
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
        try #require(snapshot.tiles.count == 1)
        #expect(DashboardModel.shownLevel(snapshot.tiles[0], now: snapshot.now) == .ok)
        s.clock.advance(minutes: 61)
        snapshot = await s.core.dashboardSnapshot(s.project)
        try #require(snapshot.tiles.count == 1)
        #expect(DashboardModel.isStale(snapshot.tiles[0], now: snapshot.now))
        #expect(DashboardModel.shownLevel(snapshot.tiles[0], now: snapshot.now) == .unknown)
        #expect(DashboardModel.ageWords(snapshot.tiles[0], now: snapshot.now) == "1 hour old")
        #expect(DashboardModel.summary(snapshot).line.isEmpty)
        _ = try await set(s, "Lead", ["id": "live", "title": "Live", "type": "status", "level": "ok",
                                      "line": "f0711855", "stale_after_hours": 1])
        snapshot = await s.core.dashboardSnapshot(s.project)
        try #require(snapshot.tiles.count == 1)
        #expect(!DashboardModel.isStale(snapshot.tiles[0], now: snapshot.now))
    }

    @Test func aKeptSummaryMovesWhenATileGoesStaleOrItsFileChanges() async throws {
        // Kept between calls (#204), so nothing has to be read again until it moves.
        let s = try await setUp([("Lead", false, nil, .finished)])
        await s.core.adoptWorkflows(in: s.project)
        _ = try await set(s, "Lead", ["id": "ci", "title": "CI", "type": "status", "level": "bad",
                                      "line": "red", "stale_after_hours": 1])
        #expect(await s.core.dashboardSummaries().first?.bad == 1)
        #expect(await s.core.dashboardSummaryCache[s.project] != nil, "kept for a watched project")
        // Stale with no file changing: what was kept no longer holds.
        s.clock.advance(minutes: 61)
        #expect(await s.core.dashboardSummaries().first?.bad == 0)
        // A change by hand reaches it through the project's watch.
        _ = try await set(s, "Lead", ["id": "ci", "title": "CI", "type": "status", "level": "bad",
                                      "line": "red", "stale_after_hours": 1])
        #expect(await s.core.dashboardSummaries().first?.bad == 1)
        var tile = try TileFile.read(Data(contentsOf: file(s, "ci")))
        tile.hidden = true
        try tile.fileData().write(to: file(s, "ci"))
        await s.core.projectFilesChanged([file(s, "ci").deletingLastPathComponent()], in: s.project)
        #expect(await s.core.dashboardSummaries().first?.tiles == 0)
        await s.core.stopWatchingAllWorkflows()
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
        try #require(snapshot.tiles.map(\.id) == ["open_bugs"])
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
        try #require(snapshot.tiles.count == 1)
        #expect(snapshot.tiles[0].keeper.name == "New lead")
        #expect(snapshot.tiles[0].keeperChanges.count == 1)
    }

    /// A tile handed between keepers keeps its latest changes only (#218).
    @Test func keeperChangesAreCapped() async throws {
        let names = (0..<13).map { "Lead \($0)" }
        let s = try await setUp(names.map { ($0, false, nil, .archived) })
        for name in names {
            var arguments = number("open_bugs", 4)
            if case .object(var fields) = arguments { fields["take_over"] = true; arguments = .object(fields) }
            _ = try await set(s, name, arguments)
        }
        let snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(snapshot.tiles[0].keeperChanges.count == DashboardState.keeperChangesKept)
        #expect(snapshot.tiles[0].keeperChanges.last?.to.contains("Lead 12") == true)
    }

    /// Each agent's sets are kept for their hour, and every agent's past it go with the
    /// next set, not only the caller's (#218).
    @Test func setsPastTheirHourAreDropped() async throws {
        let s = try await setUp([("Old", false, nil, .finished), ("New", false, nil, .finished)])
        _ = try await set(s, "Old", number("a", 1))
        s.clock.advance(minutes: 61)
        _ = try await set(s, "New", number("b", 1))
        let sets = await s.core.dashboardStore.state(s.project).sets
        #expect(Array(sets.keys) == [s.ids["New"]!.uuidString])
    }

    @Test func readDashboardListsEveryTileWithItsKeeperAndPoints() async throws {
        let s = try await setUp([("Lead", false, nil, .finished), ("Helper", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 6))
        s.clock.advance(minutes: 60)
        _ = try await set(s, "Lead", number("open_bugs", 4))
        let read = try await s.core.readDashboard(.init(token: s.tokens["Helper"]!))
        #expect(read.contains("## Quality\n\n1. open_bugs — Open bugs [number]"))
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

    @Test func compactionKeepsHoursForAWeekAndDaysToNinetyDays() {
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
        let days = folded.filter { now.timeIntervalSince($0.at) > 7 * 86_400 + 86_400 }
        #expect((7 * 24 - 1...7 * 24 + 1).contains(week.count))
        #expect((81...83).contains(days.count))
        #expect(folded.allSatisfy { now.timeIntervalSince($0.at) <= 90 * 86_400 })
        #expect(folded.count <= 7 * 24 + 86, "about 6 KB a tile at most")
        let sent = DashboardStore.downsampled(folded, since: now.addingTimeInterval(-30 * 86_400), limit: 120)
        #expect(sent.count == 120)
        #expect(sent.last == folded.last)
    }

    @Test func aRunOfEqualValuesIsKeptAsItsFirstPoint() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let points = [3.0, 3, 4, 4, 4, 3].enumerated().map {  // index-ok: six, from a literal
            TilePoint(at: now.addingTimeInterval(Double($0.offset - 6) * 3600), value: $0.element)
        }
        #expect(DashboardStore.compacted(points, now: now).map(\.value) == [3, 4, 3])
        #expect(DashboardStore.compacted(points, now: now).first?.at == points[0].at)
    }

    // MARK: History in the project (#127)

    private func history(_ s: Setup, _ id: String) -> URL {
        s.project.appendingPathComponent(".agents/dashboard/history/\(id).jsonl")
    }

    @Test func theDashboardSaysItsTilesAreProjectFiles() {
        // The web page's test pins the same words.
        #expect(DashboardModel.filesSentence
                == "Tiles and their trends are files in .agents/dashboard/ in this project, which you may commit")
        #expect(DashboardModel.historyFile("open_bugs") == ".agents/dashboard/history/open_bugs.jsonl")
    }

    @Test func pointsAreKeptInTheProjectAndAnotherHostReadsThem() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 6))
        s.clock.advance(minutes: 60)
        _ = try await set(s, "Lead", number("open_bugs", 4))
        let lines = try String(contentsOf: history(s, "open_bugs"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let t = Int(s.clock.now.timeIntervalSince1970)
        #expect(lines.map(String.init) == [#"{"t":\#(t - 3600),"v":6}"#, #"{"t":\#(t),"v":4}"#],
                "the same points are always the same bytes")
        #expect(!FileManager.default.fileExists(
            atPath: s.locations.root.appendingPathComponent("dashboards/\(DashboardStore.key(s.project))/points").path),
            "nothing about the trend is kept on the host")

        // A clone's host: a new root, the same project files.
        let other = StoreLocations(root: s.locations.root.deletingLastPathComponent().appendingPathComponent("other"))
        try other.createDirectories()
        let there = DaemonCore(store: try AgentStore(locations: other), locations: other,
                               discovery: .findsEverything, launcher: FakeLauncher(), now: { s.clock.now })
        await there.loadFromDisk()
        #expect(await there.dashboardSnapshot(s.project).tiles.first?.points.map(\.value) == [6, 4])
    }

    @Test func theSameValueOrTheSameHourWritesNothingNew() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 6))
        let first = try Data(contentsOf: history(s, "open_bugs"))
        let stamp = try FileManager.default.attributesOfItem(atPath: history(s, "open_bugs").path)[.modificationDate] as? Date

        s.clock.advance(minutes: 90)
        try await Task.sleep(for: .milliseconds(20))
        let same = try await set(s, "Lead", number("open_bugs", 6))
        #expect(same.contains("no point was added"))
        let again = try FileManager.default.attributesOfItem(atPath: history(s, "open_bugs").path)[.modificationDate] as? Date
        #expect(stamp == again, "a value the trend already ends at is not a write")

        // Two sets in one hour leave one point, the later.
        s.clock.advance(minutes: 60)
        _ = try await set(s, "Lead", number("open_bugs", 5))
        s.clock.advance(minutes: 10)
        _ = try await set(s, "Lead", number("open_bugs", 7))
        let tiles = await s.core.dashboardSnapshot(s.project).tiles
        try #require(tiles.count == 1)
        let points = tiles[0].points.map(\.value)
        #expect(points == [6, 7])
        #expect(try Data(contentsOf: history(s, "open_bugs")) != first)
    }

    @Test func pointsThisHostKeptBeforeAreMovedIntoTheProjectOnce() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        let legacy = s.locations.root.appendingPathComponent("dashboards/\(DashboardStore.key(s.project))/points/open_bugs.jsonl")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let t = s.clock.now.timeIntervalSince1970
        try Data("{\"t\":\(t - 7200),\"v\":9}\n{\"t\":\(t - 7100),\"v\":8}\n{\"t\":\(t - 3600),\"v\":7}\n".utf8)
            .write(to: legacy)
        _ = try await set(s, "Lead", number("open_bugs", 6))

        #expect(await s.core.dashboardSnapshot(s.project).tiles[0].points.map(\.value) == [8, 7, 6],
                "folded by the project's policy: that hour's last")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: history(s, "open_bugs"), encoding: .utf8).split(separator: "\n").count == 3)
    }

    @Test func aPulledHistoryIsReadAgain() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", number("open_bugs", 6))
        _ = await s.core.dashboardSnapshot(s.project)
        let t = s.clock.now.timeIntervalSince1970
        try Data("{\"t\":\(t - 3600),\"v\":2}\n{\"t\":\(t),\"v\":6}\n".utf8).write(to: history(s, "open_bugs"))
        await s.core.dashboardFilesChanged([history(s, "open_bugs")], in: s.project)
        #expect(await s.core.dashboardSnapshot(s.project).tiles[0].points.map(\.value) == [2, 6])
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

    // MARK: Order (#147)

    private func status(_ id: String, section: String? = nil) -> JSONValue {
        var arguments: [String: JSONValue] = ["id": .string(id), "title": .string(id), "type": "status",
                                              "level": "ok", "line": "fine"]
        if let section { arguments["section"] = .string(section) }
        return .object(arguments)
    }

    private func shown(_ s: Setup) async -> [String] {
        await DashboardModel.sections(s.core.dashboardSnapshot(s.project), includeHidden: true)
            .map { "\($0.title ?? "-"): " + $0.tiles.map(\.id).joined(separator: " ") }
    }

    private func move(_ s: Setup, _ who: String, _ arguments: JSONValue) async throws -> String {
        try await s.core.moveTile(DaemonAPI.MoveTileRequest(token: s.tokens[who]!, arguments: arguments))
    }

    @Test func aPersonsArrangeIsKeptInTheProjectAndSurvivesAReset() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        for id in ["a", "b", "c"] { _ = try await set(s, "Lead", status(id)) }
        _ = try await set(s, "Lead", status("d", section: "Ship"))
        #expect(await shown(s) == ["-: a b c", "Ship: d"])

        try await s.core.arrangeDashboard(.init(folder: s.project, order: DashboardOrder(sections: [
            .init(title: "Ship", tiles: ["d", "c"]), .init(title: nil, tiles: ["b", "a", "gone"]),
        ])))
        #expect(await shown(s) == ["Ship: d c", "-: b a"])
        let order = try JSONDecoder().decode(DashboardOrder.self, from: Data(contentsOf:
            s.project.appendingPathComponent(".agents/dashboard/_order.json")))
        #expect(order.tiles == ["d", "c", "b", "a"])

        // Setting a value again keeps a tile where it was put, and a new one goes last in
        // its own section; the order file is never read as a tile.
        _ = try await set(s, "Lead", status("c"))
        _ = try await set(s, "Lead", status("e"))
        #expect(await shown(s) == ["Ship: d c", "-: b a e"])
        #expect(await s.core.dashboardSnapshot(s.project).tiles.count == 5)

        // A new host (a relaunch) reads the same order from the project.
        let again = DaemonCore(store: try AgentStore(locations: s.locations), locations: s.locations,
                               discovery: .findsEverything, launcher: FakeLauncher(), now: { s.clock.now })
        await again.loadFromDisk()
        #expect(await DashboardModel.sections(again.dashboardSnapshot(s.project), includeHidden: true)
            .map(\.title) == ["Ship", nil])
    }

    @Test func changingASectionMovesATileAndRemovingOneTakesItOut() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        for id in ["a", "b"] { _ = try await set(s, "Lead", status(id)) }
        _ = try await set(s, "Lead", status("c", section: "Ship"))
        try await s.core.arrangeDashboard(.init(folder: s.project, order: DashboardOrder(sections: [
            .init(title: nil, tiles: ["b", "a"]), .init(title: "Ship", tiles: ["c"]),
        ])))
        _ = try await set(s, "Lead", status("b", section: "Ship"))
        #expect(await shown(s) == ["-: a", "Ship: c b"])
        _ = try await s.core.removeTile(.init(token: s.tokens["Lead"]!, id: "c"))
        #expect(await s.core.dashboardSnapshot(s.project).order?.tiles == ["a"])
    }

    @Test func anyAgentMovesATileAndReadDashboardShowsTheOrder() async throws {
        let s = try await setUp([("Lead", false, nil, .finished), ("Helper", false, nil, .finished)])
        for id in ["a", "b", "c"] { _ = try await set(s, "Lead", status(id)) }
        let answer = try await move(s, "Helper", ["id": "c", "position": "first"])
        #expect(answer.contains("Moved \"c\""))
        #expect(await shown(s) == ["-: c a b"])
        _ = try await move(s, "Helper", ["id": "c", "after": "a"])
        #expect(await shown(s) == ["-: a c b"])
        _ = try await move(s, "Helper", ["id": "b", "before": "a"])
        #expect(await shown(s) == ["-: b a c"])
        _ = try await move(s, "Helper", ["id": "a", "section": "Later"])
        #expect(await shown(s) == ["-: b c", "Later: a"])
        _ = try await move(s, "Helper", ["id": "a", "section": ""])
        #expect(await shown(s) == ["-: b c a"])
        let read = try await s.core.readDashboard(.init(token: s.tokens["Helper"]!))
        #expect(read.contains("1. b — b"))
        #expect(read.contains("3. a — a"))
    }

    @Test func aMoveIsRefusedInWords() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", status("a"))
        for (arguments, words) in [
            (["id": "zz", "position": "first"] as JSONValue, "no tile \"zz\""),
            (["id": "a"], "say where"),
            (["id": "a", "before": "a"], "next to itself"),
            (["id": "a", "position": "middle"], "first or last"),
            (["id": "a", "before": "a", "position": "first"], "not more"),
        ] {
            await #expect {
                _ = try await move(s, "Lead", arguments)
            } throws: { error in
                (error as? JSONRPCError)?.message.contains(words) == true
            }
        }
    }

    // MARK: #171

    private func asides(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? [])
            .filter { $0.hasPrefix(url.lastPathComponent + ".corrupt-") }
    }

    /// Copies of a project's file are kept under the daemon's root, never in the project (#205).
    private func outsideAsides(_ url: URL, _ s: Setup) async -> [URL] {
        StoreCoding.asides(of: url, in: StoreCoding.asideFolder(for: url, under: await s.core.locations.root))
    }

    @Test func anUnreadableOrderIsKeptNotWrittenOver() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        for id in ["a", "b"] { _ = try await set(s, "Lead", status(id)) }
        let orderFile = s.project.appendingPathComponent(".agents/dashboard/_order.json")
        let conflicted = Data("<<<<<<< HEAD\n{\"sections\":[]}\n=======\n>>>>>>> theirs\n".utf8)
        try conflicted.write(to: orderFile)

        let snapshot = await s.core.dashboardSnapshot(s.project)
        #expect(snapshot.order == nil, "the tiles show in the order they were made")
        #expect(snapshot.tiles.count == 2, "the Dashboard keeps working")
        #expect(snapshot.note?.contains("_order.json could not be read") == true, "the page says so")
        #expect(asides(orderFile).isEmpty, "nothing set aside in the project, mid-merge")
        let kept = await outsideAsides(orderFile, s)
        try #require(kept.count == 1)
        #expect(try Data(contentsOf: kept[0]) == conflicted)

        // No arrange writes over it while it does not read (#205)…
        let arrange = DaemonAPI.ArrangeRequest(folder: s.project, order: DashboardOrder(sections: [
            .init(title: nil, tiles: ["b", "a"]),
        ]))
        await #expect(throws: (any Error).self) { try await s.core.arrangeDashboard(arrange) }
        #expect(try Data(contentsOf: orderFile) == conflicted)

        // …and once the person resolves it, the next arrange writes a whole, readable file.
        try Data(#"{"sections":[]}"#.utf8).write(to: orderFile)
        try await s.core.arrangeDashboard(arrange)
        #expect(try JSONDecoder().decode(DashboardOrder.self, from: Data(contentsOf: orderFile)).tiles == ["b", "a"])
        #expect(await outsideAsides(orderFile, s).count == 1)
        #expect(Self.temporaries(in: orderFile.deletingLastPathComponent()).isEmpty)
    }

    @Test func aHistoryLineThatDoesNotReadIsKeptInACopy() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        _ = try await set(s, "Lead", number("bugs", 4))
        let history = s.project.appendingPathComponent(".agents/dashboard/history/bugs.jsonl")
        var data = try Data(contentsOf: history)
        data.append(Data("not a point\n{\"t\":1800000060,\"v\":5}\n".utf8))
        try data.write(to: history)
        await s.core.dashboardFilesChanged([history], in: s.project)

        let tile = try #require(await s.core.dashboardSnapshot(s.project).tiles.first)
        #expect(tile.recent.map(\.value) == [4, 5], "the lines that read are kept")
        #expect(asides(history).isEmpty, "never copied into the project (#205)")
        #expect(await outsideAsides(history, s).count == 1, "the whole file is kept before a write drops the bad line")
        #expect(await s.core.dashboardSnapshot(s.project).note?.contains("bugs.jsonl") == true)
    }

    @Test func anUnreadableHostStateIsSetAside() async throws {
        let s = try await setUp([("Lead", false, nil, .finished)])
        let state = s.locations.root.appendingPathComponent("dashboards/\(DashboardStore.key(s.project))/state.json")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"folder\":".utf8).write(to: state)
        let answer = try await set(s, "Lead", status("a"))
        #expect(answer.contains("Set \"a\""))
        #expect(asides(state).count == 1)
        #expect(try StoreCoding.decoder.decode(DashboardState.self, from: Data(contentsOf: state)).tiles["a"] != nil)
    }

    static func temporaries(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".tmp") }
    }

    @Test func tileIDsMayNotStartWithAnUnderscore() {
        #expect(!TileLimits.isValidID("_order"))
        #expect(TileLimits.isValidID("open_bugs"))
        #expect(TileLimits.isValidID("x_"))
    }

    @Test func theOrderMovesTilesAndSections() {
        let order = DashboardOrder(sections: [.init(title: nil, tiles: ["a", "b"]), .init(title: "S", tiles: ["c"])])
        #expect(order.moving(["a"], to: "S", before: "c").sections
            == [.init(title: nil, tiles: ["b"]), .init(title: "S", tiles: ["a", "c"])])
        #expect(order.moving(["b"], to: "S").moving(["a"], to: "S").sections == [.init(title: "S", tiles: ["c", "b", "a"])])
        #expect(order.moving(["a"], after: "b").tiles == ["b", "a", "c"])
        #expect(order.movingSection("S", before: .some(nil)).sections.map(\.title) == ["S", nil])
        #expect(order.movingSection(nil, before: nil).sections.map(\.title) == ["S", nil])
        let messy = DashboardOrder(sections: [.init(title: "", tiles: ["a", "a"]), .init(title: nil, tiles: ["b", "x"]),
                                              .init(title: "E", tiles: [])])
        #expect(messy.cleaned(known: ["a", "b"]).sections == [.init(title: nil, tiles: ["a", "b"])])
    }
}

private extension TileFile {
    var description: String { (try? String(data: fileData(), encoding: .utf8)) ?? "" }
}
