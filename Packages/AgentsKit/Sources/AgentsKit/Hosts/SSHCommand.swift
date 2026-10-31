import AgentsKitCore
import Foundation

/// The window's one way of running `ssh` (037). Every command line in contracts/ssh.md is
/// built here and nowhere else.
///
/// It is the person's own `ssh`, with their config, keys, agent and known hosts, so
/// nothing about reaching a server is decided here. `BatchMode` is on for every call: ssh
/// never waits on a prompt nobody can see, and a key that needs a passphrase fails at
/// once and is said to be locked.
public struct SSHCommand: Sendable {
    public var executable: URL
    /// The destination, exactly as the person typed it. Always after `--`.
    public var name: String
    /// The master's control socket, `<root>/machines/<id>.ctl`. Nil only for commands that
    /// never touch a master.
    public var controlPath: URL?
    public var environment: [String: String]
    /// Options for every command that logs in: a key given for one install and the
    /// known-hosts file its host key went into (058, T072), where the person's own config
    /// is not the one to use.
    public var options: [String] = []

    public static let system = URL(filePath: "/usr/bin/ssh")

    public init(executable: URL = SSHCommand.system, name: String, controlPath: URL?,
                environment: [String: String] = SSHCommand.environment(from: ProcessInfo.processInfo.environment)) {
        self.executable = executable
        self.name = name
        self.controlPath = controlPath
        self.environment = environment
    }

    static let batch = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

