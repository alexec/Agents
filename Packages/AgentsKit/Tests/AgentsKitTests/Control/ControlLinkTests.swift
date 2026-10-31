import Foundation
import Testing
@testable import AgentsKitCore

/// `ControlLink`'s dial (058): `DaemonClient.connect()` keeps only "could not connect"
/// from whatever `dial` throws, so a refusal's words (#2235) are kept on the side as
/// `connected()` sees them, for the window to read once it gives up.
@Suite("The control plane's one connection")
struct ControlLinkTests {
    @Test func aRefusalIsKeptOnTheSideAsDaemonClientWouldDiscardIt() async throws {
        let link = ControlLink(dial: { throw ControlRefusal(line: "This hosted account is suspended.") })
        await #expect(throws: ControlRefusal.self) {
            _ = try await link.controlLink.transport()
        }
        #expect(ControlLink.hostedRefusal.take() == "This hosted account is suspended.")
        // Taken once: a second read, as the next failed try would make, finds nothing left.
        #expect(ControlLink.hostedRefusal.take() == nil)
    }

    @Test func anOrdinaryFailureKeepsNothing() async throws {
        struct Boom: Error {}
        let link = ControlLink(dial: { throw Boom() })
        await #expect(throws: Boom.self) {
            _ = try await link.controlLink.transport()
        }
        #expect(ControlLink.hostedRefusal.take() == nil)
    }
}
