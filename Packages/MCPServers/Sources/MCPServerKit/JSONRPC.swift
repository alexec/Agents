import Foundation

/// A JSON-RPC error answer: its code, message and optional data.
public struct RPCError: Error, Sendable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSON?

    public init(_ code: Int, _ message: String, data: JSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func invalidParams(_ message: String) -> RPCError { RPCError(-32602, message) }
    public static func internalError(_ message: String) -> RPCError { RPCError(-32603, message) }
    public static func methodNotFound(_ method: String) -> RPCError { RPCError(-32601, "no method \(method)") }

    var json: JSON {
        var o: [String: JSON] = ["code": .int(code), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}

/// What answers a request: a method and its params in, a result out, or an error thrown.
/// Anything thrown that is not an `RPCError` is answered as -32603 and logged to stderr.
public protocol RPCHandler: Sendable {
    func handle(method: String, params: JSON?) async throws -> JSON
}

/// JSON-RPC 2.0 over one line of text, as MCP's stdio transport sends it: a request, a
/// notification (answered with nothing), or a batch of them.
public enum JSONRPC {
    /// Lines over this are refused unread, as the Node servers did.
    public static let maxLine = 1024 * 1024

    /// The line to write back for `line`, or nil when there is nothing to answer.
    public static func answer(line: String, with handler: some RPCHandler, name: String) async -> String? {
        guard !line.allSatisfy(\.isWhitespace) else { return nil }
        if line.utf8.count > maxLine {
            return failure(id: .null, RPCError(-32600, "message too large")).text
        }
        guard let parsed = try? JSON.parse(line) else {
            return failure(id: .null, RPCError(-32700, "parse error")).text
        }
        if case .array(let batch) = parsed {
            let answers = await withTaskGroup(of: (Int, JSON?).self) { group in
                for (i, message) in batch.enumerated() {
                    group.addTask { (i, await answer(message: message, with: handler, name: name)) }
                }
                var out = [(Int, JSON)]()
                for await (i, a) in group { if let a { out.append((i, a)) } }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            return answers.isEmpty ? nil : JSON.array(answers).text
        }
        return await answer(message: parsed, with: handler, name: name)?.text
    }

    /// The answer to one message, or nil for a notification or a client's response.
    public static func answer(message: JSON, with handler: some RPCHandler, name: String) async -> JSON? {
        guard message["jsonrpc"]?.string == "2.0", let method = message["method"]?.string else {
            // A response from the client is not answered; anything else is not a request.
            let isResponse = message["id"] != nil && message["method"] == nil
                && (message["result"] != nil || message["error"] != nil)
            return isResponse ? nil : failure(id: message["id"] ?? .null, RPCError(-32600, "not a JSON-RPC 2.0 request"))
        }
        let id = message["id"]
        do {
            let result = try await handler.handle(method: method, params: message["params"])
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch {
            guard let id else { return nil }
            if let error = error as? RPCError { return failure(id: id, error) }
            log("\(name): \(method) failed: \(error)")
            return failure(id: id, .internalError("\(error)"))
        }
    }

    static func failure(id: JSON, _ error: RPCError) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": error.json]
    }
}

/// A line to stderr, where a stdio server's logging goes.
public func log(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