    /// What the person's config may say that would break a connection of ours (#610):
    /// - `RemoteCommand` makes ssh refuse a command of ours ("Cannot execute command-line
    ///   and remote command"), and `RequestTTY force` puts `\r\n` in what we read back.
    /// - `LocalForward`, `RemoteForward` and `DynamicForward` would be opened by every
    ///   connection, and one that cannot open is a failure of ours. `ClearAllForwardings`
    ///   clears a forward given on the command line too, so a connection that needs one
    ///   asks its own master for it (`tunnelForwardArguments`).
    static let quiet = ["-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "ClearAllForwardings=yes"]

    /// A connection of its own, never the person's `ControlMaster`: one of theirs would
    /// carry ours past the host key check we ask for, and an `auto` one would be made by
    /// us and left behind by `ControlPersist`.
    static let ownConnection = ["-o", "ControlMaster=no", "-o", "ControlPath=none"]

    /// What ssh is handed as the destination. `user@host:port` is how people write it,
    /// and ssh does not read a port there; it does read `ssh://user@host:port`, so that
    /// form is written for it (037). An alias, or anything else, goes as typed.
    var destination: String {
        guard !name.hasPrefix("ssh://"), let colon = name.lastIndex(of: ":"),
              let port = Int(name[name.index(after: colon)...]), (1...65535).contains(port),
              !name[..<colon].contains(":") else { return name }
        return "ssh://" + name
    }

    private var control: [String] {
        guard let controlPath else { return [] }
        return ["-S", controlPath.path(percentEncoded: false)]
    }

    /// § 1: what the person's config says about this name, with no network.
    public var resolveArguments: [String] { ["-G", "--", destination] }

    /// § 3: connect only far enough to learn the host key, offering no credentials, into
    /// `knownHosts` alone.
    public func keyFetchArguments(knownHosts: URL) -> [String] {
        Self.batch + Self.quiet + Self.ownConnection + ["-o", "StrictHostKeyChecking=accept-new",
                      "-o", "UserKnownHostsFile=\(knownHosts.path(percentEncoded: false))",
                      "-o", "GlobalKnownHostsFile=/dev/null",
                      "-o", "PreferredAuthentications=none"]
            // After ours: ssh keeps the first value it is given for each option.
            + options + ["--", destination, "true"]
    }

    /// § 4: the long-lived connection everything else goes over.
    public func masterArguments(forward: (local: String, remote: String)?) -> [String] {
        var args = Self.batch + ["-M", "-N"] + control + [
            "-o", "ControlPersist=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes"]
        if let forward { args += ["-L", "\(forward.local):\(forward.remote)"] }
        return args + ["--", destination]
    }

    /// Ask the master to add a reverse forward (047): `remote`, a Unix socket path on the
    /// server, to `local` on this Mac (`host:port`). sshd makes the socket owner-only.
    public func remoteForwardArguments(remote: String, local: String) -> [String] {
        control + ["-O", "forward", "-R", "\(remote):\(local)", "--", destination]
    }

    /// Whether `ssh -G` says this name is reached through another machine: a `ProxyJump`
    /// or a `ProxyCommand` (#435). Such a server can rarely dial back to this Mac.
    public static func throughBastion(_ resolved: String) -> Bool {
        resolved.split(whereSeparator: \.isNewline).contains { line in
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2, ["proxyjump", "proxycommand"].contains(words[0].lowercased()) else { return false }
            return words[1].trimmingCharacters(in: .whitespaces).lowercased() != "none"
        }
    }

    /// The connection a reverse tunnel rides (#435, #610): a master of its own on
    /// `control`, never the person's, so neither their `ControlPersist` nor their
    /// `ControlPath` can end or take it. It opens no forward: `ClearAllForwardings` drops
    /// every one the config names, and would drop a `-R` given here too, so the tunnel's
    /// one forward is asked for once this is up (`tunnelForwardArguments`).
    public func tunnelMasterArguments(control: URL) -> [String] {
        Self.batch + options + Self.quiet + [
            "-M", "-N", "-S", control.path(percentEncoded: false), "-o", "ControlPersist=no",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes",
            "--", destination]
    }

    /// The tunnel's forward, asked of its master: the server's `127.0.0.1:remote` reaches
    /// this machine's `127.0.0.1:local`. ssh exits non-zero with its reason when the server
    /// will not open it (the port is taken, or `AllowTcpForwarding no`).
    public func tunnelForwardArguments(control: URL, remotePort: Int, localPort: Int) -> [String] {
        ["-S", control.path(percentEncoded: false), "-O", "forward",
         "-R", "127.0.0.1:\(remotePort):127.0.0.1:\(localPort)", "--", destination]
    }

    /// `-O check` or `-O exit`, asked of a tunnel's master.
    public func tunnelControlArguments(control: URL, _ operation: String) -> [String] {
        ["-S", control.path(percentEncoded: false), "-O", operation, "--", destination]
    }

    /// `-O check` or `-O exit`, asked of the master.
    public func controlArguments(_ operation: String) -> [String] {
        control + ["-O", operation, "--", destination]
    }

    /// §§ 5–8: a shell command on the server, over the master.
    /// With no master of ours, a connection of its own (#610).
    public func runArguments(_ remote: String) -> [String] {
        Self.batch + options + Self.quiet + (controlPath == nil ? Self.ownConnection : control)
            + ["--", destination, remote]
    }

    /// The window's environment, less anything that could open a prompt the window does
    /// not know about, and less this app's own variables, which would otherwise ride
    /// along into a server's shell via `SendEnv` and mean nothing there.
    public static func environment(from inherited: [String: String]) -> [String: String] {
        inherited.filter { key, _ in
            !(key == "SSH_ASKPASS" || key == "SSH_ASKPASS_REQUIRE" || key == "DISPLAY"
              || key.hasPrefix("CLAUDE") || key.hasPrefix("AGENTS_"))
        }
    }

    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Run `ssh` with these arguments and wait for it. `stdin`, when given, is a file
    /// handed to the process as its standard input: the installer streams a binary this
    /// way without holding it in memory.
    ///
    /// Ended on `terminationHandler`, never `waitUntilExit`, which hangs off the main
    /// thread (memory: waitUntilExit hangs off the main thread).
    ///
    /// Done once it has exited and both pipes are at their end, as `ChildProcess` is: the
    /// pipe's last bytes can still be in a read when the exit is heard, and a busy
    /// machine left them out, so `shasum` came back empty (#225). Something left running
    /// in the background can hold a pipe open, so the ends are waited for only a few
    /// seconds past the exit.
    public func run(_ arguments: [String], stdin: URL? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice

        let collected = Collected()
        return try await withCheckedThrowingContinuation { continuation in
            collected.continuation = continuation
            // Empty is the end of the pipe, reported again and again until the handler goes
            // (#163), and the end of a pipe can come well before the process's exit.
            for (pipe, path) in [(out, \Collected.out), (err, \Collected.err)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collected.ended(path)
                    } else {
                        collected.append(data, to: path)
                    }
                }
            }
            process.terminationHandler = { finished in
                collected.exited(finished.terminationStatus)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collected.finish()
                }
            }
            do {
                try process.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collected.fail(error)
            }
        }
    }

    /// What one run has read, behind a lock; resumes its caller exactly once.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<Output, Error>?
        var out = Data(), err = Data()
        private var status: Int32?
        private var ends: Set<KeyPath<Collected, Data>> = []

        func append(_ data: Data, to path: ReferenceWritableKeyPath<Collected, Data>) {
            lock.withLock { self[keyPath: path].append(data) }
        }

        func ended(_ path: KeyPath<Collected, Data>) {
            if lock.withLock({ ends.insert(path); return ends.count == 2 && status != nil }) { finish() }
        }

        func exited(_ code: Int32) {
            if lock.withLock({ status = code; return ends.count == 2 }) { finish() }
        }

        func finish() {
            let done: (CheckedContinuation<Output, Error>, Output)? = lock.withLock {
                guard let continuation, let status else { return nil }
                self.continuation = nil
                return (continuation, Output(status: status, stdout: String(decoding: out, as: UTF8.self),
                                             stderr: String(decoding: err, as: UTF8.self)))
            }
            if let (continuation, output) = done { continuation.resume(returning: output) }
        }

        func fail(_ error: Error) {
            let pending: CheckedContinuation<Output, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(throwing: error)
        }
    }

    /// What went wrong, from ssh's own words (contracts/ssh.md § Errors). Nil when the
    /// command succeeded. `agentHasKeys` splits a refused login in two: with nothing in
    /// the agent, the likeliest reason is a key that needs its passphrase.
    public static func classify(status: Int32, stderr: String, agentHasKeys: Bool) -> HostProblem? {
        guard status != 0 else { return nil }
        if stderr.contains("Could not resolve hostname") { return .unknownHost }
        // `StrictHostKeyChecking=yes` and no key for it in known_hosts: "No ED25519 host key
        // is known for … and you have requested strict checking." A changed key says more.
        if stderr.contains("you have requested strict checking"),
           !stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyUnknown }
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
            || stderr.contains("Host key verification failed") { return .hostKeyChanged }
        if stderr.contains("Permission denied") { return agentHasKeys ? .loginRefused : .keyLocked }
        if ["Connection timed out", "Operation timed out", "No route to host", "Connection refused"]
            .contains(where: stderr.contains) { return .timedOut("connect") }
        if stderr.contains("administratively prohibited") { return .noStreamLocalForwarding }
        if stderr.contains("No space left on device") { return .diskFull(freeBytes: 0) }
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: true).suffix(3)
        return .installFailed(lines.joined(separator: "\n"))
    }

    /// Whether the person's ssh agent holds any key. `ssh-add -l` exits 0 when it lists
    /// one, 1 when the agent is empty and 2 when there is no agent.
    public static func agentHasKeys(environment: [String: String]) async -> Bool {
        let sshAdd = SSHCommand(executable: URL(filePath: "/usr/bin/ssh-add"), name: "", controlPath: nil,
                                environment: environment)
        return (try? await sshAdd.run(["-l"]).status) == 0
    }
}
