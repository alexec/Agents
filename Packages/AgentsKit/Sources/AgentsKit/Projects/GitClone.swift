import Foundation

/// The person's own `git`, run for the daemon with nobody at a keyboard (027).
///
/// Their git, not one we ship: it is the one that has their keychain helper, their SSH
/// agent and their config, and those are the whole of how a private repository is
/// reached. What it must not do is ask — a prompt from the daemon goes to no terminal
/// and waits for ever — so prompts are switched off and stdin is empty. A clone that
/// would have asked fails, and says so.
///
/// It also must not run commands a repository's own config names (`core.fsmonitor`,
/// hooks, pager, external diff): every git call gets `-c` overrides and
/// `GIT_CONFIG_NOSYSTEM=1` (security review S3). `gh` does not.
public final class GitProcess: @unchecked Sendable {
    public struct Outcome: Sendable {
        public var status: Int32
        public var output: String
        public var errors: String
        /// What it printed, as bytes: for output measured in bytes, as `cat-file
        /// --batch`'s is (035).
        public var data = Data()
        public var succeeded: Bool { status == 0 }
    }

    public enum LaunchError: Error, Sendable {
        case notInstalled
    }

    private let process = Process()
    /// What is written to its stdin, for the one command that reads a list there
    /// (`cat-file --batch`, 035). Nil is an empty stdin, as it always was.
    private let input: Data?

