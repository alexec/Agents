import Foundation

/// The person's own `git`, run for the daemon with nobody at a keyboard (027).
///
/// Their git, not one we ship: it is the one that has their keychain helper, their SSH
/// agent and their config, and those are the whole of how a private repository is
/// reached. What it must not do is ask — a prompt from the daemon goes to no terminal
/// and waits for ever — so prompts are switched off and stdin is empty. A clone that
/// would have asked fails, and says so.
public final class GitProcess: @unchecked Sendable {
    public struct Outcome: Sendable {
        public var status: Int32
        public var output: String
        public var errors: String
        public var succeeded: Bool { status == 0 }
    }

    public enum LaunchError: Error, Sendable {
        case notInstalled
    }

    private let process = Process()

    /// Where git is on the person's PATH, or nil when it is not installed.
    public static func executable() -> URL? {
        for directory in LoginShellPath.directories() {
            let candidate = URL(filePath: directory).appending(path: "git")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public init(_ arguments: [String], in folder: URL? = nil) throws {
        guard let git = Self.executable() else { throw LaunchError.notInstalled }
        process.executableURL = git
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        var environment = LoginShellPath.environment()
        // Never ask. The SSH side cannot ask either: the daemon has no terminal, and
        // `GIT_SSH_COMMAND` is left alone because it would override their own
        // `core.sshCommand`.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
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
                    errors: String(decoding: drained.errors, as: UTF8.self)))
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
