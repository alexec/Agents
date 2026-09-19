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
        /// What a read took out of the pipe, and whether that was the end of it.
        struct Drained {
            var text: String
            var atEOF: Bool
        }

        let process: Process
        let pipe: Pipe
        /// Where a chunk goes as it is read. Called on whichever thread read it, in
        /// the order the bytes came out of the pipe.
        let onChunk: @Sendable (String) -> Void

        // The exit and the waiters belong to the actor and are only touched there.
        var exitCode: Int32?
        var signal: String?
        var waiters: [CheckedContinuation<Void, Never>] = []

        /// Held across read-then-append, so the two things that read the pipe — the
        /// readability source and the drain that runs when the process exits — cannot
        /// interleave a command's output with itself.
        private let readLock = NSLock()
        /// Guards the buffer alone. Separate from `readLock` so a reader that is busy
        /// handing a chunk to the windows never holds up an agent asking for output.
        /// Always taken inside `readLock`, never the other way round.
        private let bufferLock = NSLock()
        private var buffer = ""
        private var wasTruncated = false

        init(process: Process, pipe: Pipe, onChunk: @escaping @Sendable (String) -> Void = { _ in }) {
            self.process = process
            self.pipe = pipe
            self.onChunk = onChunk
        }

        var output: String { bufferLock.withLock { buffer } }
        var truncated: Bool { bufferLock.withLock { wasTruncated } }

        func append(_ text: String) {
            readLock.withLock { store(text) }
        }

        /// Everything the pipe has right now, without waiting for anything.
        ///
        /// The fd is non-blocking, so this never waits on a write end that a
        /// backgrounded grandchild may still be holding open: it takes what is there
        /// and says whether it saw the end. Reading and storing happen together under
        /// the lock, so two readers cannot put their chunks in out of order.
        @discardableResult
        func drain() -> Drained {
            readLock.withLock {
                let fd = pipe.fileHandleForReading.fileDescriptor
                guard fd >= 0 else { return Drained(text: "", atEOF: true) }
                var bytes = Data()
                var atEOF = false
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                loop: while true {
                    let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    switch count {
                    case let n where n > 0:
                        bytes.append(contentsOf: chunk[0 ..< n])
                    case 0:
                        atEOF = true
                        break loop
                    default:
                        // EAGAIN is the ordinary end of a drain: the pipe is empty but
                        // still open. Anything else is a pipe we cannot read any more.
                        if errno == EINTR { continue }
                        if errno != EAGAIN && errno != EWOULDBLOCK { atEOF = true }
                        break loop
                    }
                }
                guard !bytes.isEmpty else { return Drained(text: "", atEOF: atEOF) }
                let text = String(decoding: bytes, as: UTF8.self)
                store(text)
                return Drained(text: text, atEOF: atEOF)
            }
        }

        /// Call with `readLock` held.
        private func store(_ text: String) {
            bufferLock.withLock {
                buffer += text
                if buffer.utf8.count > TerminalService.outputByteLimit {
                    buffer = String(buffer.suffix(TerminalService.outputByteLimit / 2))
                    wasTruncated = true
                }
            }
            onChunk(text)
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
        let terminal = Terminal(process: process, pipe: pipe, onChunk: onChunk(for: id))
        terminals[id] = terminal

        // Non-blocking, so a drain can take what is in the pipe without ever waiting.
        let readFD = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(readFD, F_GETFL)
        if flags >= 0 { _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK) }

        pipe.fileHandleForReading.readabilityHandler = { [weak terminal] handle in
            guard let terminal else {
                handle.readabilityHandler = nil
                return
            }
            // Nothing to read is the end of the pipe, and the handler retires itself
            // there. The exit arriving first used to cancel this handler with the
            // command's bytes still sitting unread in the buffer, which is how a
            // command that printed something came back empty.
            if terminal.drain().atEOF { handle.readabilityHandler = nil }
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

    /// Bound once per terminal so the reader can hand a chunk on without hopping onto
    /// the actor, which is what put chunks out of order and let the last one arrive
    /// after the agent had already asked for the output.
    private nonisolated func onChunk(for id: String) -> @Sendable (String) -> Void {
        let onOutput = onOutput
        return { text in onOutput(id, text) }
    }

    private func finished(_ id: String, code: Int32, signal: String?) {
        guard let terminal = terminals[id] else { return }
        // Read what is left before anything is told the command is over. The exit and
        // the last of the output race each other, and a waiter woken first would go on
        // to read a buffer those bytes had not landed in yet.
        let drained = terminal.drain()
        terminal.exitCode = code
        terminal.signal = signal
        // Only at the end of the pipe: something the command left running behind it
        // still holds the write end, and its output is still worth having.
        if drained.atEOF { terminal.pipe.fileHandleForReading.readabilityHandler = nil }
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
        // Letting go is the last chance this output has to reach the windows, so take
        // what is in the pipe before the handler that would have read it is gone.
        terminal.drain()
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
            terminals[id] = Terminal(process: Process(), pipe: Pipe(), onChunk: onChunk(for: id))
        }
        terminals[id]?.append(text)
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
