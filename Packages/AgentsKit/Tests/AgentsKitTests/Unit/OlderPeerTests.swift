import AgentsKitCore
import Testing

/// What the Mac and the Remote say when an older control plane or machine refuses a call (#4096).
/// Serialized: the versions this app last read are kept once for the whole app.
@Suite(.serialized)
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

    private func machine(_ id: String, _ version: String) -> DaemonAPI.ControlMachine {
        DaemonAPI.ControlMachine(id: MachineRef(rawValue: id), name: id, platform: "linux", version: version,
                                 state: "running", reach: "online", machineID: nil)
    }

    /// #4101: a host older than the app, behind a control plane of the same version.
    @Test func anOlderMachinesRefusalNeedsAnUpdate() {
        defer { OlderPeer.know([], home: nil) }
        OlderPeer.know([machine("devbox", "0.17.0"), machine("home", "0.18.0")], home: MachineRef(rawValue: "home"))
        let older = OlderPeer.machineRefusal(notAProviderCreate, from: MachineRef(rawValue: "devbox"), app: "0.18.0")
        #expect(older.message == "This machine needs an update to do this. It runs Agents 0.17.0; this app is 0.18.0.")
        #expect(older.code == JSONRPCError.invalidParams)
        // The same version, the home machine by `.mac`, or one not listed: the machine's own words.
        #expect(OlderPeer.machineRefusal(notAProviderCreate, from: MachineRef(rawValue: "home"), app: "0.18.0") == notAProviderCreate)
        #expect(OlderPeer.machineRefusal(notAProviderCreate, from: .mac, app: "0.18.0") == notAProviderCreate)
        #expect(OlderPeer.machineRefusal(notAProviderCreate, from: MachineRef(rawValue: "gone"), app: "0.18.0") == notAProviderCreate)
    }

    @Test func theHomeMachineIsKnownAsMac() {
        defer { OlderPeer.know([], home: nil) }
        OlderPeer.know([machine("home", "0.17.0")], home: MachineRef(rawValue: "home"))
        #expect(OlderPeer.version(of: .mac) == "0.17.0")
        let older = OlderPeer.machineRefusal(notAProviderCreate, from: .mac, app: "0.18.0")
        #expect(older.message.hasPrefix("This machine needs an update"))
    }

    /// A machine's words are not replaced by the control plane's when both are older.
    @Test func aMachinesWordsStay() {
        defer { OlderPeer.know([], home: nil); OlderPeer.controlVersion = nil }
        OlderPeer.know([machine("devbox", "0.17.0")], home: nil)
        let older = OlderPeer.machineRefusal(notAProviderCreate, from: MachineRef(rawValue: "devbox"), app: "0.18.0")
        OlderPeer.controlVersion = "0.0.1"
        #expect(OlderPeer.controlRefusal(older) == older.message)
    }
}
