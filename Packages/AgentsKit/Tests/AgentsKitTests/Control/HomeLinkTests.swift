import Foundation
import Testing
@testable import AgentsKitCore

/// The Remote's own connection, wrapped (#3234): what it writes is the contract that the Go
/// control plane's TestTheRemotesWrappedLinesReachTheHomeHost sends to a real router.
@Suite("The Remote's connection to its home host", .timeLimit(.minutes(1)))
struct HomeLinkTests {
    static let contract = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/control-wire/remote-home.jsonl")

    struct Given: DaemonLink {
        let transport: PairedTransport
        func transport() async throws -> any LineTransport { transport }
    }

    /// The control plane's end: every line it hears, in order.
    final class Plane: @unchecked Sendable {
        let transport: PairedTransport
        private let lock = NSLock()
        private var heard: [String] = []

        init(_ transport: PairedTransport) {
            self.transport = transport
            Task { [weak self] in
                do { for try await line in transport.lines() { self?.lock.withLock { self?.heard.append(line) } } } catch {}
            }
        }

        var lines: [String] { lock.withLock { heard } }

        func waitFor(_ count: Int) async throws {
            while lines.count < count { try await Task.sleep(for: .milliseconds(5)) }
        }

        func say(_ line: String) throws { try transport.write(line: line) }

        func home(_ host: String) throws {
            try say(#"{"m":{"jsonrpc":"2.0","id":"home-link/status","result":{"name":"Plane","homeHost":"\#(host)"}}}"#)
        }
    }

    static func open() async throws -> (any LineTransport, Plane) {
        let (client, plane) = PairedTransport.pair()
        return (try await HomeLink(Given(transport: client)).transport(), Plane(plane))
    }

    @Test func writesTheContractsLines() async throws {
        let contract = try String(contentsOf: Self.contract, encoding: .utf8).split(separator: "\n").map(String.init)
        let messages = try contract.dropFirst().map { line -> String in
            switch try ControlWire.readClient(line) {
            case .toHost(_, let message), .toControl(let message), .bare(let message): return message
            }
        }
        let (link, plane) = try await Self.open()
        // Written before the control plane said which host is home: held until it does.
        try link.write(line: messages[0])
        try await plane.waitFor(1)
        #expect(plane.lines == [contract[0]])
        try plane.home("mac")
        try await plane.waitFor(2)
        for message in messages.dropFirst() { try link.write(line: message) }
        try await plane.waitFor(contract.count)
        #expect(plane.lines == contract)
    }

    @Test func handsBackWhatABareConnectionHeard() async throws {
        let (link, plane) = try await Self.open()
        try plane.home("mac")
        try plane.say(#"{"h":"box1","m":{"jsonrpc":"2.0","id":1,"result":{"pong":"box1"}}}"#)
        try plane.say(#"{"m":{"jsonrpc":"2.0","method":"control/hostChanged","params":{"host":"box1","state":"offline"}}}"#)
        try plane.say(#"{"h":"mac","m":{"jsonrpc":"2.0","id":1,"result":{"pong":"mac"}}}"#)
        try plane.say(#"{"m":{"jsonrpc":"2.0","id":2,"result":[]}}"#)
        // The home host gone ends the connection, as a bare one was ended.
        try plane.say(#"{"m":{"jsonrpc":"2.0","method":"control/hostChanged","params":{"host":"mac","state":"offline"}}}"#)
        var heard: [String] = []
        for try await line in link.lines() { heard.append(line) }
        #expect(heard == [#"{"jsonrpc":"2.0","id":1,"result":{"pong":"mac"}}"#, #"{"jsonrpc":"2.0","id":2,"result":[]}"#])
        #expect(throws: JSONRPCTransportError.self) { try link.write(line: #"{"jsonrpc":"2.0","id":3,"method":"daemon/ping"}"#) }
    }

    @Test func endsWhenThereIsNoHomeHost() async throws {
        let (link, plane) = try await Self.open()
        try plane.say(#"{"m":{"jsonrpc":"2.0","id":"home-link/status","result":{"name":"Plane"}}}"#)
        await #expect(throws: HomeLink.NoHomeHost.self) {
            for try await _ in link.lines() {}
        }
    }
}
