import Foundation
import Testing
@testable import AgentsKitCore

/// The ladder, exhausted. `decide` is total over its inputs, and a case that fell
/// through would be a need the person never hears about — the failure this feature
/// exists to prevent. Every test names its own thresholds and injects `now`; none sleeps.
@Suite("The ladder")
struct RoutingTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let thresholds = AttentionThresholds(macIdle: 120, deviceStaleness: 600,
                                                 settlingPause: 20, reAlertInterval: 300)
    private let agent = UUID()
    private let phoneID = UUID()
    private let padID = UUID()

    private func need(raisedAt: Date? = nil) -> Need {
        Need(id: .permission(UUID()), agentID: agent, folder: URL(filePath: "/tmp/p"), kind: .permission,
             raisedAt: raisedAt ?? t0.addingTimeInterval(-60),
             headline: Headline(h1: "p", h2: "a", h3: "wants"))
    }

    private func device(_ id: UUID, _ kind: Device.Kind, approved: Bool = true, mayNotify: Bool? = true,
                        lastSeen: Date? = nil) -> Device {
        Device(id: id, name: "d", kind: kind, announcedAt: t0, approvedAt: approved ? t0 : nil,
               lastSeenAt: lastSeen, mayNotify: mayNotify)
    }

    private func presence(_ surface: Surface, watching: UUID? = nil, active: Bool = true,
                          ago: TimeInterval = 0) -> Presence {
        Presence(surface: surface, watching: watching, active: active, heardAt: t0.addingTimeInterval(-ago))
    }

    private func decide(_ need: Need? = nil, outstanding: Bool = true, presences: [Presence] = [],
                        devices: [Device] = [], delivery: Delivery? = nil, now: Date? = nil) -> Decision {
        Routing.decide(need: need ?? self.need(), outstanding: outstanding,
                       presences: Dictionary(uniqueKeysWithValues: presences.map { ($0.surface, $0) }),
                       devices: devices, delivery: delivery, thresholds: thresholds, now: now ?? t0)
    }

    // MARK: Each rung reached

    @Test func rung0AMetNeedGoesNowhereWhateverElseIsTrue() {
        let d = decide(outstanding: false, presences: [presence(.mac)], devices: [device(phoneID, .iPhone)])
        #expect(d == Decision(to: nil, alert: false, wait: false))
    }

    @Test func rung1WatchingSilencesEverything() {
        let d = decide(presences: [presence(.mac, watching: agent)], devices: [device(phoneID, .iPhone)])
        #expect(d.to == nil)
        #expect(!d.alert)
        #expect(!d.wait)
    }

    /// US3 scenario 3: watched on a device while the Mac is active and the phone was
    /// touched more recently. The rule is about the conversation, not the machine.
    @Test func rung1IsAnySurfaceNotTheOneThatWouldWin() {
        let d = decide(presences: [presence(.mac, active: true, ago: 5),
                                   presence(.device(padID), watching: agent, ago: 30),
                                   presence(.device(phoneID), ago: 1)],
                       devices: [device(padID, .iPad), device(phoneID, .iPhone)])
        #expect(d.to == nil)
    }

    @Test func rung2AtTheMac() {
        let d = decide(presences: [presence(.mac, ago: 30), presence(.device(phoneID), ago: 1)],
                       devices: [device(phoneID, .iPhone)])
        #expect(d.to == .mac)
        #expect(d.alert)
        #expect(!d.wait)
    }

    @Test func rung2NeedsTheMacActiveAndRecent() {
        #expect(decide(presences: [presence(.mac, active: false)], devices: [device(phoneID, .iPhone)]).to == .device(phoneID))
        #expect(decide(presences: [presence(.mac, ago: 121)], devices: [device(phoneID, .iPhone)]).to == .device(phoneID))
        #expect(decide(presences: [presence(.mac, ago: 119)]).to == .mac)
    }

    @Test func rung3TheDeviceInHand() {
        let d = decide(presences: [presence(.device(padID), ago: 10), presence(.device(phoneID), ago: 100)],
                       devices: [device(padID, .iPad), device(phoneID, .iPhone)])
        #expect(d.to == .device(padID))
    }

    @Test func rung3SkipsADeviceThatMayNotNotifyAndSoDoesRung4() {
        let mute = device(phoneID, .iPhone, mayNotify: false)
        let d = decide(presences: [presence(.device(phoneID), ago: 1)], devices: [mute])
        #expect(d.to == nil, "a device that cannot show anything is choosing silence")
        let unsaid = device(phoneID, .iPhone, mayNotify: nil)
        #expect(decide(presences: [presence(.device(phoneID), ago: 1)], devices: [unsaid]).to == nil)
        #expect(decide(presences: [presence(.device(padID))], devices: [device(padID, .iPad, approved: false)]).to == nil)
    }

    @Test func rung4TheDefaultIPhone() {
        let older = device(UUID(), .iPhone, lastSeen: t0.addingTimeInterval(-9000))
        let newer = device(phoneID, .iPhone, lastSeen: t0.addingTimeInterval(-4000))
        let d = decide(presences: [presence(.device(padID), ago: 601)], devices: [older, newer, device(padID, .iPad)])
        #expect(d.to == .device(phoneID), "the most recently used iPhone, when nobody is in hand")
    }

    @Test func rung4RefusesAnUnknownAsTheDefault() {
        let d = decide(devices: [device(UUID(), .unknown), device(padID, .iPad)])
        #expect(d.to == nil)
    }

    @Test func rung5WhenEveryDeviceIsStale() {
        let d = decide(presences: [presence(.device(padID), ago: 700), presence(.mac, ago: 700)],
                       devices: [device(padID, .iPad)])
        #expect(d.to == nil)
        #expect(!d.wait)
    }

    // MARK: The pause

    @Test func thePauseHoldsAtTheMacInsideItAndNotOutsideIt() {
        let fresh = need(raisedAt: t0.addingTimeInterval(-5))
        let inside = decide(fresh, presences: [presence(.mac)])
        #expect(inside.wait)
        #expect(inside.to == .mac)
        #expect(!inside.alert, "nothing is delivered while waiting")
        let outside = decide(fresh, presences: [presence(.mac)], now: t0.addingTimeInterval(20))
        #expect(!outside.wait)
        #expect(outside.alert)
    }

    @Test func thePauseNeverHoldsWhenThePersonIsAway() {
        let fresh = need(raisedAt: t0)
        let phone = decide(fresh, presences: [presence(.device(phoneID))], devices: [device(phoneID, .iPhone)])
        #expect(!phone.wait)
        #expect(phone.to == .device(phoneID))
        let nowhere = decide(fresh)
        #expect(!nowhere.wait)
    }

    // MARK: Alerting versus showing

    @Test func theFirstDecisionAlerts() {
        #expect(decide(presences: [presence(.mac)]).alert)
    }

    @Test func aMoveInsideTheIntervalIsSilentAndAfterItIsNot() {
        let shownOnMac = Delivery(needID: need().id, to: .mac, alertedAt: t0.addingTimeInterval(-100), alertCount: 1)
        let moved = decide(presences: [presence(.device(phoneID))], devices: [device(phoneID, .iPhone)],
                           delivery: shownOnMac)
        #expect(moved.to == .device(phoneID))
        #expect(!moved.alert, "it moves, silently")
        let later = decide(presences: [presence(.device(phoneID))], devices: [device(phoneID, .iPhone)],
                           delivery: shownOnMac, now: t0.addingTimeInterval(250))
        #expect(later.alert)
    }

    @Test func stayingPutNeverReAlerts() {
        let shown = Delivery(needID: need().id, to: .mac, alertedAt: t0.addingTimeInterval(-10_000), alertCount: 1)
        #expect(!decide(presences: [presence(.mac)], delivery: shown).alert)
    }

    /// SC-006, asserted rather than hoped for: ten moves inside five minutes, at most
    /// two alerts. The first, and one more once the interval has passed.
    @Test func tenMovesInFiveMinutesAlertAtMostTwice() {
        var delivery: Delivery? = nil
        var alerts = 0
        let phone = device(phoneID, .iPhone)
        for step in 0..<10 {
            let now = t0.addingTimeInterval(Double(step) * 30)
            let onPhone = step % 2 == 0
            let presences = onPhone ? [presence(.device(phoneID))] : [presence(.mac)]
            let shifted = presences.map { Presence(surface: $0.surface, watching: nil, active: true, heardAt: now) }
            let d = Routing.decide(need: need(), presences: Dictionary(uniqueKeysWithValues: shifted.map { ($0.surface, $0) }),
                                   devices: [phone], delivery: delivery, thresholds: thresholds, now: now)
            if d.alert { alerts += 1 }
            delivery = Delivery(needID: need().id, to: d.to,
                                alertedAt: d.alert ? now : (delivery?.alertedAt ?? now),
                                alertCount: (delivery?.alertCount ?? 0) + (d.alert ? 1 : 0))
        }
        #expect(alerts <= 2, "alerts: \(alerts)")
        #expect(alerts >= 1)
    }

    // MARK: Ties

    @Test func aTieGoesToTheIPhone() {
        let d = decide(presences: [presence(.device(padID), ago: 3), presence(.device(phoneID), ago: 3)],
                       devices: [device(padID, .iPad), device(phoneID, .iPhone)])
        #expect(d.to == .device(phoneID))
    }

    @Test func totalOverEveryShapeOfInput() {
        let surfaces: [[Presence]] = [[], [presence(.mac)], [presence(.mac, active: false)],
                                      [presence(.device(phoneID))], [presence(.mac, watching: agent)]]
        let deviceSets: [[Device]] = [[], [device(phoneID, .iPhone)], [device(padID, .iPad)],
                                      [device(phoneID, .iPhone, mayNotify: false)]]
        for p in surfaces { for ds in deviceSets { for outstanding in [true, false] {
            _ = decide(outstanding: outstanding, presences: p, devices: ds)
        } } }
    }
}
