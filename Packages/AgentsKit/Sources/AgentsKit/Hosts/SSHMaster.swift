import AgentsKitCore
import Foundation

/// One long-lived `ssh -M` per server, owned by the window (037, contracts/ssh.md § 4).
///
/// Everything else the window asks of a server goes over it with `-S`: the person
/// authenticates once, and a new channel costs one round trip rather than a new login.
/// Once the server's home is known it carries the one forward that matters, a local Unix
/// socket to the server daemon's `daemon.sock`, which is where `ServerLink` connects.
///
/// It does not bring itself back. `onExit` says it has gone, and whoever owns it decides
/// when to start another.
public actor SSHMaster {
    public let command: SSHCommand
    /// The local end of the forward, `<root>/hosts/<id>.sock`.
    public let socket: URL

    private var process: Process?
    private var onExit: (@Sendable () async -> Void)?
    private var stopping = false

    public init(command: SSHCommand, socket: URL) {
        self.command = command
        self.socket = socket
    }

    public var isRunning: Bool { process?.isRunning ?? false }
    public var pid: Int32? { process.map(\.processIdentifier) }

    public func setOnExit(_ handler: @escaping @Sendable () async -> Void) {
        onExit = handler
    }

    /// Start the master and wait until it answers `-O check`. With `forwardingTo`, the
    /// local socket is forwarded to that absolute path on the server.
    ///
    /// Throws the `HostProblem` ssh's own words name when it exits before it is ready,
    /// and `timedOut` when it neither exits nor answers in 15 seconds.
    public func start(forwardingTo remote: String?) async throws {
        guard let controlPath = command.controlPath else { throw HostProblem.installFailed("no control path") }
        for path in [controlPath.path(percentEncoded: false), socket.path(percentEncoded: false)]
        where path.utf8.count >= POSIX.socketPathLimit {
            throw DaemonClient.ConnectError.socketPathTooLong(path)
        }
        if process?.isRunning == true { await stop() }
        try? FileManager.default.createDirectory(at: controlPath.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Left by a master that did not get to tidy up. ssh refuses to bind a control
        // path that exists, and a forward whose socket file is in the way fails.
        try? FileManager.default.removeItem(at: controlPath)
        try? FileManager.default.removeItem(at: socket)

        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.masterArguments(
            forward: remote.map { (local: socket.path(percentEncoded: false), remote: $0) })
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let stderr = StderrTail()
        errors.fileHandleForReading.readabilityHandler = { handle in stderr.append(handle.availableData) }
        process.terminationHandler = { [weak self] _ in
            errors.fileHandleForReading.readabilityHandler = nil
            Task { await self?.exited() }
        }
        stopping = false
        try process.run()
        self.process = process

        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                let words = stderr.text
                let hasKeys = await SSHCommand.agentHasKeys(environment: command.environment)
                throw SSHCommand.classify(status: process.terminationStatus == 0 ? 255 : process.terminationStatus,
                                          stderr: words, agentHasKeys: hasKeys) ?? .installFailed(words)
            }
            if let check = try? await command.run(command.controlArguments("check")), check.status == 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await stop()
        throw HostProblem.timedOut("connect")
    }

    /// `-O exit`, then SIGTERM if it is still there after two seconds.
    public func stop() async {
        guard let process else { return }
        stopping = true
        if process.isRunning {
            _ = try? await command.run(command.controlArguments("exit"))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { process.terminate() }
        }
        self.process = nil
        if let controlPath = command.controlPath { try? FileManager.default.removeItem(at: controlPath) }
        try? FileManager.default.removeItem(at: socket)
    }

    private func exited() async {
        // A stop that was asked for is not news.
        guard !stopping else { return }
        process = nil
        await onExit?()
    }

    private final class StderrTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) {
            guard !more.isEmpty else { return }
            lock.lock(); data.append(more); if data.count > 16_384 { data = data.suffix(16_384) }; lock.unlock()
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}
