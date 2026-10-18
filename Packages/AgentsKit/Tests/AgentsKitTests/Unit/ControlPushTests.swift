import Foundation
import Testing
@testable import AgentsKitCore

/// A push the control plane sealed in Go (#1460) opens here, on the device it was sealed
/// to, as `RemoteNotify` and the app open it. The fixture is the Go test's own
/// (`TestTheSwiftFixtureOpens`), so both ends are checked against the same bytes.
@Suite("Control plane push")
struct ControlPushTests {
    struct Fixture: Decodable {
        var devicePrivateKey: Data
    }

    static let file = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Go/internal/controlplane/apns/testdata/control-push.json")

    static func fixture() throws -> (key: DeviceKey, userInfo: [AnyHashable: Any]) {
        let data = try Data(contentsOf: file)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let whole = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let userInfo = try #require(whole?["push"] as? [String: Any])
        return (try DeviceKey.software(privateKey: fixture.devicePrivateKey), userInfo)
    }

    @Test func theDeviceOpensWhatGoSealed() throws {
        let (key, userInfo) = try Self.fixture()
        #expect(ControlPush.isControlPush(userInfo))
        let pushed = try #require(ControlPush.pushed(from: userInfo, key: key))
        let agent = try #require(UUID(uuidString: "A0000000-0000-4000-8000-000000000001"))
        let at = Date(timeIntervalSinceReferenceDate: 800000000.5)
        #expect(pushed.needID == .report(agent, at))
        #expect(pushed.token == NeedID.report(agent, at).token)
        #expect(pushed.headline == Headline(h1: "brushwise", h2: "Rehang the gallery", h3: "Wants to write hello.txt",
                                            answers: [QuickAnswer(kind: .choice, id: "allow", title: "Allow")]))
        #expect(pushed.alert)
        #expect(!pushed.withdraws)
    }

    /// Apple sees only the generic alert: none of the words, and not the need.
    @Test func appleSeesOnlyTheGenericAlert() throws {
        let (_, userInfo) = try Self.fixture()
        let aps = try #require(userInfo["aps"] as? [String: Any])
        #expect((aps["alert"] as? [String: String]) == ["title": "An agent needs you"])
        #expect(aps["mutable-content"] as? Int == 1)
        let carried = String(decoding: try JSONSerialization.data(withJSONObject: userInfo), as: UTF8.self)
        for word in ["brushwise", "Rehang", "hello.txt", "A0000000", "Allow"] {
            #expect(!carried.contains(word), "\(word) is legible")
        }
    }

    /// Another device, or none, opens nothing: the banner keeps the generic title.
    @Test func onlyThatDeviceOpensIt() throws {
        let (_, userInfo) = try Self.fixture()
        #expect(ControlPush.pushed(from: userInfo, key: DeviceKey.ephemeral()) == nil)
        #expect(ControlPush.pushed(from: userInfo, key: nil) == nil)
    }

    /// A mailbox push from a Mac host's relay is not the control plane's.
    @Test func aMailboxPushIsNotOne() {
        let userInfo: [AnyHashable: Any] = ["aps": ["content-available": 1], "ck": ["qry": [:]]]
        #expect(!ControlPush.isControlPush(userInfo))
        #expect(ControlPush.pushed(from: userInfo, key: DeviceKey.ephemeral()) == nil)
    }

    /// A headline sealed for the mailbox does not open as a push, nor a push as a headline.
    @Test func aHeadlineIsNotAPush() throws {
        let device = DeviceKey.ephemeral()
        let envelope = try Envelope.seal(Headline(h1: "a", h2: "b", h3: "c"), to: device.publicKey)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(["sealed": envelope]))
        #expect(ControlPush.pushed(from: ["agents": body], key: device) == nil)
        let (key, userInfo) = try Self.fixture()
        let sealed = try JSONDecoder().decode(ControlPush.Body.self, from: JSONSerialization.data(
            withJSONObject: try #require(userInfo["agents"]))).sealed
        #expect(throws: (any Error).self) { try Envelope.open(sealed, with: key) }
    }

    /// A withdrawal has no words, and takes the banner away.
    @Test func noHeadlineIsAWithdrawal() {
        let need = NeedID.permission(UUID())
        let pushed = CloudKitMailbox.Pushed(needID: need, token: need.token, envelope: nil, alert: false, withdrawn: true)
        #expect(pushed.withdraws)
        var shown = pushed
        shown.withdrawn = false
        shown.headline = Headline(h1: "a", h2: "b", h3: "c")
        #expect(!shown.withdraws)
    }
}
