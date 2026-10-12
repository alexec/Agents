import Foundation
import Synchronization

/// MCP's stdio transport: newline-delimited JSON-RPC on stdin and stdout. Each line is
/// answered as it finishes, so a slow tool does not hold up a poll; answers are written
/// whole, one at a time. Logging goes to stderr.
public enum StdioTransport {
    /// Serves `handler` on stdin and stdout until stdin closes.
    public static func serve(_ handler: some RPCHandler, name: String) async {
        await serve(handler, name: name, input: .standardInput, output: .standardOutput)
    }

    /// Serves `handler` on `input` and `output` until `input` closes, then waits for the
    /// answers still being worked out.
    public static func serve(_ handler: some RPCHandler, name: String, input: FileHandle, output: FileHandle) async {
        let writer = Writer(output)
        await withTaskGroup(of: Void.self) { group in
            for await line in lines(of: input) {
                group.addTask {
                    if let answer = await JSONRPC.answer(line: line, with: handler, name: name) {
                        writer.write(answer)
                    }
                }
            }
        }
    }

    /// The lines of `input`, read on a thread of their own so a blocking read holds no task.
    /// A line over `JSONRPC.maxLine` is passed on as it is, for the answer to refuse.
    public static func lines(of input: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                var pending = Data()
                while true {
                    let chunk = input.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        var line = pending[pending.startIndex..<newline]
                        if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                        continuation.yield(String(decoding: line, as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                continuation.finish()
            }
            thread.name = "stdin"
            thread.start()
        }
    }

    final class Writer: Sendable {
        let output: Mutex<FileHandle>
        init(_ output: FileHandle) { self.output = Mutex(output) }
        func write(_ line: String) {
            output.withLock { $0.write(Data((line + "\n").utf8)) }
        }
    }
}
