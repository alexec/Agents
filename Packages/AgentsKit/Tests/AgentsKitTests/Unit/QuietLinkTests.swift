import Foundation
import Testing
@testable import AgentsKitCore

/// A far end that has gone quiet is let go rather than waited on for ever. The phone
/// runs one reconnect at a time, so a ping that never came back held every later
/// attempt behind it, and the app had to be killed to reach the Mac again.
@Suite("A quiet link")
struct QuietLinkTests {
    /// A Mac that answers pings until it is told to stop, then says nothing at all:
    /// the TLS handshake done, the daemon behind the bridge not answering.
    final class Mac: DaemonLink, @unchecked Sendable {
        let quiet = ManagedAtomicFlag()

        func transport() async throws -> any LineTransport {
            let (near, far) = PairedTransport.pair()
            let quiet = quiet
            _ = Task {
                for try await line in far.lines() {
                    guard !quiet.isSet,
                          let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = object["id"] as? Int else { continue }
                    try? far.write(line: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
                }
            }
            return near
        }

        func start() async throws {}
    }

    @Test func aMacThatNeverAnswersIsNotConnectedTo() async throws {
        let mac = Mac()
        mac.quiet.set()
        let client = DaemonClient(link: mac)
        await client.setPingPatience(.milliseconds(200))
        let started = ContinuousClock.now
        await #expect(throws: DaemonClient.ConnectError.self) {
            try await client.connect(startIfNeeded: false)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aConnectionThatGoesQuietIsLetGoAndWhatWaitedOnItFails() async throws {
        let mac = Mac()
        let client = DaemonClient(link: mac)
        try await client.connect(startIfNeeded: false)
        #expect(await client.answers(within: .seconds(5)))

        mac.quiet.set()
        let waiting = Task { try await client.call(DaemonAPI.Method.ping) }
        let started = ContinuousClock.now
        #expect(await !client.answers(within: .milliseconds(200)))
        #expect(ContinuousClock.now - started < .seconds(10), "the race returned without waiting for the ping")
        await #expect(throws: JSONRPCTransportError.self) { _ = try await waiting.value }
    }

    @Test func aQuietConnectionIsReplacedOnTheNextConnect() async throws {
        let mac = Mac()
        let client = DaemonClient(link: mac)
        try await client.connect(startIfNeeded: false)
        await client.setPingPatience(.milliseconds(200))
        mac.quiet.set()
        // The old connection is asked first; quiet, it is closed rather than trusted,
        // and the fresh one is quiet too, so this fails instead of hanging.
        await #expect(throws: DaemonClient.ConnectError.self) {
            try await client.connect(startIfNeeded: false)
        }
    }
}
