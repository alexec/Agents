import Foundation
import Testing
@testable import AgentsKitCore

/// The phone picks the direct link when the Mac is nearby and the relay otherwise, and
/// moves back when the Mac comes into reach (046, R8, FR-002).
@Suite("Choosing the link")
struct LinkChooserTests {
    /// A transport that only remembers whether it was closed.
    final class Probe: LineTransport, @unchecked Sendable {
        let name: String
        let closed = ManagedAtomicFlag()
        let stream: AsyncThrowingStream<String, any Error>
        let continuation: AsyncThrowingStream<String, any Error>.Continuation

        init(_ name: String) {
            self.name = name
            (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        }

        func write(line: String) throws {}
        func lines() -> AsyncThrowingStream<String, any Error> { stream }
        func close() {
            closed.set()
            continuation.finish()
        }
    }

    struct Nope: Error {}

    private static func after(_ delay: Duration, _ transport: Probe) -> LinkChooser.MakeTransport {
        { try await Task.sleep(for: delay); return transport }
    }

    private static func failing(after delay: Duration, _ error: any Error = Nope()) -> LinkChooser.MakeTransport {
        { try await Task.sleep(for: delay); throw error }
    }

    @Test func theDirectLinkWinsWhenItIsQuick() async throws {
        let direct = Probe("direct"), relay = Probe("relay")
        let chooser = LinkChooser(direct: Self.after(.milliseconds(50), direct),
                                  relay: Self.after(.milliseconds(10), relay), window: .milliseconds(300))
        let chosen = try await chooser.transport() as? Probe
        #expect(chosen === direct)
        #expect(chooser.link == .direct)
        await eventually("the relay that lost is closed") { relay.closed.isSet }
    }

    @Test func theRelayWinsWhenTheMacIsNotNearby() async throws {
        let relay = Probe("relay")
        let chooser = LinkChooser(direct: Self.failing(after: .milliseconds(20)),
                                  relay: Self.after(.milliseconds(60), relay),
                                  probe: Self.failing(after: .zero), window: .milliseconds(300))
        let chosen = try await chooser.transport() as? Probe
        #expect(chosen === relay)
        #expect(chooser.link == .relayed)
    }

    @Test func aQuietDirectLinkLosesAfterTheWindow() async throws {
        let direct = Probe("direct"), relay = Probe("relay")
        let chooser = LinkChooser(direct: Self.after(.seconds(5), direct),
                                  relay: Self.after(.milliseconds(10), relay),
                                  probe: Self.failing(after: .zero), window: .milliseconds(100))
        let started = ContinuousClock.now
        let chosen = try await chooser.transport() as? Probe
        #expect(chosen === relay)
        // Well before the direct link's five seconds, even with the suite's load around it.
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test func neitherAnsweringSaysWhyTheRelayCouldNot() async throws {
        let chooser = LinkChooser(direct: Self.failing(after: .milliseconds(10)),
                                  relay: Self.failing(after: .milliseconds(20), RelayTrouble.notPaired),
                                  window: .milliseconds(100))
        await #expect(throws: RelayTrouble.notPaired) { _ = try await chooser.transport() }
        #expect(chooser.link == .none)
    }

    @Test func backHomeTheRelayGivesWay() async throws {
        let relay = Probe("relay")
        let macNearby = ManagedAtomicFlag()
        let chooser = LinkChooser(direct: Self.failing(after: .milliseconds(10)),
                                  relay: Self.after(.milliseconds(10), relay),
                                  probe: {
                                      guard macNearby.isSet else { throw Nope() }
                                      return Probe("probe")
                                  },
                                  window: .milliseconds(50), probeEvery: .milliseconds(30))
        _ = try await chooser.transport()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!relay.closed.isSet, "no Mac nearby yet, so the relay stays")
        macNearby.set()
        await eventually("the relay is closed so the model reconnects") { relay.closed.isSet }
        #expect(chooser.link == .none)
    }

    @Test func theLinkIsHeardAsItChanges() async throws {
        let relay = Probe("relay")
        let chooser = LinkChooser(direct: Self.failing(after: .milliseconds(5)),
                                  relay: Self.after(.milliseconds(5), relay),
                                  probe: Self.failing(after: .zero), window: .milliseconds(50))
        var heard = chooser.links().makeAsyncIterator()
        #expect(await heard.next() == RemoteLink.none)
        _ = try await chooser.transport()
        #expect(await heard.next() == .relayed)
    }
}
