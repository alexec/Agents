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

    /// The page asks what the host could not read and hears it change, as the window does (#223).
    @Test func thePageAsksAndHearsStoreNotes() {
        let rows = Rows.rows
        #expect(rows.contains { $0.method == DaemonAPI.Method.storeNotes && $0.kind == .hostRequest
            && $0.result == DaemonAPI.StoreNotes.self })
        #expect(rows.contains { $0.method == DaemonAPI.Notification.storeNotesChanged && $0.kind == .hostNotification
            && $0.params == DaemonAPI.StoreNotes.self })
    }
}
