import Foundation
import Testing
@testable import AgentsKit

/// Daemon `git` must not honour a repository's own config that would run a command
/// (security review S3).
@Suite("Daemon git does not run repo config commands")
struct GitProcessHardeningTests {
    /// A `core.fsmonitor` script that writes a sentinel is set in the repo. A daemon
    /// `git status` must not create that sentinel — the hardened `-c core.fsmonitor=false`
    /// wins over the repo config.
    @Test func repoFsmonitorDoesNotRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "git-harden-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try await git(["init", "-q"], in: root)
        try await git(["config", "user.email", "harden@example.com"], in: root)
        try await git(["config", "user.name", "Harden"], in: root)
        try "x\n".write(to: root.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "file.txt"], in: root)
        try await git(["commit", "-qm", "start"], in: root)

        let sentinel = root.appending(path: "fsmonitor-ran")
        let script = root.appending(path: "fsmonitor.sh")
        try """
            #!/bin/sh
            echo ran > '\(sentinel.path)'
            # git's fsmonitor protocol expects a version line; empty is enough to fail soft.
            exit 1
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try await git(["config", "core.fsmonitor", script.path], in: root)

        // Without hardening, status would invoke the script. With it, the sentinel stays gone.
        try await git(["status", "--porcelain"], in: root)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path),
                "core.fsmonitor must not run under GitProcess")
    }

    /// The argv the daemon builds always starts with the config overrides, so every
    /// call site that uses the git convenience initializer is covered.
    @Test func hardenedArgumentsPrependEveryOverride() {
        let args = GitProcess.hardenedArguments(["status", "--porcelain"])
        #expect(args.starts(with: GitProcess.configOverrides.flatMap { ["-c", $0] }))
        #expect(args.suffix(2) == ["status", "--porcelain"])
    }

    private func git(_ arguments: [String], in folder: URL) async throws {
        let outcome = try await GitProcess(arguments, in: folder).run()
        #expect(outcome.succeeded, "git \(arguments) failed: \(outcome.errors)")
    }
}
