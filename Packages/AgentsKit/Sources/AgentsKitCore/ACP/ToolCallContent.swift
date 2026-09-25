import Foundation

/// What a tool call produced.
///
/// Claude and Copilot send a structured diff for an edit — for an edit, the passage
/// that went and the one that came, not the whole file — and Grok sends none (035
/// research R1). What is sent is drawn, nothing is invented, and anything else is kept
/// whole.
public enum ToolCallContent: Codable, Hashable, Sendable {
    case content(ContentBlock)
    case diff(Diff)
    /// Output from a terminal the client is running. The id is ours to look up.
    case terminal(String)
    case unknown(JSONValue)

    public struct Diff: Codable, Hashable, Sendable {
        public var path: String
        public var oldText: String?
        public var newText: String

        public init(path: String, oldText: String?, newText: String) {
            self.path = path
            self.oldText = oldText
            self.newText = newText
        }

        public var fileName: String { URL(filePath: path).lastPathComponent }
    }

    public init(wire: JSONValue) {
        switch wire["type"]?.stringValue {
        case "content":
            self = .content(ContentBlock(wire: wire["content"] ?? wire))
        case "diff":
            guard let path = wire["path"]?.stringValue,
                  let newText = wire["newText"]?.stringValue else { self = .unknown(wire); return }
            self = .diff(Diff(path: path, oldText: wire["oldText"]?.stringValue, newText: newText))
        case "terminal":
            guard let id = wire["terminalId"]?.stringValue else { self = .unknown(wire); return }
            self = .terminal(id)
        default:
            self = .unknown(wire)
        }
    }

    public var wire: JSONValue {
        switch self {
        case .content(let block): return ["type": "content", "content": block.wire]
        case .diff(let diff):
            var object: [String: JSONValue] = ["type": "diff",
                                               "path": .string(diff.path),
                                               "newText": .string(diff.newText)]
            if let oldText = diff.oldText { object["oldText"] = .string(oldText) }
            return .object(object)
        case .terminal(let id): return ["type": "terminal", "terminalId": .string(id)]
        case .unknown(let value): return value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(wire: try JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try wire.encode(to: encoder)
    }
}

/// Where a tool call did its work. The app offers each one and opens it at the line.
public struct ToolCallLocation: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var line: Int?

    public var id: String { line.map { "\(path):\($0)" } ?? path }
    public var fileName: String { URL(filePath: path).lastPathComponent }

    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }

    init?(wire: JSONValue) {
        guard let path = wire["path"]?.stringValue else { return nil }
        self.path = path
        self.line = wire["line"]?.intValue
    }
}
