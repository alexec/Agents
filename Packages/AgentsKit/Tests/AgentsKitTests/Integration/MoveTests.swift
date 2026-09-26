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
                           prompt: String = "Fix the login redirect") async throws -> UUID {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder ?? repo.project,
                                                             prompt: prompt))
        await settled(core, id)
        return id
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
}
