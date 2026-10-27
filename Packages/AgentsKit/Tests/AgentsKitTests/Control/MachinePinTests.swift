import Foundation
import Testing
@testable import AgentsKitCore

/// A Mac pinned to one control plane by a configuration profile (#998, spec 998 slice 4, US7):
/// the three managed keys, the codes and memberships the pin admits, and the words.
@Suite("Machine pin")
struct MachinePinTests {
    let key = Data([4] + Array(repeating: 1, count: 64))
    let otherKey = Data([4] + Array(repeating: 2, count: 64))

    func code(_ key: Data, url: String) -> ControlCode {
        ControlCode(purpose: .host, controlKey: key, secret: Data(repeating: 3, count: 32), url: url, pin: nil, name: "cp")
    }

    /// FR-025: the three keys a profile forces make the pin; none of them is no pin.
    @Test func theThreeKeysMakeThePin() {
        let pin = MachinePin.read(forced: ["ControlPlaneAddress": "control.acme.dev", "ControlPlaneKey": "abc", "MustJoin": true])
        #expect(pin == MachinePin(address: "control.acme.dev", key: "abc", mustJoin: true))
        #expect(pin?.arguments == ["--pin-address", "control.acme.dev", "--pin-key", "abc", "--must-join"])
        #expect(MachinePin.read(forced: [:]) == nil)
        #expect(MachinePin.read(forced: ["ControlPlaneAddress": ""]) == nil)
    }

    /// US7 AS4, FR-029: a rule in the profile is ignored, and said; macOS's own forced keys are not.
    @Test func aRuleInTheProfileIsIgnoredAndSaid() {
        var said: [String] = []
        let pin = MachinePin.read(forced: ["ControlPlaneAddress": "control.acme.dev", "modes": "ask", "stopAll": true,
                                           "AppleLanguages": ["en"]], ignored: { said = $0 })
        #expect(pin == MachinePin(address: "control.acme.dev", key: nil, mustJoin: false))
        #expect(said == ["modes", "stopAll"])
    }

    /// The key id agrees with agentsd's (controllink.KeyID).
    @Test func theKeyIDIsAgentsds() {
        #expect(MachinePin.keyID(key) == "taPq3iOv_j8")
    }

    /// US7 AS2, FR-027: only the pinned control plane's codes and memberships are admitted,
    /// by its key or its key id, at any of its addresses.
    @Test func onlyThePinnedControlPlaneIsAdmitted() {
        let pin = MachinePin(address: "Control.Acme.dev", key: ControlCode.base64url(key), mustJoin: true)
        #expect(pin.admits(code(key, url: "https://control.acme.dev:8443")))
        #expect(!pin.admits(code(otherKey, url: "https://control.acme.dev")))
        #expect(!pin.admits(code(key, url: "https://control.elsewhere.dev")))
        let byID = MachinePin(address: nil, key: MachinePin.keyID(key), mustJoin: false)
        #expect(byID.admits(code(key, url: "https://anywhere.dev")))
        #expect(!byID.admits(code(otherKey, url: "https://anywhere.dev")))
        let member = ControlMembership(host: MachineRef(rawValue: "abcd1234"), controlKey: key, addresses: [], name: "acme",
                                       url: "https://10.0.0.1:443", pin: nil)
        #expect(!pin.admits(member))
        var moved = member
        moved.endpoints = [ControlEndpoint(url: "https://control.acme.dev")]
        #expect(pin.admits(moved))
    }

    /// The words name the control plane required (contracts/policy-api.md).
    @Test func theWordsNameTheControlPlane() {
        let pin = MachinePin(address: "https://control.acme.dev:443", key: nil, mustJoin: true)
        #expect(pin.mustJoinWords == "Your organisation requires this Mac to join control.acme.dev.")
        #expect(pin.refusal == "Set by your organisation. This Mac may join control.acme.dev only.")
        #expect(pin.leaveRefusal == "Set by your organisation. This Mac stays joined to control.acme.dev.")
    }
}