    /// Where git is on the person's PATH, or nil when it is not installed.
    public static func executable() -> URL? {
        for directory in LoginShellPath.directories() {
            let candidate = URL(filePath: directory).appending(path: "git")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Config overrides prepended to every daemon `git` call so a repository's own
    /// config cannot run commands as the daemon (security review S3): no fsmonitor, no
    /// hooks, no pager, no external diff, no `ext::` helpers. Applied only on the git
    /// convenience initializer — `gh` goes through `init(executable:)` without them.
    static let configOverrides = [
        "core.fsmonitor=false",
        "core.hooksPath=/dev/null",
        "core.pager=cat",
        "diff.external=",
        "protocol.ext.allow=never",
    ]

    /// Environment for every daemon `git` call. `GIT_CONFIG_NOSYSTEM` drops system
    /// config; the person's user config stays (remotes, SSH). Callers may still lay
    /// extras over this (035's `GIT_OPTIONAL_LOCKS=0`).
    static let hardenedEnvironment: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

    /// `-c key=value` pairs for `configOverrides`, then the caller's arguments.
    static func hardenedArguments(_ arguments: [String]) -> [String] {
        configOverrides.flatMap { ["-c", $0] } + arguments
    }

    /// `extra` is laid over the environment last: how a caller that must only read
    /// says so (035's `GIT_OPTIONAL_LOCKS=0`).
    public convenience init(_ arguments: [String], in folder: URL? = nil,
                            environment extra: [String: String] = [:], input: Data? = nil) throws {
        guard let git = Self.executable() else { throw LaunchError.notInstalled }
        // Never ask. The SSH side cannot ask either: the daemon has no terminal, and
        // `GIT_SSH_COMMAND` is left alone because it would override their own
        // `core.sshCommand`.
        self.init(executable: git, arguments: Self.hardenedArguments(arguments), in: folder,
                  environment: Self.hardenedEnvironment.merging(extra) { _, new in new },
                  input: input)
    }

    /// Any of the person's own tools, run the same way: their PATH, nothing that can
    /// ask. `gh` goes through here too, because everything that makes git safe
    /// to run unattended is what makes `gh` safe. No git `-c` hardenings here: those
    /// are only for the git convenience initializer above.
    init(executable: URL, arguments: [String], in folder: URL? = nil,
         environment extra: [String: String] = [:], input: Data? = nil) {
        self.input = input
        process.executableURL = executable
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        process.environment = LoginShellPath.environment().merging(extra) { _, new in new }
        process.standardInput = input == nil ? FileHandle.nullDevice : Pipe()
    }

    /// Run to the end. Both pipes are drained while it runs, so a chatty git cannot
    /// fill one and stall. Ended by the termination handler rather than
    /// `waitUntilExit`, which on a dispatch thread can wait for ever on a git that has
    /// already gone.
    public func run() async throws -> Outcome {
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let drained = Drained()
        drained.group.enter()
        process.terminationHandler = { _ in drained.group.leave() }
        try process.run()
        if let input, let stdin = process.standardInput as? Pipe {
            // Written off this thread and closed, so a list longer than the pipe's
            // buffer cannot stall git and this caller waiting on each other.
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let process = self.process
        return await withCheckedContinuation { continuation in
            drained.group.enter()
            DispatchQueue.global().async {
                drained.output = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                drained.group.leave()
            }
            drained.group.enter()
            DispatchQueue.global().async {
                drained.errors = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
                drained.group.leave()
            }
            drained.group.notify(queue: .global()) {
                continuation.resume(returning: Outcome(
                    status: process.terminationStatus,
                    output: String(decoding: drained.output, as: UTF8.self),
                    errors: String(decoding: drained.errors, as: UTF8.self),
                    data: drained.output))
            }
        }
    }

    /// Stop it. What it wrote is its caller's to delete.
    public func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// What the two pipes said, and whether git has gone. Each field is written once, on
/// its own queue, before the group is left, and read only after it is empty.
private final class Drained: @unchecked Sendable {
    let group = DispatchGroup()
    var output = Data()
    var errors = Data()
}

extension GitProcess {
    /// Every remote URL a checkout names, or empty when it is not a checkout. Read
    /// only: nothing is fetched and nothing is written.
    public static func remoteURLs(of folder: URL) async -> [String] {
        guard FileManager.default.fileExists(atPath: folder.appending(path: ".git").path),
              let git = try? GitProcess(["config", "--get-regexp", #"^remote\..*\.url$"#], in: folder),
              let outcome = try? await git.run(), outcome.succeeded else { return [] }
        return outcome.output.split(separator: "\n").compactMap { line in
            line.split(separator: " ", maxSplits: 1).last.map(String.init)
        }
    }
}

/// What went wrong with a clone, in a sentence somebody can act on.
///
/// Git's own words are good but addressed to someone at a terminal ("could not read
/// Username for 'https://github.com': terminal prompts disabled"). The ones people meet
/// are recognised and said plainly; anything else is git's last `fatal:` line, which is
/// still better than a code.
public enum CloneFailure {
    public static func explain(_ errors: String, remote: GitRemote) -> String {
        let text = errors.lowercased()
        let where_ = "\(remote.host)/\(remote.path)"
        if text.contains("xcrun: error") || text.contains("no developer tools") {
            return notInstalled
        }
        if text.contains("could not resolve host") || text.contains("could not resolve hostname") {
            return "Could not reach \(remote.host). Check the address and the network."
        }
        if text.contains("repository not found") || text.contains("does not appear to be a git repository")
            || text.contains("repository") && (text.contains("not found") || text.contains("does not exist")) {
            return "There is no repository at \(where_), or this Mac is not allowed to read it."
        }
        if text.contains("could not read username") || text.contains("could not read password")
            || text.contains("terminal prompts disabled") || text.contains("authentication failed") {
            // GitHub asks for a name for a repository that is not there as well as for
            // a private one, so this cannot tell the two apart and does not pretend to.
            return "\(where_) needs a sign-in this Mac does not have, or is not there. If it is private, sign in once with git in Terminal, then try again."
        }
        if text.contains("permission denied (publickey") {
            return "\(remote.host) did not accept this Mac's SSH key for \(where_)."
        }
        if text.contains("host key verification failed") {
            return "\(remote.host) is not a known SSH host on this Mac. Connect to it once with ssh in Terminal, then try again."
        }
        let fatal = errors.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix("fatal:") }
            .map { $0.dropFirst("fatal:".count).trimmingCharacters(in: .whitespaces) }
        if let fatal, !fatal.isEmpty { return "Could not clone \(where_): \(fatal)" }
        return "Could not clone \(where_)."
    }

    public static let notInstalled = "Git is not installed on this Mac. Install the Xcode command line tools, then try again."
}
