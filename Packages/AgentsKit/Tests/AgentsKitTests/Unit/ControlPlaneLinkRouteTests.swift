import Foundation
import Testing
@testable import AgentsKitCore

/// The Remote's link says which way each connection went, so the app knows it is away
/// (#883): the Away line, and the terminal and files that wait for the address.
@Suite("The control plane link's route")
struct ControlPlaneLinkRouteTests {
    struct Unreachable: Error {}

    final class Line: LineTransport, @unchecked Sendable {
        func write(line: String) throws {}
        func lines() -> AsyncThrowingStream<String, any Error> { AsyncThrowingStream { _ in } }
        func close() {}
    }

    @Test func noRouteBeforeTheFirstConnection() {
        let link = ControlPlaneLink(dial: { Line() }, relayed: nil)
        #expect(link.route.current == .none)
    }

    @Test func theAddressIsDirect() async throws {
        let link = ControlPlaneLink(dial: { Line() }, relayed: { Line() })
        _ = try await link.transport()
        #expect(link.route.current == .direct)
    }

    @Test func theRelayWhenTheAddressFailsIsRelayed() async throws {
        let link = ControlPlaneLink(dial: { throw Unreachable() }, relayed: { Line() })
        _ = try await link.transport()
        #expect(link.route.current == .relayed)
        link.watching.stop()
    }

    @Test func theAddressAgainIsDirectAgain() async throws {
        let answers = Answers()
        let link = ControlPlaneLink(dial: {
            guard answers.address else { throw Unreachable() }
            return Line()
        }, relayed: { Line() })
        _ = try await link.transport()
        #expect(link.route.current == .relayed)
        answers.address = true
        _ = try await link.transport()
        #expect(link.route.current == .direct)
    }

    @Test func theSecondConnectionDoesNotSayTheFirstsRoute() async throws {
        let link = ControlPlaneLink(dial: { throw Unreachable() }, relayed: { Line() })
        _ = try await link.transport()
        let second = link.addressOnly
        _ = try? await second.transport()
        #expect(link.route.current == .relayed)
        #expect(second.route.current == .none)
        link.watching.stop()
    }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var address: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}
