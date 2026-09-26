import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A server going and coming back said once each, through the window's retries (037, 042).
@Suite("Server reachability")
struct ServerReachabilityTests {
    private let devbox = HostID(rawValue: "devbox")
    private let since = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aServerThatWasNeverConnectedHasNotGoneOffline() {
        var reachability = ServerReachability()
        #expect(reachability.moved(devbox, to: .connecting(.connect)) == nil)
        #expect(reachability.moved(devbox, to: .failed(.offline)) == nil)
        #expect(reachability.moved(devbox, to: .connected) == nil)
    }

    @Test func goingIsSaidOnceThroughTheRetriesAndComingBackOnce() {
        var reachability = ServerReachability()
        #expect(reachability.moved(devbox, to: .connected) == nil)
        #expect(reachability.moved(devbox, to: .offline(since: since)) == .wentOffline)
        #expect(reachability.moved(devbox, to: .connecting(.connect)) == nil)
        #expect(reachability.moved(devbox, to: .offline(since: since.addingTimeInterval(30))) == nil)
        #expect(reachability.offlineSince[devbox] == since)
        #expect(reachability.moved(devbox, to: .connected) == .cameBack)
        #expect(reachability.offlineSince[devbox] == nil)
        #expect(reachability.moved(devbox, to: .connected) == nil)
    }

    @Test func talkingToTheOldDaemonWhileAnUpdateWaitsIsBack() {
        var reachability = ServerReachability()
        _ = reachability.moved(devbox, to: .offline(since: since))
        #expect(reachability.moved(devbox, to: .updateWaiting) == .cameBack)
        #expect(reachability.moved(devbox, to: .connected) == nil)
    }

    @Test func aForgottenServerHasNothingToComeBackFrom() {
        var reachability = ServerReachability()
        _ = reachability.moved(devbox, to: .offline(since: since))
        reachability.forget(devbox)
        #expect(reachability.moved(devbox, to: .connected) == nil)
    }
}
