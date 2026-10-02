import Foundation
import Testing
@testable import AgentsKitCore

/// A failure the far end could not tie to a request, and lines nobody could read (#93):
/// each ends in an answer, never in a caller waiting for good.
@Suite("Failures with no id", .timeLimit(.minutes(1)))
struct IdlessFailureTests {
    /// A far end that answers every call with `{}`, except `refused`, which it answers
    /// as a server does a request it could not parse: an error with `id: null`.
    final class FarEnd: DaemonLink, @unchecked Sendable {
        let refused: String
        /// Wraps every reply for the control plane's own route, as `agents-control` does.
        let wrapped: Bool
        init(refusing refused: String, wrapped: Bool = false) {
            self.refused = refused
            self.wrapped = wrapped
        }

        func transport() async throws -> any LineTransport {
            let (near, far) = PairedTransport.pair()
            let refused = refused, wrapped = wrapped
            _ = Task {
                for try await line in far.lines() {
                    let message = wrapped ? String(line.dropFirst(5).dropLast()) : line
                    guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                          let id = object["id"] as? Int else { continue }
                    let reply = object["method"] as? String == refused
                        ? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
                        : #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#
                    try? far.write(line: wrapped ? ControlWire.wrap(host: nil, message: reply) : reply)
                }
            }
            return near
        }

        func start() async throws {}
    }

    @Test func everyCallInFlightIsFailedWithTheError() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let connection = JSONRPCConnection(transport: mine)
        await connection.start()
        // Two calls in flight, then one failure nobody can be tied to.
        let first = Task { try await connection.call("one") }
        let second = Task { try await connection.call("two") }
        var seen = 0
        for try await _ in theirs.lines() {
            seen += 1
            if seen == 2 { break }
        }
        try theirs.write(line: #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#)
        for outcome in [await first.result, await second.result] {
            guard case .failure(let error as JSONRPCError) = outcome else {
                Issue.record("expected the parse error, got \(outcome)")
                continue
            }
            #expect(error.code == JSONRPCError.parseError)
        }
        // The connection itself is not ended by it.
        #expect(!connection.isClosed)
        await connection.close()
    }

    @Test func aDaemonClientsCallIsAnsweredNotLeftWaiting() async throws {
        let client = DaemonClient(link: FarEnd(refusing: DaemonAPI.Method.agentsList))
        try await client.connect(startIfNeeded: false)
        await #expect(throws: JSONRPCError.self) {
            try await client.call(DaemonAPI.Method.agentsList)
        }
        // The next call still goes through.
        _ = try await client.call(DaemonAPI.Method.projectsList)
        #expect(await client.isConnected)
    }

    @Test func throughAControlLinkTheFailureReachesItsCaller() async throws {
        let far = FarEnd(refusing: DaemonAPI.Method.hostsList, wrapped: true)
        let link = ControlLink { try await far.transport() }
        let client = DaemonClient(link: link.controlLink)
        try await client.connect(startIfNeeded: false)
        await #expect(throws: JSONRPCError.self) {
            try await client.call(DaemonAPI.Method.hostsList)
        }
    }

    @Test func aControlLinkCountsAFrameItCannotRead() async throws {
        let (near, far) = PairedTransport.pair()
        let link = ControlLink { near }
        let client = DaemonClient(link: link.controlLink)
        let answering = Task {
            for try await line in far.lines() {
                let message = String(line.dropFirst(5).dropLast())
                guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                      let id = object["id"] as? Int else { continue }
                try? far.write(line: ControlWire.wrap(host: nil, message: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#))
            }
        }
        try await client.connect(startIfNeeded: false)
        try far.write(line: "{ not a frame")
        await eventually("the frame was counted") { link.unreadableFrameCount == 1 }
        answering.cancel()
    }
}

@Suite("The router answers what it cannot read (#93)")
struct UnreadableClientLineTests {
    let home = HostID(rawValue: "mac")

    /// The router reads its clients weakly, so each test holds it to the end.
    private func connected() async -> (ControlRouter, FakeControlClient) {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachClient(client(.operator), transport: ours)
        return (router, FakeControlClient(transport: theirs))
    }

    private func parseError(in message: String) -> Bool {
        guard case .failure(nil, let error)? = try? JSONRPCCodec.decode(line: message) else { return false }
        return error.code == JSONRPCError.parseError
    }

    @Test func aBareLineThatIsNotJSONIsAnsweredBare() async throws {
        let (router, window) = await connected()
        try window.send("{ this is not json")
        await eventually("an answer came") { !window.lines.isEmpty }
        #expect(parseError(in: window.lines.first ?? ""))
        withExtendedLifetime(router) {}
    }

    @Test func aWrappedLineWithABadHostIsAnsweredWrapped() async throws {
        let (router, window) = await connected()
        try window.send(#"{"h":"not a host!","m":{"jsonrpc":"2.0","id":1,"method":"agents/list"}}"#)
        await eventually("an answer came") { !window.lines.isEmpty }
        guard case .toControl(let message)? = try? ControlWire.readClient(window.lines.first ?? "") else {
            Issue.record("the answer was not wrapped: \(window.lines)")
            return
        }
        #expect(parseError(in: message))
        withExtendedLifetime(router) {}
    }

    @Test func aWrappedLineWithNoMessageIsAnsweredOnItsHostsRoute() async throws {
        let (router, window) = await connected()
        try window.send(#"{"h":"k3v9x0qa"}"#)
        await eventually("an answer came") { !window.lines.isEmpty }
        guard case .toHost(let host, let message)? = try? ControlWire.readClient(window.lines.first ?? "") else {
            Issue.record("the answer was not on the host's route: \(window.lines)")
            return
        }
        #expect(host.rawValue == "k3v9x0qa")
        #expect(parseError(in: message))
        withExtendedLifetime(router) {}
    }
}
