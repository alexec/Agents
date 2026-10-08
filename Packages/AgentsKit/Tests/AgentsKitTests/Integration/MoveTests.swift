import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Moving an agent into a worktree, or back to its project folder, during its life (053).
///
/// Real git in a repository made for each test, and a fake runtime. What this suite holds:
/// a move is made between turns and never during one; the next runtime starts in the new
/// folder and is asked to continue its session there; nothing uncommitted is carried,
/// changed or lost; and an agent that moved itself is started again to carry on.
@Suite("Moving agents", .timeLimit(.minutes(1)))
struct MoveTests {
    // MARK: A repository to work in

    private struct Repo {
        let locations: StoreLocations
        let project: URL
        let top: URL
    }

    private func git(_ arguments: [String], in folder: URL) async throws -> String {
        let outcome = try await GitProcess(arguments, in: folder).run()
        guard outcome.succeeded else {
            throw GitWorktrees.Failure(message: "git \(arguments.joined(separator: " ")): \(outcome.errors)")
        }
        return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repository(committed: Bool = true, subfolder: String? = nil) async throws -> Repo {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsMoves-\(UUID().uuidString)", isDirectory: true)
        let top = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        _ = try await git(["init", "-q", "-b", "main"], in: top)
        _ = try await git(["config", "user.email", "test@example.com"], in: top)
        _ = try await git(["config", "user.name", "Test"], in: top)
        if let subfolder {
            try FileManager.default.createDirectory(at: top.appending(path: subfolder),
                                                    withIntermediateDirectories: true)
            try "x".write(to: top.appending(path: "\(subfolder)/file.txt"), atomically: true, encoding: .utf8)
        }
        try "hello\n".write(to: top.appending(path: "README"), atomically: true, encoding: .utf8)
        if committed {
            _ = try await git(["add", "."], in: top)
            _ = try await git(["commit", "-q", "-m", "first"], in: top)
        }
        let standardTop = Project.standardize(top)
        let project = subfolder.map { Project.standardize(standardTop.appending(path: $0)) } ?? standardTop
        return Repo(locations: StoreLocations(root: root.appending(path: "store")), project: project, top: standardTop)
    }

    private func makeCore(_ repo: Repo, _ launcher: FakeLauncher) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: repo.locations), locations: repo.locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        return core
    }

    /// An agent in the project folder, its first turn over.
    private func idleAgent(_ core: DaemonCore, _ repo: Repo, in folder: URL? = nil,
                           prompt: String = "Fix the login redirect", runtime: String = "claude") async throws -> UUID {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: runtime, cwd: folder ?? repo.project,
                                                             prompt: prompt))
        await settled(core, id)
        await quiet(core, id)
        return id
    }

    /// No runtime, no turn and nothing being sent, several looks in a row. `settled` is
    /// true as soon as the app has *asked* how a silent turn went, and that question is
    /// a turn of its own: a move made in it waits for it, which is not what a test of an
    /// idle agent means.
    private func quiet(_ core: DaemonCore, _ id: UUID,
                       sourceLocation: SourceLocation = #_sourceLocation) async {
        var calm = 0
        let deadline = ContinuousClock.now.advanced(by: Eventually.timeout)
        while calm < 5 {
            guard ContinuousClock.now < deadline else {
                Issue.record("the agent never went quiet", sourceLocation: sourceLocation)
                return
            }
            let noRuntime = await core.live[id] == nil
            let noTurn = await core.turnTasks[id] == nil
            let notSending = await !core.sending.contains(id)
            let settledState = await core.agent(id)?.state.hasTurnInFlight == false
            calm = (noRuntime && noTurn && notSending && settledState) ? calm + 1 : 0
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func personMove(_ core: DaemonCore, _ id: UUID, _ target: MoveTarget?,
                            removeLeft: Bool = false, discard: Bool = false) async throws -> DaemonAPI.MoveAnswer {
        try await core.move(DaemonAPI.MoveRequest(agentID: id, target: target, removeLeft: removeLeft,
                                                  discardChanges: discard))
    }

    private func failure(_ body: () async throws -> some Any) async -> JSONRPCError? {
        do { _ = try await body(); return nil } catch let error as JSONRPCError { return error } catch { return nil }
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
            if case .runtimeNote(let text) = $0.kind { return text }
            return nil
        }
    }

    private func appPrompts(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
            if case .userMessage(let text, _, let from) = $0.kind, from == .app { return text }
            return nil
        }
    }

    /// The app's tools as each runtime listed them over the app's server (#185), by name,
    /// across every session made or picked up.
    private func listedTools(_ launcher: FakeLauncher) async -> [[String]] {
        var all: [[String]] = []
        for runtime in launcher.allAgents {
            for tools in [await runtime.newSessionAppToolList, await runtime.continuedSessionAppToolList] {
                guard let tools else { continue }
                all.append(tools.compactMap { $0["name"]?.stringValue })
            }
        }
        return all
    }

    private func worktreesMade(_ repo: Repo) -> [String] {
        let folder = repo.top.appending(path: WorktreeName.folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func addByHand(_ repo: Repo, _ name: String) async throws -> URL {
        let path = repo.top.deletingLastPathComponent().appending(path: name)
        _ = try await git(["worktree", "add", "-q", "-b", name, path.path, "HEAD"], in: repo.top)
        return Project.standardize(path)
    }

    // MARK: Applying a move (Phase 2)

    @Test func anIdleAgentMovesIntoANewWorktreeAtOnce() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        let title = await core.agent(id)?.title ?? ""
        let expectedName = WorktreeName.from(prompt: title)
        // What an agent's start already laid out in the project folder (dotagents) is not
        // the move's doing: the move must leave the folder exactly as it found it.
        let before = try await git(["status", "--porcelain"], in: repo.top)

        let answer = try await personMove(core, id, .newWorktree(name: nil))

        #expect(answer.when == .now)
        let agent = try #require(await core.agent(id))
        let worktree = try #require(agent.worktree)
        #expect(worktree.name == expectedName)
        #expect(worktree.branch == "agents/\(expectedName)")
        #expect(worktree.madeByApp)
        #expect(worktree.project == repo.project)
        #expect(worktree.base == "main")
        #expect(agent.cwd.path == repo.top.appending(path: ".agents/worktrees/\(expectedName)").path)
        #expect(agent.projectFolder == repo.project)
        #expect(agent.pendingMove == nil)
        #expect(try await git(["status", "--porcelain"], in: repo.top) == before)
        #expect(try await notes(core, id).contains { $0.hasPrefix("Moved from the project folder to worktree \(expectedName) on agents/\(expectedName), from main.") })
    }

    @Test func theNextTurnStartsInTheNewFolderAndContinuesItsSession() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "elsewhere"))
        let cwd = try #require(await core.agent(id)?.cwd)

        try await core.prompt(.init(agentID: id, text: "carry on"))
        await settled(core, id)

        #expect(launcher.launches.last.map { Project.standardize($0.cwd).path } == cwd.path)
        let asked = try #require(await launcher.lastAgent?.continuedSessionParams?["cwd"]?.stringValue)
        #expect(Project.standardize(URL(filePath: asked)).path == cwd.path)
        // Told where it is now, once, with the prompt that followed the move. The app's
        // own question about the silent turn may come after it, in a runtime of its own.
        var told = false
        for runtime in launcher.allAgents {
            let content = await runtime.promptContent.map { "\($0)" } ?? ""
            if content.contains("carry on") { told = content.contains("You have moved: you now work in \(cwd.path)") }
        }
        #expect(told)
    }

    @Test func aWorktreeMadeFromAWorktreeCarriesItsCommitsAndIsNotNested() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "first"))
        let first = try #require(await core.agent(id)?.cwd)
        try "work\n".write(to: first.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], in: first)
        _ = try await git(["commit", "-q", "-m", "work"], in: first)

        _ = try await personMove(core, id, .newWorktree(name: "second"))

        let agent = try #require(await core.agent(id))
        #expect(agent.cwd.path == repo.top.appending(path: ".agents/worktrees/second").path)
        #expect(FileManager.default.fileExists(atPath: agent.cwd.appending(path: "work.txt").path))
        #expect(agent.worktree?.base == "agents/first")
        #expect(worktreesMade(repo) == ["first", "second"])
    }

    @Test func aProjectInASubfolderLandsInTheSameSubfolder() async throws {
        let repo = try await repository(subfolder: "app")
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "tidy"))
        let agent = try #require(await core.agent(id))
        #expect(agent.cwd.path == repo.top.appending(path: ".agents/worktrees/tidy/app").path)
        #expect(agent.projectFolder == repo.project)
    }

    @Test func uncommittedChangesStayBehindUntouched() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        try "half done\n".write(to: repo.top.appending(path: "draft.txt"), atomically: true, encoding: .utf8)
        let uncommitted = try await git(["status", "--porcelain"], in: repo.top).split(separator: "\n").count

        _ = try await personMove(core, id, .newWorktree(name: "clean"))

        let cwd = try #require(await core.agent(id)?.cwd)
        #expect(try String(contentsOf: repo.top.appending(path: "draft.txt"), encoding: .utf8) == "half done\n")
        #expect(!FileManager.default.fileExists(atPath: cwd.appending(path: "draft.txt").path))
        #expect(try await notes(core, id).contains {
            $0.contains("\(uncommitted) uncommitted \(uncommitted == 1 ? "change" : "changes") stayed in the project folder.")
        })
    }

    @Test func anExistingWorktreeIsMovedIntoAndNothingIsMade() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        let byHand = try await addByHand(repo, "by-hand")

        _ = try await personMove(core, id, .existing(byHand))

        let agent = try #require(await core.agent(id))
        #expect(agent.cwd.path == byHand.path)
        #expect(agent.worktree?.madeByApp == false)
        #expect(worktreesMade(repo).isEmpty)
    }

    @Test func anAgentMovesBackToTheProjectFolder() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "away"))

        let answer = try await personMove(core, id, .projectFolder)

        #expect(answer.when == .now)
        let agent = try #require(await core.agent(id))
        #expect(agent.cwd == repo.project)
        #expect(agent.worktree == nil)
        #expect(worktreesMade(repo) == ["away"], "kept: only remove takes it away")
    }

    @Test func aGivenNameIsCleanedAndATakenOneNumbered() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let first = try await idleAgent(core, repo)
        let second = try await idleAgent(core, repo, prompt: "Something else")

        _ = try await personMove(core, first, .newWorktree(name: "Fix Login"))
        _ = try await personMove(core, second, .newWorktree(name: "Fix Login"))

        #expect(await core.agent(first)?.worktree?.name == "fix-login")
        #expect(await core.agent(second)?.worktree?.name == "fix-login-2")
    }

    @Test func withNoCommitNothingIsStoredAndTheAgentStays() async throws {
        let repo = try await repository(committed: false)
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)

        let error = await failure { try await personMove(core, id, .newWorktree(name: nil)) }

        #expect(error?.code == DaemonAPI.Failure.worktreeFailed)
        #expect(error?.message.contains("no commit") == true)
        let agent = try #require(await core.agent(id))
        #expect(agent.cwd == repo.project)
        #expect(agent.pendingMove == nil)
    }

    @Test func aMoveThatFailsWhenMadeLeavesTheAgentWhereItWas() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        // Checked when asked, gone by the time it is made.
        let byHand = try await addByHand(repo, "fleeting")
        var agent = try #require(await core.agent(id))
        agent.pendingMove = PendingMove(target: .existing(byHand), askedBy: .person, askedAt: Date())
        await core.changed(agent)
        try FileManager.default.removeItem(at: byHand)

        #expect(await core.applyPendingMove(id) == nil)

        let after = try #require(await core.agent(id))
        #expect(after.cwd == repo.project)
        #expect(after.pendingMove == nil)
        #expect(try await notes(core, id).contains { $0.hasPrefix("Could not move:") && $0.hasSuffix("Still in the project folder.") })
    }

    // MARK: The agent asks (US1)

    /// An agent in the middle of a turn, held there until the test opens the gate, and
    /// the token its tools speak with.
    private func busyAgent(_ core: DaemonCore, _ repo: Repo, _ gate: TurnGate,
                           _ launcher: FakeLauncher) async throws -> (id: UUID, token: String) {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: repo.project,
                                                             prompt: "Fix the login redirect"))
        await eventually("the turn is under way") { gate.turnsArrived >= 1 }
        let token = try #require(await eventuallySome("its tools have a token") {
            await core.appTokens.first { $0.value == id }?.key
        })
        return (id, token)
    }

    private func gatedLauncher() -> (FakeLauncher, TurnGate) {
        let gate = TurnGate()
        var script = FakeACPAgent.Script()
        script.gate = gate
        return (FakeLauncher(script: script), gate)
    }

    @Test func aMoveAskedMidTurnWaitsForTheTurnAndThenCarriesOn() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        let answer = try await core.moveSelf(.init(token: token, target: .newWorktree(name: "own-branch")))

        #expect(answer.when == .afterTurn)
        #expect(answer.message.contains("when this turn ends"))
        #expect(answer.message.contains("own-branch"))
        #expect(await core.agent(id)?.pendingMove?.askedBy == .agent)
        #expect(await core.agent(id)?.cwd == repo.project, "nothing moves while the turn runs")

        gate.open()
        let moved = repo.top.appending(path: ".agents/worktrees/own-branch").path
        await eventually("moved when the turn ended") { await core.agent(id)?.cwd.path == moved }
        await eventually("started again to carry on") {
            (try? await appPrompts(core, id).contains(DaemonCore.carryOn)) == true
        }
        await eventually("in the worktree") {
            launcher.launches.last.map { Project.standardize($0.cwd).path } == moved
        }
        #expect(try await notes(core, id).contains { $0.hasPrefix("Will move to a new worktree like own-branch when this turn ends") })
    }

    /// The name the answer gives is the name made, even when the agent retitles itself
    /// later in the same turn.
    @Test func theNameIsSettledWhenTheMoveIsAsked() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)
        let title = try #require(await core.agent(id)?.title)
        let expected = WorktreeName.from(prompt: title)

        let answer = try await core.moveSelf(.init(token: token, target: .newWorktree(name: nil)))
        #expect(answer.message.contains(expected))
        var agent = try #require(await core.agent(id))
        agent.title = "Something else entirely"
        await core.changed(agent)
        gate.open()

        await eventually("moved") { await core.agent(id)?.worktree != nil }
        #expect(await core.agent(id)?.worktree?.name == expected)
    }

    @Test func theLastOfTwoAsksIsTheOneMade() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        _ = try await core.moveSelf(.init(token: token, target: .newWorktree(name: "one")))
        _ = try await core.moveSelf(.init(token: token, target: .newWorktree(name: "two")))
        gate.open()

        await eventually("moved") { await core.agent(id)?.worktree?.name == "two" }
        #expect(worktreesMade(repo) == ["two"])
    }

    // MARK: Asked on finish_turn

    private func finish(_ core: DaemonCore, _ token: String, _ outcome: String = "partly_done",
                        afterwards: String? = nil, move: DaemonAPI.MoveAsk?) async throws -> String {
        try await core.finishTurn(.init(token: token, outcome: outcome, message: "Moving on to its own branch.",
                                        prompts: [], afterwards: afterwards, move: move))
    }

    @Test func aMoveOnFinishTurnLandsTheReportAndMovesWhenTheTurnEnds() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        let answer = try await finish(core, token, move: .init(target: .newWorktree(name: "from-finish")))

        #expect(answer.contains("when this turn ends"))
        #expect(await core.agent(id)?.report?.outcome == .partlyDone)
        #expect(await core.agent(id)?.pendingMove?.askedBy == .agent)
        #expect(await core.agent(id)?.cwd == repo.project, "nothing moves while the turn runs")

        gate.open()
        let moved = repo.top.appending(path: ".agents/worktrees/from-finish").path
        await eventually("moved when the turn ended") { await core.agent(id)?.cwd.path == moved }
        await eventually("started again to carry on") {
            (try? await appPrompts(core, id).contains(DaemonCore.carryOn)) == true
        }
    }

    /// A move carries the agent on, so it does not go with an ending that waits or archives it.
    @Test func aMoveWithAnEndingThatWaitsIsRefusedWhole() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)
        let move = DaemonAPI.MoveAsk(target: .newWorktree(name: "nope"))

        for (outcome, afterwards) in [("needs_answer", nil), ("done", "archive")] as [(String, String?)] {
            await #expect(throws: JSONRPCError.self) {
                _ = try await finish(core, token, outcome, afterwards: afterwards, move: move)
            }
        }
        #expect(await core.agent(id)?.report == nil)
        #expect(await core.agent(id)?.pendingMove == nil)
        gate.open()
    }

    // MARK: Moving with the other turn-end tools (#481)

    /// Parked and moved in one turn: it moves, and stays parked there rather than being
    /// started again. On the old `finish_turn`, which refused the pair, as on the new tools.
    @Test(arguments: [false, true])
    func aParkAndAMoveTogetherMoveAndStayParked(_ onFinishTurn: Bool) async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        if onFinishTurn {
            let answer = try await finish(core, token, "done", afterwards: "park",
                                          move: .init(target: .newWorktree(name: "parked-there")))
            #expect(answer.contains("will be parked"))
        } else {
            let moving = try await core.moveSelf(.init(token: token, target: .newWorktree(name: "parked-there")))
            #expect(moving.when == .afterTurn)
            let parking = try await core.askAfterTurn(.init(token: token, afterwards: "park"))
            #expect(parking.contains("stay parked there"))
        }

        gate.open()
        let moved = repo.top.appending(path: ".agents/worktrees/parked-there").path
        await eventually("moved when the turn ended") { await core.agent(id)?.cwd.path == moved }
        await eventually("parked") { await core.agent(id)?.parking?.isParked == true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await !appPrompts(core, id).contains(DaemonCore.carryOn), "not started again")
    }

    /// A move asked first refuses the wait, and a wait first refuses the move, each saying why.
    @Test func aMoveAndAWaitDoNotGoTogether() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        _ = try await core.moveSelf(.init(token: token, target: .newWorktree(name: "then-wait")))
        let waitRefused = await failure { try await core.waitOn(.init(token: token, untilMinutes: 5)) }
        #expect(waitRefused?.message.contains("move_worktree with neither argument") == true)

        let stayed = try await core.moveSelf(.init(token: token, target: nil))
        #expect(stayed.message.hasPrefix("Move cancelled"))
        #expect(await core.agent(id)?.pendingMove == nil)

        _ = try await core.waitOn(.init(token: token, untilMinutes: 5))
        let moveRefused = await failure {
            try await core.moveSelf(.init(token: token, target: .newWorktree(name: "after-wait")))
        }
        #expect(moveRefused?.message.contains("this turn ended blocked") == true)
        #expect(await core.agent(id)?.pendingMove == nil)
        gate.open()
    }

    /// A move the daemon cannot make refuses the call, so the agent hears why while it can still act.
    @Test func aMoveThatIsRefusedRecordsNothing() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        await #expect(throws: JSONRPCError.self) {
            _ = try await finish(core, token, move: .init(target: .existing(URL(filePath: "/tmp/not-a-worktree"))))
        }
        #expect(await core.agent(id)?.report == nil)
        #expect(await core.agent(id)?.pendingMove == nil)
        gate.open()
    }

    /// The last call is the whole account of the turn: one without a move takes back the agent's.
    @Test func aLaterFinishTurnWithoutAMoveTakesItBack() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        _ = try await finish(core, token, move: .init(target: .newWorktree(name: "second-thoughts")))
        _ = try await finish(core, token, "done", move: nil)

        #expect(await core.agent(id)?.pendingMove == nil)
        #expect(await core.agent(id)?.report?.outcome == .done)
        gate.open()
        await eventually("the turn ended") { await core.agent(id)?.state.hasTurnInFlight == false }
        #expect(worktreesMade(repo).isEmpty)
        #expect(await core.agent(id)?.cwd == repo.project)
    }

    @Test func aStoppedTurnStillMovesButDoesNotCarryOn() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        _ = try await core.moveSelf(.init(token: token, target: .newWorktree(name: "stopped")))
        try await core.stop(id)
        gate.open()

        await eventually("moved anyway") { await core.agent(id)?.worktree?.name == "stopped" }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await appPrompts(core, id).contains(DaemonCore.carryOn) == false)
    }

    @Test func wordsThePersonQueuedGoFirstWithTheMoveOnThem() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)

        _ = try await core.moveSelf(.init(token: token, target: .newWorktree(name: "queued")))
        try await core.prompt(.init(agentID: id, text: "and also this"))
        gate.open()

        await eventually("the person's words went, in the worktree") {
            let content = await launcher.lastAgent?.promptContent.map { "\($0)" } ?? ""
            return content.contains("and also this") && content.contains("You have moved")
        }
        #expect(try await appPrompts(core, id).contains(DaemonCore.carryOn) == false)
    }

    @Test func refusalsAreSaidAndNothingIsStored() async throws {
        let repo = try await repository()
        let plain = repo.top.deletingLastPathComponent().appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let core = try await makeCore(repo, FakeLauncher())

        let outside = try await idleAgent(core, repo, in: plain)
        let notRepo = await failure { try await personMove(core, outside, .newWorktree(name: nil)) }
        #expect(notRepo?.code == DaemonAPI.Failure.worktreeFailed)
        #expect(notRepo?.message.contains("needs a git repository") == true)

        let inside = try await idleAgent(core, repo)
        let foreign = await failure { try await personMove(core, inside, .existing(plain)) }
        #expect(foreign?.code == DaemonAPI.Failure.notAWorktree)

        #expect(await core.agent(outside)?.pendingMove == nil)
        #expect(await core.agent(inside)?.pendingMove == nil)
        #expect(await core.agent(inside)?.cwd == repo.project)
    }

    @Test func leavingAWorktreeFromTheProjectFolderIsNothingToDo() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        let answer = try await personMove(core, id, .projectFolder)
        #expect(answer.when == .nothing)
        #expect(answer.message.contains("not in a worktree"))
    }

    // MARK: Everything that follows a folder (US2)

    @Test func aMovedAgentResumesInItsWorktreeAfterARestart() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "kept"))
        let cwd = try #require(await core.agent(id)?.cwd)
        await core.saveTail?.value

        let launcher = FakeLauncher()
        let again = try await makeCore(repo, launcher)
        _ = await again.recover()
        #expect(await again.agent(id)?.cwd == cwd)
        try await again.prompt(.init(agentID: id, text: "carry on"))
        await settled(again, id)

        #expect(launcher.launches.first.map { Project.standardize($0.cwd).path } == cwd.path)
        let asked = try #require(await launcher.allAgents.first?.continuedSessionParams?["cwd"]?.stringValue)
        #expect(Project.standardize(URL(filePath: asked)).path == cwd.path)
    }

    @Test func aMoveWaitingWhenTheDaemonWentIsMadeWhenItComesBack() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        var agent = try #require(await core.agent(id))
        agent.pendingMove = PendingMove(target: .newWorktree(name: "after-restart"), askedBy: .agent, askedAt: Date())
        await core.changed(agent)
        await core.saveTail?.value

        let again = try await makeCore(repo, FakeLauncher())
        _ = await again.recover()

        let moved = try #require(await again.agent(id))
        #expect(moved.worktree?.name == "after-restart")
        #expect(moved.pendingMove == nil)
    }

    @Test func archivingAMovedAgentCleansUpItsWorktreeAsIfItStartedThere() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "done-with"))
        let root = try #require(await core.agent(id)?.worktree?.root)

        try await core.archive(id)

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// The Changes pane follows: git's view is the new checkout, measured from the
    /// commit the agent started on, which a worktree made from its folder still has.
    @Test func itsChangesAreMeasuredInTheNewCheckout() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        // Taken beside the start, not in it: under load it can land after the agent is idle.
        let started = try #require(await eventuallySome("the starting point was taken") {
            await core.agent(id)?.startingPoint
        })
        _ = try await personMove(core, id, .newWorktree(name: "measured"))
        let agent = try #require(await core.agent(id))
        let root = try #require(agent.worktree?.root)

        #expect(agent.startingPoint?.repository.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        #expect(agent.startingPoint?.commit == started.commit)
        let (context, _) = await core.gitContext(for: agent)
        #expect(context?.rootPath == root.resolvingSymlinksInPath().path)
    }

    @Test func theProjectPageListsTheAgentInItsNewWorktree() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "listed"))

        let listed = await core.listWorktrees(for: repo.project)
        let here = try #require(listed.worktrees.first { $0.name == "listed" })
        #expect(here.agents == [id])
        #expect(here.madeByApp)
        #expect(listed.worktrees.first { $0.isProjectFolder }?.agents.contains(id) == false)
    }

    @Test func aMovedAgentWhoseWorktreeWasDeletedIsNotStartedAnywhereElse() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "deleted"))
        let root = try #require(await core.agent(id)?.worktree?.root)
        try FileManager.default.removeItem(at: root)
        let launchesBefore = launcher.launchCount

        let error = await failure { try await core.prompt(.init(agentID: id, text: "carry on")) }

        #expect(error?.code == DaemonAPI.Failure.folderGone)
        #expect(launcher.launchCount == launchesBefore)
    }

    @Test func aRuntimeThatCannotFindItsSessionInTheNewFolderCarriesOnInANewOne() async throws {
        let repo = try await repository()
        var forgetful = FakeACPAgent.Script()
        forgetful.sessionGoneError = JSONRPCError(code: -32603, message: "Path not found.")
        let launcher = FakeLauncher(script: forgetful)
        let core = try await makeCore(repo, launcher)
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "fresh"))
        let cwd = try #require(await core.agent(id)?.cwd)

        try await core.prompt(.init(agentID: id, text: "carry on"))
        await settled(core, id)

        #expect(try await notes(core, id).contains { $0.contains("no longer has this conversation") })
        var started = false
        for runtime in launcher.allAgents {
            if let asked = await runtime.newSessionParams?["cwd"]?.stringValue,
               Project.standardize(URL(filePath: asked)).path == cwd.path { started = true }
        }
        #expect(started, "the new session is in the new folder")
    }

    @Test func archivingWithAMoveWaitingTakesItBackAndMakesNothing() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, token) = try await busyAgent(core, repo, gate, launcher)
        _ = try await core.moveSelf(.init(token: token, target: .newWorktree(name: "never")))

        try await core.archive(id)
        gate.open()
        try await Task.sleep(for: .milliseconds(300))

        #expect(await core.agent(id)?.pendingMove == nil)
        #expect(await core.agent(id)?.cwd == repo.project)
        #expect(worktreesMade(repo).isEmpty)
    }

    // MARK: Leaving a worktree and removing it

    @Test func leavingWithRemoveTakesAwayACleanWorktreeAndItsMergedBranch() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "tidy"))
        let root = try #require(await core.agent(id)?.worktree?.root)

        let answer = try await personMove(core, id, .projectFolder, removeLeft: true)

        #expect(answer.when == .now)
        #expect(await core.agent(id)?.cwd == repo.project)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try await git(["branch", "--list", "agents/tidy"], in: repo.top).isEmpty, "nothing on it but main's commit")
        #expect(try await notes(core, id).contains { $0.contains("Removed the worktree tidy and its branch.") })
    }

    @Test func leavingWithRemoveTakesACleanWorktreeAndKeepsItsUnmergedBranch() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "worked"))
        let root = try #require(await core.agent(id)?.worktree?.root)
        try "work\n".write(to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], in: root)
        _ = try await git(["commit", "-q", "-m", "work"], in: root)
        let tip = try await git(["rev-parse", "HEAD"], in: root)

        // A lane's commits wait for a merge in a wave: that is no reason to keep the folder (#194).
        let answer = try await personMove(core, id, .projectFolder, removeLeft: true)

        #expect(answer.when == .now)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(await core.agent(id)?.cwd == repo.project)
        #expect(try await git(["rev-parse", "agents/worked"], in: repo.top) == tip, "the branch holds the commits")
        #expect(try await notes(core, id).contains { $0.contains("Removed the worktree worked; its branch agents/worked is kept.") })
    }

    @Test func removingOverUncommittedWorkNeedsDiscard() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        _ = try await personMove(core, id, .newWorktree(name: "dirty"))
        let root = try #require(await core.agent(id)?.worktree?.root)
        try "work\n".write(to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], in: root)
        _ = try await git(["commit", "-q", "-m", "work"], in: root)
        try "changed\n".write(to: root.appending(path: "work.txt"), atomically: true, encoding: .utf8)
        try "unsaved\n".write(to: root.appending(path: "unsaved.txt"), atomically: true, encoding: .utf8)

        let refused = await failure { try await personMove(core, id, .projectFolder, removeLeft: true) }
        #expect(refused?.code == DaemonAPI.Failure.worktreeFailed)
        let message = refused?.message ?? ""
        #expect(message.contains("2 uncommitted changes: edited work.txt, untracked unsaved.txt"), "\(message)")
        #expect(!message.contains("commits not in"), "commits are not what would be lost")
        #expect(await core.agent(id)?.pendingMove == nil)
        #expect(await core.agent(id)?.cwd == root, "nothing moved")

        _ = try await personMove(core, id, .projectFolder, removeLeft: true, discard: true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try await git(["branch", "--list", "agents/dirty"], in: repo.top).isEmpty == false,
                "discarding changes never discards commits")
    }

    @Test func removingAWorktreeWhoseCommitsWouldBeOnNoBranchIsRefused() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())

        let detached = try await idleAgent(core, repo)
        _ = try await personMove(core, detached, .newWorktree(name: "loose"))
        let looseRoot = try #require(await core.agent(detached)?.worktree?.root)
        _ = try await git(["checkout", "-q", "--detach"], in: looseRoot)
        let onHead = await failure { try await personMove(core, detached, .projectFolder, removeLeft: true, discard: true) }
        #expect(onHead?.code == DaemonAPI.Failure.worktreeFailed)
        #expect(onHead?.message.contains("detached HEAD") == true, "\(onHead?.message ?? "")")
        #expect(FileManager.default.fileExists(atPath: looseRoot.path))

        let orphan = try await idleAgent(core, repo, prompt: "Another")
        _ = try await personMove(core, orphan, .newWorktree(name: "gone"))
        let goneRoot = try #require(await core.agent(orphan)?.worktree?.root)
        _ = try await git(["update-ref", "-d", "refs/heads/agents/gone"], in: repo.top)
        let noBranch = await failure { try await personMove(core, orphan, .projectFolder, removeLeft: true, discard: true) }
        #expect(noBranch?.code == DaemonAPI.Failure.worktreeFailed)
        #expect(noBranch?.message.contains("agents/gone is not there any more") == true, "\(noBranch?.message ?? "")")
        #expect(FileManager.default.fileExists(atPath: goneRoot.path))
    }

    @Test func removingAWorktreeTheAppDidNotMakeOrAnotherAgentIsInIsRefused() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let first = try await idleAgent(core, repo)
        let byHand = try await addByHand(repo, "by-hand")
        _ = try await personMove(core, first, .existing(byHand))
        let foreign = await failure { try await personMove(core, first, .projectFolder, removeLeft: true) }
        #expect(foreign?.code == DaemonAPI.Failure.notAWorktree)

        _ = try await personMove(core, first, .newWorktree(name: "shared"))
        let root = try #require(await core.agent(first)?.worktree?.root)
        let second = try await idleAgent(core, repo, prompt: "Another")
        _ = try await personMove(core, second, .existing(root))
        let shared = await failure { try await personMove(core, first, .projectFolder, removeLeft: true) }
        #expect(shared?.code == DaemonAPI.Failure.worktreeInUse)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: The person moves an agent (US3)

    @Test func thePersonsMoveOfAnIdleAgentStartsNoTurn() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        let id = try await idleAgent(core, repo)
        let launchesBefore = launcher.launchCount

        _ = try await personMove(core, id, .newWorktree(name: "quiet"))
        try await Task.sleep(for: .milliseconds(300))

        #expect(launcher.launchCount == launchesBefore)
        #expect(try await appPrompts(core, id).contains(DaemonCore.carryOn) == false)
        #expect(await core.agent(id)?.state == .finished)
    }

    @Test func aWaitingMoveCanBeTakenBack() async throws {
        let repo = try await repository()
        let (launcher, gate) = gatedLauncher()
        let core = try await makeCore(repo, launcher)
        let (id, _) = try await busyAgent(core, repo, gate, launcher)

        let asked = try await personMove(core, id, .newWorktree(name: "second-thoughts"))
        #expect(asked.when == .afterTurn)
        #expect(await core.agent(id)?.pendingMove?.askedBy == .person)

        let cancelled = try await personMove(core, id, nil)
        #expect(cancelled.message == "Move cancelled.")
        #expect(await core.agent(id)?.pendingMove == nil)
        gate.open()
        await settled(core, id)
        #expect(await core.agent(id)?.cwd == repo.project)
        #expect(worktreesMade(repo).isEmpty)
    }

    @Test func anArchivedAgentIsNotMoved() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        try await core.archive(id)
        let error = await failure { try await personMove(core, id, .newWorktree(name: nil)) }
        #expect(error?.message.contains("archived") == true)
    }

    // MARK: Runtimes that would forget (053, Alex 2026-09-26)

    /// Grok files its sessions by folder and answers "Path not found" when asked for one
    /// from another, so it would carry on having forgotten everything: it is not moved,
    /// whoever asks, and is not offered the tools.
    @Test func anAgentOnARuntimeThatWouldForgetIsNotMoved() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        let id = try await idleAgent(core, repo, runtime: "grok")

        let error = await failure { try await personMove(core, id, .newWorktree(name: nil)) }

        #expect(error?.message.contains("can't carry its conversation into another folder") == true)
        #expect(await core.agent(id)?.cwd == repo.project)
        #expect(worktreesMade(repo).isEmpty)
        let listed = await listedTools(launcher)
        #expect(!listed.isEmpty && listed.allSatisfy { !$0.contains(AppTool.moveWorktree) })
    }

    @Test func anAgentOnARuntimeThatCarriesItsConversationIsOfferedTheTools() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        _ = try await idleAgent(core, repo, runtime: "claude")
        let listed = await listedTools(launcher)
        #expect(!listed.isEmpty && listed.allSatisfy { $0.contains(AppTool.moveWorktree) })
    }

    // MARK: The terminal (T037)

    /// A shell opened before the move goes on where it was: it is the person's, and may be
    /// running something. It says where it was started, so the pane can say the agent is
    /// somewhere else now.
    @Test func aShellOpenedBeforeTheMoveSaysWhereItWasStarted() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await idleAgent(core, repo)
        let before = try await core.attachShell(.init(agentID: id, rows: 24, cols: 80))
        #expect(before.folder.map { Project.standardize($0) } == repo.project)

        _ = try await personMove(core, id, .newWorktree(name: "shelled"))
        let after = try await core.attachShell(.init(agentID: id, rows: 24, cols: 80))

        #expect(after.folder.map { Project.standardize($0) } == repo.project, "the live shell was not moved")
        #expect(await core.agent(id)?.cwd != repo.project)
    }
}
