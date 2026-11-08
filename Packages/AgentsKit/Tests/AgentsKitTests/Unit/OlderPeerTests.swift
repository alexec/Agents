import AgentsKitCore
import Testing

/// What the Mac and the Remote say when an older control plane or machine refuses a call (#4096).
struct OlderPeerTests {
    private let notAProviderCreate = JSONRPCError(code: JSONRPCError.invalidParams,
                                                  message: "Those parameters are not a ProviderCreate.")

    @Test func anOlderControlPlaneNeedsAnUpdate() {
        #expect(OlderPeer.sentence(notAProviderCreate, from: .controlPlane, runs: "0.17.0", app: "0.18.0")
                == "The control plane needs an update to do this. It runs Agents 0.17.0; this app is 0.18.0.")
        let unknown = JSONRPCError(code: JSONRPCError.methodNotFound, message: "method not found")
        #expect(OlderPeer.sentence(unknown, from: .machine, runs: "0.9.2", app: "0.18.0")
                == "This machine needs an update to do this. It runs Agents 0.9.2; this app is 0.18.0.")
    }

    @Test func theSameVersionOrNewerIsARealFault() {
        #expect(OlderPeer.sentence(notAProviderCreate, from: .controlPlane, runs: "0.18.0", app: "0.18.0") == nil)
        #expect(OlderPeer.sentence(notAProviderCreate, from: .controlPlane, runs: "0.19.0", app: "0.18.0") == nil)
        #expect(OlderPeer.sentence(notAProviderCreate, from: .controlPlane, runs: nil, app: "0.18.0") == nil)
    }

    @Test func otherRefusalsAreNotAboutTheVersion() {
        let busy = JSONRPCError(code: -32005, message: "No such agent.")
        #expect(OlderPeer.sentence(busy, from: .controlPlane, runs: "0.17.0", app: "0.18.0") == nil)
    }

    @Test func theControlPlanesRefusalUsesTheVersionLastRead() {
        defer { OlderPeer.controlVersion = nil }
        OlderPeer.controlVersion = "0.17.0"
        // A test bundle has no app version, so the control plane's words stay as they were.
        if OlderPeer.appVersion == nil {
            #expect(OlderPeer.controlRefusal(notAProviderCreate) == "Those parameters are not a ProviderCreate.")
        }
        OlderPeer.controlVersion = OlderPeer.appVersion
        #expect(OlderPeer.controlRefusal(notAProviderCreate) == "Those parameters are not a ProviderCreate.")
    }

    @Test func versionsCompareByNumber() {
        #expect(OlderPeer.isOlder("0.9.0", than: "0.10.0"))
        #expect(OlderPeer.isOlder("v0.17.0", than: "0.18.0"))
        #expect(!OlderPeer.isOlder("0.18.1-dev.3+gabc", than: "0.18.1"))
        #expect(OlderPeer.isOlder("0.18", than: "0.18.1"))
        #expect(!OlderPeer.isOlder("dev", than: "0.18.0"))
    }
}
