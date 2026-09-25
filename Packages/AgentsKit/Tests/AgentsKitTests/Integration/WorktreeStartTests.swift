import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Starting an agent in a worktree of its own (030).
///
/// Real git, in a real repository made for each test, and a fake runtime. What this
/// suite holds is that the worktree is made before any runtime and the runtime is
/// started inside it, that the agent stays filed under its project, that the project's
/// own checkout is left alone, and that a worktree that cannot be had starts nothing.
@Suite("Agents in worktrees", .timeLimit(.minutes(1)))
struct WorktreeStartTests {
    // MARK: A repository to work in

    private struct Repo {
        let locations: StoreLocations
        /// The project folder: the top of the repository, or a folder inside it.
        let project: URL
        /// The top of the repository.
        let top: URL
    }

    private func git(_ arguments: [String], in folder: URL) async throws -> String {
        let outcome = try await GitProcess(arguments, in: folder).run()
        guard outcome.succeeded else {
            throw GitWorktrees.Failure(message: "git \(arguments.joined(separator: " ")): \(outcome.errors)")
        }
        return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A repository with one commit on `main`, or none at all.
    private func repository(committed: Bool = true, subfolder: String? = nil) async throws -> Repo {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorktrees-\(UUID().uuidString)", isDirectory: true)
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

    private func startNew(_ core: DaemonCore, _ repo: Repo,
                          prompt: String = "Fix the login redirect on Safari") async throws -> UUID {
        try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: repo.project,
                                                    prompt: prompt, worktree: .new))
    }

    private func failure(_ body: () async throws -> some Any) async -> JSONRPCError? {
        do { _ = try await body(); return nil } catch let error as JSONRPCError { return error } catch { return nil }
    }

    // MARK: US1

