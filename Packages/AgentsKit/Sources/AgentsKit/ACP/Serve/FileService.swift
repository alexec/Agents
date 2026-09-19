import Foundation

/// Reading and writing files on an agent's behalf.
///
/// Only Grok asks for this today, and only once the app says it can: with the
/// capability off it does its own file IO and we see nothing. That is the whole reason
/// to serve it, and it is also why every path goes through `FolderScope` first.
public struct FileService: Sendable {
    public enum ReadOutcome: Sendable {
        case read(String)
        case refused(String)
        case failed(String)

        var record: ServedRequest.Outcome {
            switch self {
            case .read: return .served
            case .refused(let reason): return .refused(reason: reason)
            case .failed(let message): return .failed(message: message)
            }
        }
    }

    public enum WriteOutcome: Sendable {
        case written
        case failed(String)

        var record: ServedRequest.Outcome {
            switch self {
            case .written: return .served
            case .failed(let message): return .failed(message: message)
            }
        }
    }

    let scope: FolderScope

    public init(scope: FolderScope) {
        self.scope = scope
    }

    public func read(path: String, line: Int?, limit: Int?) -> ReadOutcome {
        guard scope.allows(path) else { return .refused(scope.refusal(for: path)) }
        guard let contents = try? String(contentsOf: URL(filePath: path), encoding: .utf8) else {
            return .failed("There is nothing readable at \(path)")
        }
        guard line != nil || limit != nil else { return .read(contents) }
        // `line` is one-based in the protocol, and a limit with no line starts at the top.
        let lines = contents.components(separatedBy: "\n")
        let start = max(0, (line ?? 1) - 1)
        guard start < lines.count else { return .read("") }
        let end = limit.map { min(lines.count, start + $0) } ?? lines.count
        return .read(lines[start..<end].joined(separator: "\n"))
    }

    /// Why a write cannot happen at all, before anybody is asked about it.
    public func refusal(forWriting path: String) -> String? {
        scope.allows(path) ? nil : scope.refusal(for: path)
    }

    public func write(path: String, contents: String) -> WriteOutcome {
        guard scope.allows(path) else { return .failed(scope.refusal(for: path)) }
        let url = URL(filePath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Atomically, so a write that fails half way leaves the old file alone.
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return .written
        } catch {
            return .failed("Could not write \(path): \(error.localizedDescription)")
        }
    }

    /// The question the user is asked before a write, with the change in it.
    public func writeToolCall(path: String, contents: String) -> ToolCall {
        let existing = try? String(contentsOf: URL(filePath: path), encoding: .utf8)
        return ToolCall(toolCallID: nil,
                        title: "Write \(URL(filePath: path).lastPathComponent)",
                        kind: "edit",
                        status: "pending",
                        content: [.diff(.init(path: path, oldText: existing, newText: contents))],
                        locations: [ToolCallLocation(path: path)])
    }
}
