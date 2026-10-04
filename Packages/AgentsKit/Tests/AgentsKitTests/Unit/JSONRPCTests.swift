import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("JSON-RPC")
struct JSONRPCTests {
    @Test func decodesTheFourKindsOfMessage() throws {
        let request = try JSONRPCCodec.decode(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#)
        guard case .request(let id, let method, let params) = request else { Issue.record("not a request"); return }
        #expect(id == .number(1))
        #expect(method == "initialize")
        #expect(params?["protocolVersion"]?.intValue == 1)

        let notification = try JSONRPCCodec.decode(line: #"{"jsonrpc":"2.0","method":"session/update","params":{}}"#)
        guard case .notification(let m, _) = notification else { Issue.record("not a notification"); return }
        #expect(m == "session/update")

        let success = try JSONRPCCodec.decode(line: #"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"abc"}}"#)
        guard case .success(_, let result) = success else { Issue.record("not a result"); return }
        #expect(result["sessionId"]?.stringValue == "abc")

        let failure = try JSONRPCCodec.decode(line: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Method not found"}}"#)
        guard case .failure(_, let error) = failure else { Issue.record("not an error"); return }
        #expect(error.isMethodNotFound)
    }

    @Test func roundTripsThroughTheCodec() throws {
        let message = JSONRPCMessage.request(id: .string("x"), method: "session/prompt",
                                             params: ["sessionId": "s", "prompt": [["type": "text", "text": "hi"]]])
        let decoded = try JSONRPCCodec.decode(line: try JSONRPCCodec.encode(message))
        guard case .request(let id, let method, let params) = decoded else { Issue.record("wrong kind"); return }
        #expect(id == .string("x"))
        #expect(method == "session/prompt")
        #expect(params?["prompt"]?.arrayValue?.first?["text"]?.stringValue == "hi")
    }

    @Test func callsAndRepliesAcrossAPair() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let client = JSONRPCConnection(transport: mine)
        let server = JSONRPCConnection(transport: theirs) { method, params in
            method == "echo" ? .success(params ?? .null) : .failure(.methodNotFound(method))
        }
        await client.start()
        await server.start()

        let result = try await client.call("echo", ["said": "hello"])
        #expect(result["said"]?.stringValue == "hello")

        await #expect(throws: JSONRPCError.self) {
            try await client.call("nonesuch")
        }
        await client.close()
        await server.close()
    }

    @Test func aMalformedLineDoesNotEndTheConnection() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let client = JSONRPCConnection(transport: mine)
        let server = JSONRPCConnection(transport: theirs) { _, _ in .success("fine") }
        await client.start()
        await server.start()

        try theirs.write(line: "{ this is not json")
        try theirs.write(line: "")
        let result = try await client.call("anything")
        #expect(result.stringValue == "fine")
        #expect(await client.malformedLines.count == 1)
        await client.close()
        await server.close()
    }

    @Test func slowIncomingRequestsDoNotBlockTheConnection() async throws {
        // The permission question is answered by a person and can take hours. Nothing
        // else on the connection may wait for it.
        let (mine, theirs) = PairedTransport.pair()
        let client = JSONRPCConnection(transport: mine) { method, _ in
            if method == "slow" {
                try? await Task.sleep(for: .milliseconds(400))
                return .success("eventually")
            }
            return .success("at once")
        }
        let server = JSONRPCConnection(transport: theirs)
        await client.start()
        await server.start()

        async let slow = server.call("slow")
        try await Task.sleep(for: .milliseconds(50))
        let quick = try await server.call("quick")
        #expect(quick.stringValue == "at once")
        let slowResult = try await slow
        #expect(slowResult.stringValue == "eventually")
        await client.close()
        await server.close()
    }

    @Test func closingFailsEveryCallStillWaiting() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let client = JSONRPCConnection(transport: mine)
        let server = JSONRPCConnection(transport: theirs) { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return .success(.null)
        }
        await client.start()
        await server.start()

        let pending = Task { try await client.call("never") }
        try await Task.sleep(for: .milliseconds(50))
        await client.close()
        await #expect(throws: (any Error).self) { try await pending.value }
        await server.close()
    }
}

/// What a connection keeps of what it could not read, and how it answers for a line the
/// transport cut (#209).
@Suite("JSON-RPC lines it cannot read", .timeLimit(.minutes(1)))
struct JSONRPCUnreadableLineTests {
    /// A runtime printing banners to stdout prints them for as long as it lives.
    @Test func onlyTheLastFewMalformedLinesAreKept() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let client = JSONRPCConnection(transport: mine)
        let server = JSONRPCConnection(transport: theirs) { _, _ in .success("fine") }
        await client.start()
        await server.start()

        for i in 0..<100 { try theirs.write(line: "banner \(i) " + String(repeating: "=", count: 5_000)) }
        #expect(try await client.call("anything").stringValue == "fine")
        #expect(await client.malformedCount == 100)
        let kept = await client.malformedLines
        #expect(kept.count == JSONRPCConnection.malformedKept)
        #expect(kept.last?.hasPrefix("banner 99 ") == true)
        #expect(kept.allSatisfy { $0.utf8.count <= JSONRPCConnection.malformedLineKept })
        await client.close()
        await server.close()
    }

    /// A reply too long to read fails the call it answers, rather than leaving it waiting.
    @Test func aCutReplyFailsItsCall() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let client = JSONRPCConnection(transport: mine)
        await client.start()
        let call = Task { try await client.call("session/load") }
        var requests = theirs.lines().makeAsyncIterator()
        let request = try #require(try await requests.next())
        let id = try #require(try JSONRPCCodec.decode(line: request).id)
        guard case .number(let number) = id else { Issue.record("a numbered call"); return }
        try theirs.write(line: LineSplitter.cut(start: Array(#"{"jsonrpc":"2.0","id":\#(number),"result":{"#.utf8),
                                                bytes: 40 << 20, limit: 16 << 20))
        await #expect(throws: JSONRPCError.self) { try await call.value }
        await client.close()
    }

    /// A request too long to read is refused, so the far end is not left waiting either.
    @Test func aCutRequestIsRefused() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let client = JSONRPCConnection(transport: mine) { _, _ in .success("never asked") }
        await client.start()
        try theirs.write(line: LineSplitter.cut(
            start: Array(#"{"jsonrpc":"2.0","id":"q1","method":"fs/write_text_file","params":{"id":5"#.utf8),
            bytes: 40 << 20, limit: 16 << 20))
        var replies = theirs.lines().makeAsyncIterator()
        let reply = try JSONRPCCodec.decode(line: try #require(try await replies.next()))
        guard case .failure(let id, _) = reply else { Issue.record("refused: \(reply)"); return }
        #expect(id == .string("q1"))
        await client.close()
    }

    /// Anything else is a notification, passed on as the cut, for whoever reads them.
    @Test func aCutNotificationIsPassedOn() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let client = JSONRPCConnection(transport: mine)
        await client.start()
        try theirs.write(line: LineSplitter.cut(
            start: Array(#"{"jsonrpc":"2.0","method":"session/update","params":{"id":5"#.utf8),
            bytes: 40 << 20, limit: 16 << 20))
        var notifications = client.incomingNotifications().makeAsyncIterator()
        let notification = try #require(await notifications.next())
        #expect(notification.method == LineSplitter.cutMethod)
        #expect(notification.params?["bytes"]?.intValue == 40 << 20)
        await client.close()
    }
}
