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
        // A master a previous window left running (it quit without stopping it, or
        // crashed) is asked to go first; one that is already dead just leaves a file.
        // ssh refuses to bind a control path that exists, and a forward whose socket
        // file is in the way fails.
        if FileManager.default.fileExists(atPath: controlPath.path(percentEncoded: false)) {
            _ = try? await command.run(command.controlArguments("exit"))
        }
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
        process.terminationHandler = { [weak self] finished in
            errors.fileHandleForReading.readabilityHandler = nil
            Task { await self?.exited(finished) }
        }
        stopping = false
        try process.run()
        self.process = process

        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                // What ssh said last can still be in the pipe: the handler is gone once
                // the process is, so read the rest here or the reason is lost under load.
                errors.fileHandleForReading.readabilityHandler = nil
                stderr.drain(errors.fileHandleForReading.fileDescriptor)
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

    /// For quitting: ask the master to go and do not wait for the answer. The app is
    /// leaving, and a master left behind would hold its socket until the next launch.
    public nonisolated func stopWithoutWaiting() {
        let exit = Process()
        exit.executableURL = command.executable
        exit.arguments = command.controlArguments("exit")
        exit.environment = command.environment
        try? exit.run()
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

    private func exited(_ finished: Process) async {
        // A stop that was asked for is not news, and neither is the end of a master
        // this one has already replaced: its exit arrives late, after the new one is up.
        guard !stopping, finished === process else { return }
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
        /// Whatever is waiting in the pipe, without blocking: ssh has exited, so all it
        /// wrote is there, and a child that outlived it (a ProxyCommand, the test relay)
        /// may hold the write end open, so end-of-file may never come.
        func drain(_ fd: Int32) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = read(fd, &buffer, buffer.count), count > 0 {
                append(Data(buffer[..<count]))
            }
        }
    }
}
