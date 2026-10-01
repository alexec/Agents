import Foundation
import Testing
@testable import AgentsKitCore

@Suite("Notices through the control plane")
struct ControlNoticesTests {
    let phone = UUID()
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func need() -> Need {
        Need(id: .permission(UUID()), agentID: UUID(), folder: URL(filePath: "/work"),
             kind: .permission, raisedAt: now.addingTimeInterval(-60),
             headline: Headline(h1: "work", h2: "Fix the test", h3: "may run a command"))
    }

    private func device(mayNotify: Bool = true) -> Device {
        Device(id: phone, publicKey: Data([1]), name: "Phone", kind: .iPhone,
               announcedAt: now.addingTimeInterval(-86_400), mayNotify: mayNotify)
    }

    @Test func anOperatorAtAScreenSealsNothing() {
        let presences: [Surface: Presence] = [
            .mac: Presence(surface: .mac, watching: nil, active: true, heardAt: now)
        ]
        let chosen = ControlNotices.device(for: need(), presences: presences, devices: [device()],
                                           delivery: nil, now: now)
        #expect(chosen == nil)
    }

    @Test func aDeviceInHandIsTheOneSealedTo() {
        let presences: [Surface: Presence] = [
            .device(phone): Presence(surface: .device(phone), watching: nil, active: true, heardAt: now)
        ]
        let chosen = ControlNotices.device(for: need(), presences: presences, devices: [device()],
                                           delivery: nil, now: now)
        #expect(chosen?.id == phone)
        #expect(chosen?.alert == true)
    }

    @Test func watchingAnywhereSealsNothing() {
        let agent = UUID()
        var asked = need()
        asked = Need(id: asked.id, agentID: agent, folder: asked.folder, kind: asked.kind,
                     raisedAt: asked.raisedAt, headline: asked.headline)
        let presences: [Surface: Presence] = [
            .device(phone): Presence(surface: .device(phone), watching: agent, active: true, heardAt: now)
        ]
        let chosen = ControlNotices.device(for: asked, presences: presences, devices: [device()],
                                           delivery: nil, now: now)
        #expect(chosen == nil)
    }

    @Test func aNeedRoundTripsUnsealedAndAWithdrawalNamesOnlyTheId() throws {
        let offered = DaemonAPI.AttentionNeed.offer(need(), buzz: true)
        let back = try JSONValue.encoding(offered).decode(DaemonAPI.AttentionNeed.self)
        #expect(back.need == offered.need)
        #expect(back.headline == offered.headline)
        #expect(back.buzz == true)
        #expect(back.withdraw == nil)

        let id = NeedID.permission(UUID())
        let withdrawn = try JSONValue.encoding(DaemonAPI.AttentionNeed.withdraw(id)).decode(DaemonAPI.AttentionNeed.self)
        #expect(withdrawn.withdraw == id)
        #expect(withdrawn.need == nil)
    }
}
