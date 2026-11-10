import Foundation
import Testing
@testable import AgentsKitCore

/// The Remote's canned daemon behind a control plane of its own (#4126): the Remote's
/// wrapped link reaches it, where it waited for a `control/status` answer for ever.
@Suite("A bare daemon as a control plane's one host", .timeLimit(.minutes(1)))
struct OneHostPlaneTests {
    /// A bare daemon that answers `daemon/ping` and says one thing unasked, as the canned one does.
    final class Bare: DaemonLink, @unchecked Sendable {
        private let lock = NSLock()
        private var held: [JSONRPCConnection] = []

        func transport() async throws -> any LineTransport {
            let (near, far) = PairedTransport.pair()
            let connection = JSONRPCConnection(transport: far) { method, _ in
                method == DaemonAPI.Method.ping ? .success(.object([:]))
                    : .failure(JSONRPCError(code: -32601, message: method))
            }
            await connection.start()
            lock.withLock { held.append(connection) }
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                try? connection.notify(DaemonAPI.Notification.agentChanged, .object([:]))
            }
            return near
        }
    }

    @Test func theRemotesWrappedLinkConnectsAndPings() async throws {
        let client = DaemonClient(link: HomeLink(OneHostPlane(Bare())), machine: .mac)
        await client.setPingPatience(.seconds(5))
        try await client.connect(startIfNeeded: false, timeout: .seconds(5))
        #expect(await client.answers(within: .seconds(5)))
        await client.disconnect()
    }

    @Test func passesWhatTheDaemonSaysUnasked() async throws {
        let link = try await HomeLink(OneHostPlane(Bare())).transport()
        for try await line in link.lines() {
            #expect(line.contains(DaemonAPI.Notification.agentChanged))
            break
        }
        link.close()
    }

    @Test func refusesTheControlPlanesOtherRequests() throws {
        let asked = #"{"jsonrpc":"2.0","id":7,"method":"control/status"}"#
        let answer = try #require(try OneHostPlane.answer(asked, host: .mac))
        #expect(answer.hasPrefix(#"{"m":"#))
        #expect(answer.contains("error"))
        let home = try JSONRPCCodec.encode(.request(id: HomeLink.statusID, method: DaemonAPI.Method.controlStatus, params: nil))
        #expect(try OneHostPlane.answer(home, host: .mac)?.contains(#""homeHost":"mac""#) == true)
        #expect(try OneHostPlane.answer(#"{"jsonrpc":"2.0","method":"x"}"#, host: .mac) == nil)
    }
}
