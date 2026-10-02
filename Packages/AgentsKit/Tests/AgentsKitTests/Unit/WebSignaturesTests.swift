import Foundation
import Testing
@testable import AgentsKitCore

/// The web remote is typed against what a person's connection may ask, and none of an
/// agent's tools (071, research R6; one grant since #111).
@Suite("Web signatures")
struct WebSignaturesTests {
    typealias Rows = DaemonAPI.WebSignatures

    @Test func everyHostRequestIsOneADeviceMayMakeAndNoAgentTool() {
        let requests = Rows.rows.filter { $0.kind == .hostRequest }.map(\.method)
        #expect(requests.filter { !ConnectionRole.device.allows($0) } == [])
        let tools = ConnectionRole.agentMethods.subtracting(ConnectionRole.strangerMethods)
        #expect(Set(requests).isDisjoint(with: tools), "an agent's tool: \(Set(requests).intersection(tools))")
    }

    @Test func noMethodIsListedTwice() {
        let methods = Rows.rows.map(\.method)
        #expect(methods.count == Set(methods).count)
    }

    @Test func notificationsAreNotRequests() {
        let notifications = Set(Rows.rows.filter { $0.kind == .hostNotification || $0.kind == .controlNotification }
            .map(\.method))
        #expect(notifications.isDisjoint(with: Set(ControlGrantTests.everyMethod)))
        #expect(notifications.contains(DaemonAPI.Notification.agentEntry))
    }
}
