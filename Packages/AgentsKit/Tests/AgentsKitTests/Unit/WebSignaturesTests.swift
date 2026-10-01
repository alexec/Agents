import Foundation
import Testing
@testable import AgentsKitCore

/// The web remote is typed only against what a device may do (071, FR-016, research R6).
@Suite("Web signatures")
struct WebSignaturesTests {
    typealias Rows = DaemonAPI.WebSignatures

    @Test func everyHostRequestIsOneADeviceMayMake() {
        let refused = Rows.rows.filter { $0.kind == .hostRequest }.map(\.method)
            .filter { !ConnectionRole.deviceMethods.contains($0) }
        #expect(refused == [], "not allowed to a device: \(refused)")
    }

    @Test func everyControlRequestIsOneAnyGrantMayMake() {
        let refused = Rows.rows.filter { $0.kind == .controlRequest }.map(\.method)
            .filter { !ControlMethods.anyGrant.contains($0) }
        #expect(refused == [], "an operator's only: \(refused)")
    }

    @Test func noMethodIsListedTwice() {
        let methods = Rows.rows.map(\.method)
        #expect(methods.count == Set(methods).count)
    }

    @Test func notificationsAreNotRequests() {
        let notifications = Set(Rows.rows.filter { $0.kind == .hostNotification || $0.kind == .controlNotification }
            .map(\.method))
        #expect(notifications.isDisjoint(with: ConnectionRole.deviceMethods))
        #expect(notifications.contains(DaemonAPI.Notification.agentEntry))
    }
}
