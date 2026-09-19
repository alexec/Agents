import Foundation
import Testing
@testable import AgentsKit

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
