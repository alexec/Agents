import Foundation
import AgentsKitCore

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
        /// It ran past its deadline and was stopped (#207). `status` is -1.
        public var timedOut = false
        /// It printed more than its caller keeps; `output` is the first part.
        public var truncated = false
        public var succeeded: Bool { status == 0 }
    }

    public enum LaunchError: Error, Sendable {
        case notInstalled
    }

    /// How long one call may run before it is stopped (#207): long enough for any read
    /// of a large repository, short enough that a hung one (an LFS smudge on a dead
    /// network, an ssh that never answers) frees whatever waits behind it.
    public static let readDeadline: Duration = .seconds(30)
    /// What one call keeps of what it printed, unless its caller says otherwise.
    public static let defaultOutputLimit = 16 * 1024 * 1024

    private let process = Process()
    /// What is written to its stdin, for the one command that reads a list there
    /// (`cat-file --batch`, 035). Nil is an empty stdin, as it always was.
    private let input: Data?
    /// How long it may run, and how much of its output is kept (#207).
    public var deadline: Duration = GitProcess.readDeadline
    public var outputLimit: Int = GitProcess.defaultOutputLimit

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
    }

    /// Run to the end, or to its deadline (#207): `ChildProcess` drains both pipes as
    /// they fill, keeps at most `outputLimit` bytes, and stops it (TERM, then KILL) when
    /// the deadline comes, so nothing waiting on it waits for ever.
    public func run() async throws -> Outcome {
        let outcome = await ChildProcess.run(process, input: input, deadline: deadline,
                                             outputLimit: outputLimit)
        if let failure = outcome.failure {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        var errors = String(decoding: outcome.errors, as: UTF8.self)
        if outcome.timedOut {
            let stopped = "Stopped after \(Self.said(deadline)) with no end in sight."
            errors = errors.isEmpty ? stopped : stopped + "\n" + errors
        }
        return Outcome(status: outcome.status,
                       output: String(decoding: outcome.output, as: UTF8.self),
                       errors: errors,
                       data: outcome.output, timedOut: outcome.timedOut, truncated: outcome.truncated)
    }

    /// A deadline as said to a person: "30 seconds", "2 minutes".
    static func said(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds >= 120, seconds % 60 == 0 { return "\(seconds / 60) minutes" }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    /// Stop it. What it wrote is its caller's to delete.
    public func terminate() {
        if process.isRunning { process.terminate() }
    }
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
