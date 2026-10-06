import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A stdio MCP server the app runs itself, and a table of the requests waiting for their
/// answers, matched by JSON-RPC `id`.
///
/// The bridge's routes use it (054), and so does the app's own client (#191, #305), which is
/// why it is not behind `Network`: a server project's client runs in the Linux `agentsd`.
///
/// Started with the same scrubbing a runtime launch gets, never the daemon's full
/// environment (security review S5), plus the server's own env; stderr is discarded.
/// Nothing it is given — command, arguments, environment, bodies — is ever logged: a
/// server's environment is where its secrets are (FR-023).
final class MCPStdioProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var waiting: [String: CheckedContinuation<Data?, Never>] = [:]
    private var partial = Data()
    private var dropped = 0
    private var ended = false
    private var endReason = "The server stopped."
    private let name: String
    private let logPrefix: String
    private let log: @Sendable (String) -> Void

    /// `logPrefix` starts each line it logs ("bridge", "mcp client"), with `name` after it.
    init(name: String, command: String, args: [String], env: [String: String], cwd: URL,
         logPrefix: String, log: @escaping @Sendable (String) -> Void) {
        self.name = name
        self.logPrefix = logPrefix
        self.log = log
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command] + args
        process.environment = RuntimeEnvironment.forRuntimes().merging(env) { $1 }
        process.currentDirectoryURL = RuntimeProcess.folderURL(cwd)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty is the end of the pipe, which is otherwise reported again and again.
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.read(data)
        }
        process.terminationHandler = { [weak self] process in
            // `env` says 127 when it found no such command.
            let missing = process.terminationReason == .exit && process.terminationStatus == 127
            self?.end(reason: missing ? "The command was not found." : "The server stopped.")
        }
        do {
            try process.run()
            log("\(logPrefix): \(name) started (pid \(process.processIdentifier))")
        } catch {
            log("\(logPrefix): \(name) could not start")
            ended = true
            endReason = "The server could not be started."
        }
    }

    var isRunning: Bool { lock.withLock { !ended } && process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }
    /// How many requests are waiting for their answers.
    var waitingCount: Int { lock.withLock { waiting.count } }
    /// Why it stopped, once it has.
    var stoppedBecause: String? { lock.withLock { ended ? endReason : nil } }

    /// Write one message; for a request, wait for the answer with the same `id`. Nil for a
    /// notification, which has no answer.
    func send(_ body: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Self.error(id: nil, code: -32700, message: "The request was not JSON.")
        }
        guard let id = message["id"].flatMap(Self.key) else {
            write(body)
            return nil
        }
        let original = message["id"]
        return await withCheckedContinuation { done in
            // Checked and registered together, so a server that stops in between still
            // answers this call.
            let stopped = lock.withLock { () -> String? in
                if ended { return endReason }
                waiting[id] = done
                return nil
            }
            if let stopped {
                done.resume(returning: Self.error(id: original, code: -32000, message: stopped))
            } else {
                write(body)
            }
        }
    }

    /// Stop waiting for the answer to `id` (a caller that timed out): nil goes back to it,
    /// and an answer that comes later is dropped.
    func abandon(_ id: Any) {
        guard let key = Self.key(id), let done = lock.withLock({ waiting.removeValue(forKey: key) }) else { return }
        done.resume(returning: nil)
    }

    func end(reason: String) {
        let pending = lock.withLock { () -> [String: CheckedContinuation<Data?, Never>] in
            if !ended { endReason = reason }
            ended = true
            let pending = waiting
            waiting.removeAll()
            return pending
        }
        output.fileHandleForReading.readabilityHandler = nil
        for (id, done) in pending {
            done.resume(returning: Self.error(idKey: id, code: -32000, message: reason))
        }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private func write(_ body: Data) {
        var line = body
        if line.last != UInt8(ascii: "\n") { line.append(UInt8(ascii: "\n")) }
        try? input.fileHandleForWriting.write(contentsOf: line)
    }

    private func read(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [Data] = lock.withLock {
            partial.append(data)
            var lines: [Data] = []
            while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(partial[partial.startIndex..<newline]))
                partial.removeSubrange(partial.startIndex...newline)
            }
            return lines
        }
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if message["method"] != nil {
            // The server speaking first. A request is told no, so it does not wait forever;
            // a notification is counted and dropped (v1, contracts/mcp-bridge.md).
            if let id = message["id"] {
                write(Self.error(id: id, code: -32601, message: "Not passed on by the app."))
            } else {
                let count = lock.withLock { dropped += 1; return dropped }
                if count == 1 || count % 100 == 0 { log("\(logPrefix): \(name) sent \(count) notification(s) not passed on") }
            }
            return
        }
        guard let id = message["id"].flatMap(Self.key),
              let done = lock.withLock({ waiting.removeValue(forKey: id) }) else { return }
        done.resume(returning: line)
    }

    /// A JSON-RPC id as a key: a number and a string of the same digits are different ids.
    static func key(_ id: Any) -> String? {
        if let number = id as? NSNumber { return "n:\(number)" }
        if let string = id as? String { return "s:\(string)" }
        return nil
    }

    static func error(id: Any?, code: Int, message: String) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(),
                                     "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func error(idKey: String, code: Int, message: String) -> Data {
        let id: Any = idKey.hasPrefix("n:") ? (Int(idKey.dropFirst(2)) ?? 0) as Any : String(idKey.dropFirst(2))
        return error(id: id, code: code, message: message)
    }
}
