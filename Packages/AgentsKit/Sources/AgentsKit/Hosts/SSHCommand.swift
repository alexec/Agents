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
    /// The master's control socket, `<root>/hosts/<id>.ctl`. Nil only for commands that
    /// never touch a master.
    public var controlPath: URL?
    public var environment: [String: String]

    public static let system = URL(filePath: "/usr/bin/ssh")

    public init(executable: URL = SSHCommand.system, name: String, controlPath: URL?,
                environment: [String: String] = SSHCommand.environment(from: ProcessInfo.processInfo.environment)) {
        self.executable = executable
        self.name = name
        self.controlPath = controlPath
        self.environment = environment
    }

    static let batch = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

    private var control: [String] {
        guard let controlPath else { return [] }
        return ["-S", controlPath.path(percentEncoded: false)]
    }

    /// § 1: what the person's config says about this name, with no network.
    public var resolveArguments: [String] { ["-G", "--", name] }

    /// § 3: connect only far enough to learn the host key, offering no credentials.
    public func keyFetchArguments(knownHosts: URL) -> [String] {
        Self.batch + ["-o", "StrictHostKeyChecking=accept-new",
                      "-o", "UserKnownHostsFile=\(knownHosts.path(percentEncoded: false))",
                      "-o", "GlobalKnownHostsFile=/dev/null",
                      "-o", "PreferredAuthentications=none",
                      "--", name, "true"]
    }

    /// § 4: the long-lived connection everything else goes over.
    public func masterArguments(forward: (local: String, remote: String)?) -> [String] {
        var args = Self.batch + ["-M", "-N"] + control + [
            "-o", "ControlPersist=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes"]
        if let forward { args += ["-L", "\(forward.local):\(forward.remote)"] }
        return args + ["--", name]
    }

    /// `-O check` or `-O exit`, asked of the master.
    public func controlArguments(_ operation: String) -> [String] {
        control + ["-O", operation, "--", name]
    }

    /// §§ 5–8: a shell command on the server, over the master.
    public func runArguments(_ remote: String) -> [String] {
        Self.batch + control + ["--", name, remote]
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
        out.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData, to: \.out) }
        err.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData, to: \.err) }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.append(out.fileHandleForReading.readDataToEndOfFile(), to: \.out)
        collected.append(err.fileHandleForReading.readDataToEndOfFile(), to: \.err)
        return Output(status: status, stdout: collected.string(\.out), stderr: collected.string(\.err))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        var out = Data(), err = Data()
        func append(_ data: Data, to path: ReferenceWritableKeyPath<Collected, Data>) {
            guard !data.isEmpty else { return }
            lock.lock(); self[keyPath: path].append(data); lock.unlock()
        }
        func string(_ path: KeyPath<Collected, Data>) -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: self[keyPath: path], as: UTF8.self)
        }
    }

    /// What went wrong, from ssh's own words (contracts/ssh.md § Errors). Nil when the
    /// command succeeded. `agentHasKeys` splits a refused login in two: with nothing in
    /// the agent, the likeliest reason is a key that needs its passphrase.
    public static func classify(status: Int32, stderr: String, agentHasKeys: Bool) -> HostProblem? {
        guard status != 0 else { return nil }
        if stderr.contains("Could not resolve hostname") { return .unknownHost }
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
