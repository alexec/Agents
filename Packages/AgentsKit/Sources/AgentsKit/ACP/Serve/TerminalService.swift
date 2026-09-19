import Foundation

/// Commands the app runs on an agent's behalf.
///
/// Every one of them is a child of the daemon, so it dies with the agent that asked for
/// it and never outlives the daemon. Output is kept to a cap with truncation flagged,
/// because a command that prints for an hour is an ordinary thing for an agent to run.
public actor TerminalService {
    public struct Failure: Error, Sendable {
        public var message: String
    }

    /// How much of a command's output is kept. Beyond this the oldest bytes go and the
    /// output is flagged as truncated, which is what the protocol has the flag for.
    public static let outputByteLimit = 256 * 1024

    private let scope: FolderScope
    private let defaultCWD: URL
    private let onOutput: @Sendable (String, String) -> Void
    private var terminals: [String: Terminal] = [:]

    public init(scope: FolderScope,
                defaultCWD: URL,
                onOutput: @escaping @Sendable (String, String) -> Void = { _, _ in }) {
        self.scope = scope
        self.defaultCWD = defaultCWD
        self.onOutput = onOutput
    }

    private final class Terminal: @unchecked Sendable {
        let process: Process
        let pipe: Pipe
        var output = ""
        var truncated = false
        var exitCode: Int32?
        var signal: String?
        var waiters: [CheckedContinuation<Void, Never>] = []

        init(process: Process, pipe: Pipe) {
            self.process = process
            self.pipe = pipe
        }
    }

    public func create(command: String, args: [String], cwd: String?, env: JSONValue?) async throws -> String {
        let workingDirectory = cwd.map { URL(filePath: $0) } ?? defaultCWD
        guard scope.allows(workingDirectory.path) else {
            throw Failure(message: scope.refusal(for: workingDirectory.path))
        }
        guard !command.isEmpty else { throw Failure(message: "No command to run") }

        let id = UUID().uuidString
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // Through a shell on purpose: agents send things like `ls -la | head`, and a
        // shell is what they expect to be running in.
        let line = ([command] + args).joined(separator: " ")
        process.arguments = ["-lc", line]
        process.currentDirectoryURL = workingDirectory
        var environment = LoginShellPath.environment()
        for entry in env?.arrayValue ?? [] {
            if let name = entry["name"]?.stringValue, let value = entry["value"]?.stringValue {
                environment[name] = value
            }
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let terminal = Terminal(process: process, pipe: pipe)
        terminals[id] = terminal

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.append(text, to: id) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.finished(id, code: process.terminationStatus,
                                        signal: process.terminationReason == .uncaughtSignal ? "killed" : nil) }
        }
        do {
            try process.run()
        } catch {
            terminals.removeValue(forKey: id)
            throw Failure(message: "Could not run \(command): \(error.localizedDescription)")
        }
        return id
    }

    private func append(_ text: String, to id: String) {
        guard let terminal = terminals[id] else { return }
        terminal.output += text
        if terminal.output.utf8.count > Self.outputByteLimit {
            terminal.output = String(terminal.output.suffix(Self.outputByteLimit / 2))
            terminal.truncated = true
        }
        onOutput(id, text)
    }

    private func finished(_ id: String, code: Int32, signal: String?) {
        guard let terminal = terminals[id] else { return }
        terminal.exitCode = code
        terminal.signal = signal
        terminal.pipe.fileHandleForReading.readabilityHandler = nil
        for waiter in terminal.waiters { waiter.resume() }
        terminal.waiters = []
    }

    public func output(id: String) -> JSONValue {
        guard let terminal = terminals[id] else { return ["output": "", "truncated": false] }
        var result: [String: JSONValue] = ["output": .string(terminal.output),
                                           "truncated": .bool(terminal.truncated)]
        if let code = terminal.exitCode {
            result["exitStatus"] = exitStatus(code: code, signal: terminal.signal)
        }
        return .object(result)
    }

    public func waitForExit(id: String) async -> JSONValue {
        guard let terminal = terminals[id] else { return exitStatus(code: 0, signal: nil) }
        if terminal.exitCode == nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                terminal.waiters.append(continuation)
            }
        }
        return exitStatus(code: terminal.exitCode ?? 0, signal: terminal.signal)
    }

    public func release(id: String) {
        guard let terminal = terminals.removeValue(forKey: id) else { return }
        terminal.pipe.fileHandleForReading.readabilityHandler = nil
        if terminal.process.isRunning { terminal.process.terminate() }
        for waiter in terminal.waiters { waiter.resume() }
        terminal.waiters = []
    }

    public func kill(id: String) {
        guard let terminal = terminals[id] else { return }
        if terminal.process.isRunning { terminal.process.terminate() }
    }

    /// Everything this agent is running, stopped. Called when the agent stops and when
    /// the daemon exits, so nothing we started outlives what asked for it.
    public func killAll() {
        for id in terminals.keys { release(id: id) }
        terminals.removeAll()
    }

    /// Feeds the ring buffer directly, so the cap can be tested without running a
    /// command for long enough to produce a megabyte.
    func appendForTesting(_ text: String, to id: String) {
        if terminals[id] == nil {
            terminals[id] = Terminal(process: Process(), pipe: Pipe())
        }
        append(text, to: id)
    }

    public var runningCount: Int {
        terminals.values.filter { $0.process.isRunning }.count
    }

    private func exitStatus(code: Int32, signal: String?) -> JSONValue {
        var status: [String: JSONValue] = ["exitCode": .int(Int(code))]
        if let signal { status["signal"] = .string(signal) }
        return .object(status)
    }
}
