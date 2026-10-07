import Foundation

/// Which server's tool an agent called, and what it answered, read from the runtime's ACP
/// tool call by its shape (#191).
///
/// The #186 probe found that no runtime passes a tool's `_meta` on, so the app cannot ask
/// the runtime whether a call has a view. It can tell which server and tool were called,
/// and get some of the result, from how each runtime describes the call. Read by shape,
/// never by runtime name (constitution II):
///
/// | Shape | Server and tool | Result |
/// |---|---|---|
/// | `rawInput.server` + `rawInput.tool` | exactly | `rawOutput.result`, whole |
/// | a name or title `mcp__<s>__<t>` (or `mcp.<s>.<t>`) | exactly | `rawOutput`, a JSON string of `structuredContent` |
/// | a title `<s>-<t>` or `<s>_<t>` | the longest server name that prefixes it | `rawOutput.structuredContent` + `contents` |
/// | text only | as above | none usable |
///
/// Nothing here is a guess: a name is only ever resolved against the servers the caller
/// names, and the caller checks the tool against that server's own catalog.
public enum ACPToolShape {
    /// One reading of a call: which server and tool, with what.
    public struct Candidate: Equatable, Sendable {
        public var server: String
        public var tool: String
        public var arguments: JSONValue?
        /// The runtime named the server and tool outright, so the call can be shown as it
        /// starts. A joined title is only trusted once its result is in.
        public var exact: Bool

        public init(server: String, tool: String, arguments: JSONValue?, exact: Bool) {
            self.server = server
            self.tool = tool
            self.arguments = arguments
            self.exact = exact
        }
    }

    /// What a call answered, as a `CallToolResult`.
    public struct Result: Equatable, Sendable {
        public var value: JSONValue
        /// It came with `structuredContent`, or whole: a view has something to draw from.
        /// A text-only result is not drawn inline (Q7): its view can still be pinned.
        public var drawable: Bool
    }

    /// Every reading of `call` against `servers`, best first: an exact naming, then the
    /// longest server name a joined title starts with. Empty when no server fits.
    public static func candidates(_ call: ToolCall, servers: [String]) -> [Candidate] {
        let known = Set(servers)
        let input = call.rawInput
        if let server = input?["server"]?.stringValue, let tool = input?["tool"]?.stringValue {
            guard known.contains(server) else { return [] }
            return [Candidate(server: server, tool: tool, arguments: input?["arguments"], exact: true)]
        }
        let byLength = known.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        var found: [Candidate] = []
        for name in [call.name, call.title].compactMap({ $0 }) {
            for (prefix, separator) in [("mcp__", "__"), ("mcp.", ".")] where name.hasPrefix(prefix) {
                let rest = name.dropFirst(prefix.count)
                for server in byLength where rest.hasPrefix(server + separator) {
                    let tool = String(rest.dropFirst(server.count + separator.count))
                    guard !tool.isEmpty else { continue }
                    found.append(Candidate(server: server, tool: tool, arguments: input, exact: true))
                }
            }
        }
        if !found.isEmpty { return unique(found) }
        for server in byLength {
            for separator in ["-", "_"] where call.title.hasPrefix(server + separator) {
                let tool = String(call.title.dropFirst(server.count + separator.count))
                guard !tool.isEmpty else { continue }
                found.append(Candidate(server: server, tool: tool, arguments: input, exact: false))
            }
        }
        return unique(found)
    }

    /// The result of a finished call, from whichever shape the runtime gave it in. Nil
    /// while the call runs, or when it gave nothing usable.
    public static func result(_ call: ToolCall) -> Result? {
        guard call.status == "completed" || call.status == "failed" else { return nil }
        let failed = call.status == "failed"
        guard let output = call.rawOutput, !output.isNull else {
            return failed ? Result(value: errorResult(call.printedText), drawable: false) : nil
        }
        // Whole: the server's own `CallToolResult`.
        if let whole = output["result"], whole.objectValue != nil {
            return Result(value: whole, drawable: true)
        }
        if output["result"]?.isNull == true, let error = output["error"], !error.isNull {
            return Result(value: errorResult(error.stringValue ?? error["message"]?.stringValue ?? ""), drawable: false)
        }
        // A JSON string: `structuredContent`, standing in for the text.
        if let text = output.stringValue {
            if let parsed = try? JSONValue.parse(Data(text.utf8)), parsed.objectValue != nil {
                return Result(value: ["content": [], "structuredContent": parsed], drawable: true)
            }
            return Result(value: textResult(text, isError: failed), drawable: false)
        }
        if let structured = output["structuredContent"], structured.objectValue != nil {
            let blocks = output["contents"]?.arrayValue ?? output["content"]?.arrayValue ?? []
            return Result(value: ["content": .array(blocks), "structuredContent": structured], drawable: true)
        }
        if let blocks = output["content"]?.arrayValue {
            return Result(value: ["content": .array(blocks)], drawable: false)
        }
        if let text = output["output"]?.stringValue {
            return Result(value: textResult(text, isError: failed), drawable: false)
        }
        return failed ? Result(value: errorResult(call.printedText), drawable: false) : nil
    }

    private static func textResult(_ text: String, isError: Bool) -> JSONValue {
        var value: JSONValue = ["content": [["type": "text", "text": .string(text)]]]
        if isError, case .object(var fields) = value {
            fields["isError"] = true
            value = .object(fields)
        }
        return value
    }

    private static func errorResult(_ text: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": true]
    }

    private static func unique(_ list: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.server + "\u{0}" + $0.tool).inserted }
    }
}