    @Test func aNewWorktreeIsMadeAndTheRuntimeStartsInsideIt() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)

        let id = try await startNew(core, repo)

        let expected = repo.top.appending(path: ".agents/worktrees/fix-login-redirect-safari")
        let agent = try #require(await core.agent(id))
        let worktree = try #require(agent.worktree)
        #expect(worktree.name == "fix-login-redirect-safari")
        #expect(worktree.branch == "agents/fix-login-redirect-safari")
        #expect(worktree.root.path == Project.standardize(expected).path)
        #expect(worktree.project == repo.project)
        #expect(worktree.base == "main")
        #expect(worktree.madeByApp)
        #expect(agent.cwd.path == worktree.root.path)

        // Both the process and the session were given the worktree.
        #expect(launcher.launches.map { Project.standardize($0.cwd).path } == [worktree.root.path])
        let asked = await launcher.lastAgent?.newSessionParams?["cwd"]?.stringValue
        #expect(asked.map { Project.standardize(URL(filePath: $0)).path } == worktree.root.path)

        let listed = try await git(["worktree", "list", "--porcelain"], in: repo.top)
        #expect(listed.contains("branch refs/heads/agents/fix-login-redirect-safari"))
    }

    @Test func itStaysFiledUnderItsProject() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await startNew(core, repo)

        let projects = await core.allProjects()
        #expect(projects.map(\.folder) == [repo.project], "one project, not one for the worktree")
        let counted = projects.first?.counts.values.reduce(0, +) ?? 0
        #expect(counted == 1)
        #expect(await core.agent(id)?.projectFolder == repo.project)
    }

    @Test func theProjectsOwnCheckoutIsLeftClean() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        _ = try await startNew(core, repo)

        #expect(try await git(["status", "--porcelain"], in: repo.top).isEmpty)
        let exclude = try String(contentsOf: repo.top.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains("/.agents/worktrees/"))
    }

    @Test func itsChatOpensWithWhereItIsWorking() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await startNew(core, repo)

        let entries = try await core.transcript(.init(agentID: id, before: nil, limit: 200)).entries
        guard case .runtimeNote(let first) = entries.first?.kind else {
            Issue.record("the first entry was \(String(describing: entries.first?.kind))")
            return
        }
        #expect(first == "Working in worktree fix-login-redirect-safari on agents/fix-login-redirect-safari, from main.")
    }

    @Test func aProjectInsideTheRepositoryWorksInTheSameFolderOfTheWorktree() async throws {
        let repo = try await repository(subfolder: "app")
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await startNew(core, repo, prompt: "tidy the app")

        let agent = try #require(await core.agent(id))
        let worktree = try #require(agent.worktree)
        #expect(worktree.root.path == repo.top.appending(path: ".agents/worktrees/tidy-app").path)
        #expect(agent.cwd.path == worktree.root.appending(path: "app").path)
        #expect(agent.projectFolder == repo.project)
    }

    @Test func aRepositoryWithNoCommitStartsNothing() async throws {
        let repo = try await repository(committed: false)
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)

        let error = await failure { try await startNew(core, repo) }
        #expect(error?.code == DaemonAPI.Failure.worktreeFailed)
        #expect(error?.message.contains("no commit") == true)
        #expect(await core.allAgents().isEmpty)
        #expect(launcher.launchCount == 0)
    }

    @Test func aHookThatRefusesStartsNothingAndSaysWhy() async throws {
        let repo = try await repository()
        let hook = repo.top.appending(path: ".git/hooks/post-checkout")
        try "#!/bin/sh\necho 'the hook says no' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)

        let error = await failure { try await startNew(core, repo) }
        #expect(error?.code == DaemonAPI.Failure.worktreeFailed)
        #expect(error?.message.contains("the hook says no") == true)
        #expect(await core.allAgents().isEmpty)
        #expect(launcher.launchCount == 0)
    }

    @Test func twoStartsFromTheSameWordsGetTwoWorktrees() async throws {
        for _ in 0..<3 {
            let repo = try await repository()
            var slow = FakeACPAgent.Script()
            slow.handshakeDelay = .milliseconds(150)
            let core = try await makeCore(repo, FakeLauncher(script: slow))

            async let first = startNew(core, repo, prompt: "Fix the build")
            async let second = startNew(core, repo, prompt: "Fix the build")
            let ids = try await [first, second]

            var names: [String] = []
            for id in ids { names.append(try #require(await core.agent(id)?.worktree?.name)) }
            #expect(Set(names) == ["fix-build", "fix-build-2"])
            #expect(await core.reservedWorktreeNames.isEmpty)
        }
    }

    @Test func anAgentWhoseWorktreeHasGoneIsNotPickedUpAnywhereElse() async throws {
        let repo = try await repository()
        var resuming = FakeACPAgent.Script()
        resuming.supportsResume = true
        let launcher = FakeLauncher(script: resuming)
        let core = try await makeCore(repo, launcher)
        let id = try await startNew(core, repo)
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        await eventually("its runtime was handed back") { await core.live[id] == nil }

        let root = try #require(await core.agent(id)?.worktree?.root)
        try FileManager.default.removeItem(at: root)

        let error = await failure { try await core.prompt(.init(agentID: id, text: "carry on")) }
        #expect(error?.code == DaemonAPI.Failure.worktreeMissing)
        #expect(error?.message == "The worktree fix-login-redirect-safari is gone, so this agent cannot be picked up where it was.")
        #expect(launcher.launchCount == 1, "never started again, in the project folder or anywhere")
    }

    /// A branch of the conversation carries on where it was: same worktree, same project.
    @Test func aBranchStaysInItsWorktree() async throws {
        let repo = try await repository()
        var forking = FakeACPAgent.Script()
        forking.sessionCapabilities = ["close": [:], "list": [:], "fork": [:]]
        let core = try await makeCore(repo, FakeLauncher(script: forking))
        let id = try await startNew(core, repo)
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }

        let branch = try await core.fork(agentID: id)
        let original = try #require(await core.agent(id))
        let copy = try #require(await core.agent(branch))
        #expect(copy.worktree == original.worktree)
        #expect(copy.projectFolder == repo.project)
        #expect(await core.allProjects().map(\.folder) == [repo.project])
    }

    // MARK: US2 — worktrees already there

    private func addByHand(_ repo: Repo, _ name: String) async throws -> URL {
        let path = repo.top.deletingLastPathComponent().appending(path: name)
        _ = try await git(["worktree", "add", "-q", "-b", name, path.path, "HEAD"], in: repo.top)
        return Project.standardize(path)
    }

    @Test func aFolderInNoRepositoryHasNoWorktrees() async throws {
        let repo = try await repository()
        let plain = repo.top.deletingLastPathComponent().appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let core = try await makeCore(repo, FakeLauncher())
        let listed = await core.listWorktrees(for: plain)
        #expect(!listed.isRepository)
        #expect(listed.worktrees.isEmpty)
    }

    @Test func everyWorktreeIsListedForWhatItIs() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let id = try await startNew(core, repo)
        let byHand = try await addByHand(repo, "by-hand")
        let gone = try await addByHand(repo, "gone")
        try FileManager.default.removeItem(at: gone)

        let listed = await core.listWorktrees(for: repo.project)
        #expect(listed.isRepository && listed.canMakeNew)
        let byName = Dictionary(uniqueKeysWithValues: listed.worktrees.map { ($0.name, $0) })

        let main = try #require(byName[repo.top.lastPathComponent])
        #expect(main.isProjectFolder)
        #expect(main.agents.isEmpty, "the agent in the worktree is not counted in the main checkout")

        let made = try #require(byName["fix-login-redirect-safari"])
        #expect(made.madeByApp && made.exists, "\(made)")
        #expect(made.agents == [id])
        #expect(made.branch == "agents/fix-login-redirect-safari")

        let hand = try #require(byName["by-hand"])
        #expect(!hand.madeByApp && hand.exists)
        #expect(hand.root == byHand)

        #expect(byName["gone"]?.exists == false)
    }

    @Test func aRepositoryWithNoCommitCannotMakeOne() async throws {
        let repo = try await repository(committed: false)
        let core = try await makeCore(repo, FakeLauncher())
        let listed = await core.listWorktrees(for: repo.project)
        #expect(listed.isRepository)
        #expect(!listed.canMakeNew)
        #expect(listed.whyNot?.contains("no commit") == true)
    }

    @Test func anAgentCanStartInAWorktreeAlreadyThere() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        let byHand = try await addByHand(repo, "by-hand")

        // The chooser asks for options in the worktree, and the start uses that draft.
        let offered = try await core.options(.init(runtimeID: "claude", cwd: byHand))
        let id = try await core.start(.init(runtimeID: "claude", cwd: repo.project, prompt: "review it",
                                            draftID: offered.draftID, worktree: .existing(byHand)))

        let agent = try #require(await core.agent(id))
        #expect(agent.cwd == byHand)
        #expect(agent.worktree?.name == "by-hand")
        #expect(agent.worktree?.branch == "by-hand")
        #expect(agent.worktree?.madeByApp == false)
        #expect(agent.worktree?.base == nil)
        #expect(agent.projectFolder == repo.project)
        #expect(launcher.launchCount == 1, "the draft made in the worktree was the one used")
    }

    @Test func aFolderFromAnotherRepositoryIsRefused() async throws {
        let repo = try await repository()
        let other = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        let error = await failure {
            try await core.start(.init(runtimeID: "claude", cwd: repo.project, prompt: "x",
                                       worktree: .existing(other.top)))
        }
        #expect(error?.code == DaemonAPI.Failure.notAWorktree)
        #expect(launcher.launchCount == 0)
    }

    @Test func aWorktreeThatHasGoneIsRefused() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        let gone = try await addByHand(repo, "gone")
        try FileManager.default.removeItem(at: gone)
        let error = await failure {
            try await core.start(.init(runtimeID: "claude", cwd: repo.project, prompt: "x",
                                       worktree: .existing(gone)))
        }
        #expect(error?.code == DaemonAPI.Failure.worktreeMissing)
        #expect(launcher.launchCount == 0)
    }

    // MARK: US3 — cleaned up by choice

    /// An agent started in a new worktree, finished, with its worktree's folder.
    private func finishedInWorktree(_ core: DaemonCore, _ repo: Repo) async throws -> (UUID, URL) {
        let id = try await startNew(core, repo)
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        return (id, try #require(await core.agent(id)?.worktree?.root))
    }

    private func removal(_ repo: Repo, _ root: URL, confirmed: Bool = false) -> DaemonAPI.WorktreeRemovalRequest {
        .init(project: repo.project, root: root, confirmed: confirmed)
    }

    @Test func archivingLeavesTheWorktreeAndItsBranch() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let (id, root) = try await finishedInWorktree(core, repo)
        try await core.archive(id)

        #expect(FileManager.default.fileExists(atPath: root.path))
        let branches = try await git(["branch", "--list", "agents/*"], in: repo.top)
        #expect(branches.contains("agents/fix-login-redirect-safari"))
    }

    @Test func aWorktreeSomeoneIsWorkingInIsNotRemoved() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let (id, root) = try await finishedInWorktree(core, repo)

        let check = try await core.checkWorktreeRemoval(removal(repo, root))
        #expect(check.blockedBy == [id], "finished is not archived, so it still holds it")
        let error = await failure { try await core.removeWorktree(removal(repo, root, confirmed: true)) }
        #expect(error?.code == DaemonAPI.Failure.worktreeInUse)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aWorktreeTheAppDidNotMakeIsNotItsToRemove() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let byHand = try await addByHand(repo, "by-hand")
        let error = await failure { try await core.removeWorktree(removal(repo, byHand, confirmed: true)) }
        #expect(error?.code == DaemonAPI.Failure.notAWorktree)
        #expect(FileManager.default.fileExists(atPath: byHand.path))
    }

    @Test func workThatWouldBeLostIsSaidFirst() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let (id, root) = try await finishedInWorktree(core, repo)
        try await core.archive(id)
        // A commit on its branch, and a change not committed.
        try "more\n".write(to: root.appending(path: "NEW"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "NEW"], in: root)
        _ = try await git(["commit", "-q", "-m", "work"], in: root)
        try "edited\n".write(to: root.appending(path: "README"), atomically: true, encoding: .utf8)

        let check = try await core.checkWorktreeRemoval(removal(repo, root))
        #expect(check.blockedBy.isEmpty)
        #expect(check.uncommitted == 1)
        #expect(check.unmerged)

        let refused = await failure { try await core.removeWorktree(removal(repo, root)) }
        #expect(refused?.message == "Removing fix-login-redirect-safari would lose 1 uncommitted change and commits not in main. Confirm to remove it anyway.")
        #expect(FileManager.default.fileExists(atPath: root.path))

        let removed = try await core.removeWorktree(removal(repo, root, confirmed: true))
        #expect(removed.removedBranch)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try await git(["branch", "--list", "agents/*"], in: repo.top).isEmpty)
    }

    @Test func aCleanMergedWorktreeGoesWithoutAsking() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let (id, root) = try await finishedInWorktree(core, repo)
        try await core.archive(id)

        let check = try await core.checkWorktreeRemoval(removal(repo, root))
        #expect(!check.losesWork)
        let removed = try await core.removeWorktree(removal(repo, root))
        #expect(removed.removedBranch)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!(try await git(["worktree", "list"], in: repo.top)).contains("fix-login"))
    }

    @Test func aWorktreeWhoseFolderHasGoneIsForgotten() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let (id, root) = try await finishedInWorktree(core, repo)
        try await core.archive(id)
        try FileManager.default.removeItem(at: root)

        _ = try await core.removeWorktree(removal(repo, root))
        #expect(!(try await git(["worktree", "list"], in: repo.top)).contains("fix-login"))
    }

    // MARK: US4 — an agent's helpers in worktrees

    /// A helper start, made with the caller's token bound again first — a fake agent's
    /// quick turn can end its session, and with it the token, at any moment.
    private func startHelper(_ core: DaemonCore, caller: UUID, prompt: String,
                             worktree: String?) async throws -> (note: String, agentID: UUID) {
        let token = UUID().uuidString
        var attempt = 0
        while true {
            await core.bindAppToken(token, to: caller)
            do {
                return try await core.startHelper(.init(token: token, prompt: prompt, worktree: worktree))
            } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.noSuchAgent && attempt < 5 {
                attempt += 1
            }
        }
    }

    @Test func anAgentCanStartAHelperInANewWorktree() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let lead = try await core.start(.init(runtimeID: "claude", cwd: repo.project, prompt: "lead"))

        let started = try await startHelper(core, caller: lead, prompt: "Write the parser tests", worktree: "new")
        let helper = try #require(await core.agent(started.agentID))
        #expect(helper.worktree?.name == "write-parser-tests")
        #expect(helper.startedByAgent == lead)
        #expect(helper.projectFolder == repo.project)
        #expect(started.note.hasSuffix("It is working in worktree write-parser-tests on agents/write-parser-tests."))
        #expect(HelperLimit.placesInUse(in: repo.project, agents: await core.allAgents()) == 1)
    }

    @Test func aHelperCanBeSentIntoAWorktreeByName() async throws {
        let repo = try await repository()
        let core = try await makeCore(repo, FakeLauncher())
        let byHand = try await addByHand(repo, "by-hand")
        let lead = try await core.start(.init(runtimeID: "claude", cwd: repo.project, prompt: "lead"))

        let started = try await startHelper(core, caller: lead, prompt: "review", worktree: "by-hand")
        #expect(await core.agent(started.agentID)?.cwd == byHand)
    }

    @Test func aNameThatIsNoWorktreeIsRefusedWithTheNamesThereAre() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        _ = try await addByHand(repo, "by-hand")
        let lead = try await core.start(.init(runtimeID: "claude", cwd: repo.project, prompt: "lead"))

        let error = await failure { try await startHelper(core, caller: lead, prompt: "x", worktree: "nope") }
        #expect(error?.code == DaemonAPI.Failure.notAWorktree)
        #expect(error?.message == "Nothing was started: there is no worktree called \"nope\" here. There are: by-hand, or say \"new\".")
        #expect(await core.allAgents().map(\.id) == [lead], "only the lead")
    }

    @Test func theToolTakesAWorktree() throws {
        let call = AppService.agentCall(named: "mcp__agents__start_agent",
                                        ["prompt": "go", "worktree": "new"])
        guard case .success(.start(_, _, _, _, let worktree))? = call else {
            Issue.record("not a start: \(String(describing: call))")
            return
        }
        #expect(worktree == "new")
    }

    /// An agent without a worktree starts where it always did.
    @Test func withoutAChoiceNothingChanges() async throws {
        let repo = try await repository()
        let launcher = FakeLauncher()
        let core = try await makeCore(repo, launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: repo.project, prompt: "hello"))

        #expect(await core.agent(id)?.worktree == nil)
        #expect(launcher.launches.map { Project.standardize($0.cwd) } == [repo.project])
        #expect(!FileManager.default.fileExists(atPath: repo.top.appending(path: ".agents").path))
    }
}
