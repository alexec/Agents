import Foundation
import MCPServerKit
import Testing

/// Answers `echo` with its params, and fails `boom` with something that is not an RPCError.
struct Echo: RPCHandler {
    struct Boom: Error {}
    func handle(method: String, params: JSON?) async throws -> JSON {
        switch method {
        case "echo": return params ?? .null
        case "boom": throw Boom()
        default: throw RPCError.methodNotFound(method)
        }
    }
}

@Suite struct JSONTests {
    @Test func numbersKeepTheirKind() throws {
        let parsed = try JSON.parse(#"{"a":1,"b":1.5,"c":true,"d":null,"e":"x","f":[1,"y"]}"#)
        #expect(parsed["a"] == .int(1))
        #expect(parsed["b"] == .double(1.5))
        #expect(parsed["c"] == .bool(true))
        #expect(parsed["d"] == .null)
        #expect(parsed["e"] == "x")
        #expect(parsed["f"] == [1, "y"])
        #expect(try JSON.parse(parsed.text) == parsed)
    }

    @Test func textIsOneLineWithSlashesAsTheyAre() {
        let json: JSON = ["url": "https://github.com/a/b", "n": 2]
        #expect(json.text == #"{"n":2,"url":"https://github.com/a/b"}"#)
    }
}

@Suite struct SchemaTests {
    let schema = Schema(["repo": .string("r", pattern: (#"^[a-z]+/[a-z]+$"#, "owner/name")),
                         "n": .integer(), "body": .string(maxLength: 3)], required: ["n"])

    @Test func listsAsJSONSchema() {
        #expect(schema.json["type"] == "object")
        #expect(schema.json["required"] == ["n"])
        #expect(schema.json["additionalProperties"] == false)
        #expect(schema.json["properties"]?["repo"]?["pattern"] == #"^[a-z]+/[a-z]+$"#)
        #expect(schema.json["properties"]?["n"]?["type"] == "integer")
    }

    @Test func checksWhatItIsGiven() throws {
        #expect(try schema.check(["n": 1, "repo": "a/b"]) == ["n": 1, "repo": "a/b"])
        #expect(throws: RPCError.invalidParams("missing n")) { try schema.check(nil) }
        #expect(throws: RPCError.invalidParams("arguments must be an object")) { try schema.check([1]) }
        #expect(throws: RPCError.invalidParams("unknown argument x; takes repo, n, body")) { try schema.check(["n": 1, "x": 1]) }
        #expect(throws: RPCError.invalidParams("n must be a positive integer")) { try schema.check(["n": 0]) }
        #expect(throws: RPCError.invalidParams("n must be a positive integer")) { try schema.check(["n": 1.5]) }
        #expect(throws: RPCError.invalidParams("repo must look like owner/name")) { try schema.check(["n": 1, "repo": "A b"]) }
        #expect(throws: RPCError.invalidParams("body is over 3 characters")) { try schema.check(["n": 1, "body": "abcd"]) }
        #expect(throws: RPCError.invalidParams("body must be a string")) { try schema.check(["n": 1, "body": 4]) }
    }
}

@Suite struct PollCursorTests {
    @Test func roundTripsAndRefusesOthers() throws {
        let cursor = PollCursor(since: "2026-10-01T10:00:00.000Z", ids: ["a", "b"])
        #expect(try PollCursor.decode(.string(cursor.encoded)) == cursor)
        #expect(!cursor.encoded.contains("="))
        #expect(throws: RPCError.self) { try PollCursor.decode("%%%") }
        #expect(throws: RPCError.self) { try PollCursor.decode(5) }
    }

    /// A cursor the Node server gave decodes the same: the daemon keeps them across the move (#700).
    @Test func readsTheNodeServersCursors() throws {
        let node = Data(#"{"since":"2026-10-01T10:00:00Z","ids":["x"]}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        #expect(try PollCursor.decode(.string(node)) == PollCursor(since: "2026-10-01T10:00:00.000Z", ids: ["x"]))
    }
}

@Suite struct JSONRPCTests {
    func answer(_ line: String) async -> JSON? {
        await JSONRPC.answer(line: line, with: Echo(), name: "test").flatMap { try? JSON.parse($0) }
    }

    @Test func answersRequestsAndNotNotifications() async {
        #expect(await answer(#"{"jsonrpc":"2.0","id":7,"method":"echo","params":{"a":1}}"#) == ["jsonrpc": "2.0", "id": 7, "result": ["a": 1]])
        #expect(await answer(#"{"jsonrpc":"2.0","method":"echo"}"#) == nil)
        #expect(await answer(#"{"jsonrpc":"2.0","id":1,"result":{}}"#) == nil, "a client's response")
        #expect(await answer("   ") == nil)
    }

    @Test func errors() async {
        #expect(await answer("not json")?["error"]?["code"] == -32700)
        #expect(await answer(#"{"id":1,"method":"echo"}"#)?["error"]?["code"] == -32600)
        #expect(await answer(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#)?["error"]?["code"] == -32601)
        #expect(await answer(#"{"jsonrpc":"2.0","id":1,"method":"boom"}"#)?["error"]?["code"] == -32603)
        let big = #"{"jsonrpc":"2.0","id":1,"method":"echo","params":""# + String(repeating: "x", count: JSONRPC.maxLine) + #""}"#
        #expect(await answer(big)?["error"]?["message"] == "message too large")
    }

    @Test func aBatchIsAnsweredInOrderWithoutItsNotifications() async {
        let batch = await answer(#"[{"jsonrpc":"2.0","id":1,"method":"echo","params":1},{"jsonrpc":"2.0","method":"echo"},{"jsonrpc":"2.0","id":2,"method":"echo","params":2}]"#)
        #expect(batch?.array?.compactMap { $0["result"] } == [1, 2])
    }
}

@Suite struct StdioTransportTests {
    /// A line that is not JSON is a parse error, a notification has no answer, and the server goes on.
    @Test func servesLinesUntilInputCloses() async throws {
        let input = Pipe(), output = Pipe()
        let served = Task {
            await StdioTransport.serve(Echo(), name: "test", input: input.fileHandleForReading, output: output.fileHandleForWriting)
            try? output.fileHandleForWriting.close()
        }
        input.fileHandleForWriting.write(Data("not json\n".utf8))
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","method":"echo"}"#.utf8 + [10]))
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"echo","params":"hi"}"#.utf8 + [13, 10]))
        try input.fileHandleForWriting.close()
        await served.value
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
        #expect(lines.count == 2)
        #expect(lines.contains { $0["error"]?["code"] == -32700 })
        #expect(lines.contains { $0["result"] == "hi" })
    }
}

@Suite struct ChildProcessTests {
    @Test func runsACommandOnPath() async {
        let echoed = await ChildProcess.run(command: "echo", ["hello"])
        #expect(echoed.status == 0)
        #expect(echoed.text == "hello\n")
        let missing = await ChildProcess.run(command: "no-such-command-\(UUID().uuidString)", [])
        #expect(missing.status == 127)
    }
}
