import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// A project whose `origin` says github.com, and a fake `gh` answering for it (038).
///
/// Real git: a bare repository stands in for GitHub, with a branch for each pull request
/// in `pulls-mixed`, and the project is a clone of it whose `origin` is rewritten to the
/// bare one with `insteadOf`, so fetches and pushes work with no network. #405's branch
/// is checked out in the project folder and #412's in a worktree beside it; the others
/// are only on the "GitHub" side.
struct PullRequestSandbox {
    let core: DaemonCore
    let project: URL
    let bare: URL
    let root: URL
    let gh: FakeGitHub
    let launcher: FakeLauncher

    /// Where #412's branch is checked out.
    var fixWorktree: URL { Project.standardize(root.appending(path: "fix-login-redirect", directoryHint: .isDirectory)) }

    static let branches = ["fix-login-redirect", "paper-settings-card", "retry-upload", "docs-for-leases", "bump-swiftterm"]

    @discardableResult
    static func git(_ arguments: [String], in folder: URL) async throws -> String {
        let outcome = try await GitProcess(arguments, in: folder).run()
        guard outcome.succeeded else {
            throw GitWorktrees.Failure(message: "git \(arguments.joined(separator: " ")): \(outcome.errors)")
        }
        return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func make(origin: String = "https://github.com/alexec/agents.git",
                     workflows: [String: String] = [:],
                     script: FakeACPAgent.Script = .init()) async throws -> PullRequestSandbox {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsPulls-\(UUID().uuidString)", isDirectory: true)
        let seed = root.appending(path: "seed", directoryHint: .isDirectory)
        let bare = root.appending(path: "remote.git", directoryHint: .isDirectory)
        let project = root.appending(path: "agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)

        try await git(["init", "-q", "-b", "main"], in: seed)
        try await git(["config", "user.email", "test@example.com"], in: seed)
        try await git(["config", "user.name", "Test"], in: seed)
        try "hello\n".write(to: seed.appending(path: "README"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: seed)
        try await git(["commit", "-q", "-m", "first"], in: seed)
        for branch in branches { try await git(["branch", branch], in: seed) }
        try await git(["clone", "-q", "--bare", seed.path, bare.path], in: root)
        try await git(["clone", "-q", bare.path, project.path], in: root)
        try await git(["config", "user.email", "test@example.com"], in: project)
        try await git(["config", "user.name", "Test"], in: project)
        try await git(["remote", "set-url", "origin", origin], in: project)
        try await git(["config", "url.\(bare.path).insteadOf", origin], in: project)
        try await git(["checkout", "-q", "paper-settings-card"], in: project)
        try await git(["worktree", "add", "-q", root.appending(path: "fix-login-redirect").path, "fix-login-redirect"],
                      in: project)

        for (id, text) in workflows {
            let folder = WorkflowFile.folder(in: project)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: WorkflowFile.url(for: id, in: project))
        }
        // The workflows folder is the project's own, and not a change to its work.
        try "/.agents/\n".write(to: project.appending(path: ".git/info/exclude"), atomically: true, encoding: .utf8)

        let locations = StoreLocations(root: root.appending(path: "store"))
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        _ = try await core.addProject(project)
        await core.rescanWorkflows(in: project)
        let gh = try FakeGitHub()
        try gh.answer(with: "pulls-mixed")
        await core.setGitHubCLI(gh.cli)
        return PullRequestSandbox(core: core, project: Project.standardize(project), bare: bare,
                                  root: root, gh: gh, launcher: launcher)
    }

    /// Every word said to an agent, in order.
    func prompts(to agentID: UUID) async throws -> [String] {
        try await core.transcript(DaemonAPI.TranscriptRequest(agentID: agentID, before: nil, limit: 200))
            .entries.compactMap { entry in
                if case .userMessage(let text, _, _) = entry.kind { return text }
                return nil
            }
    }
}
