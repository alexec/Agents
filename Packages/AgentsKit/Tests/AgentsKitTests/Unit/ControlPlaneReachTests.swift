import Foundation
import Testing
@testable import AgentsKitCore

/// What the Remote says when it can't reach its control plane (#4916): "your Mac" only when
/// the control plane runs on the home Mac.
struct ControlPlaneReachTests {
    private let mac = MachineRef(rawValue: "mac")

    private func host(_ id: MachineRef, machineID: String?) -> DaemonAPI.ControlMachine {
        DaemonAPI.ControlMachine(id: id, name: "Alex's Mac", platform: "macOS", version: "0.17",
                                 state: "online", reach: "direct", machineID: machineID)
    }

    @Test func onTheHomeMacWhenItsMachineIsTheControlPlanes() {
        let status = DaemonAPI.ControlStatus(name: "c", version: "0.17", homeHost: mac, machineID: "m1")
        #expect(ControlPlaneReach.onHomeMac(status, hosts: [host(mac, machineID: "m1")]))
    }

    @Test func elsewhereWhenTheMachinesDiffer() {
        let status = DaemonAPI.ControlStatus(name: "c", version: "0.17", homeHost: mac, machineID: "cloud")
        #expect(!ControlPlaneReach.onHomeMac(status, hosts: [host(mac, machineID: "m1")]))
    }

    @Test func elsewhereWithNoHomeHostOrNoMachineID() {
        let none = DaemonAPI.ControlStatus(name: "c", version: "0.17", homeHost: nil, machineID: "m1")
        #expect(!ControlPlaneReach.onHomeMac(none, hosts: [host(mac, machineID: "m1")]))
        let unknown = DaemonAPI.ControlStatus(name: "c", version: "0.17", homeHost: mac, machineID: "m1")
        #expect(!ControlPlaneReach.onHomeMac(unknown, hosts: [host(mac, machineID: nil)]))
        #expect(!ControlPlaneReach.onHomeMac(unknown, hosts: []))
    }

    @Test func addressIsTheURLsHost() {
        #expect(ControlPlaneReach.address(of: "wss://control.example.com:443/v1/connect") == "control.example.com")
        #expect(ControlPlaneReach.address(of: nil) == nil)
        #expect(ControlPlaneReach.address(of: "not a url") == nil)
    }

    @Test func theMacsWordsNameTheMac() {
        let reach = ControlPlaneReach()
        #expect(reach.title == "Can't reach your Mac")
        #expect(reach.detail.hasPrefix("It needs to be awake"))
        #expect(reach.banner(lastHeard: nil) == "Not connected to your Mac yet")
        #expect(reach.banner(lastHeard: "5 min ago") == "Last heard from your Mac 5 min ago")
        #expect(reach.notAnswering.hasPrefix("Your Mac is not answering."))
    }

    @Test func elsewhereTheWordsNameTheControlPlaneAndItsAddress() {
        let reach = ControlPlaneReach(onHomeMac: false, address: "control.example.com")
        #expect(reach.title == "Can't reach the control plane")
        #expect(reach.detail.hasPrefix("The control plane at control.example.com does not answer."))
        #expect(!reach.detail.contains("Mac"))
        #expect(reach.banner(lastHeard: "5 min ago") == "Last heard from the control plane 5 min ago")
        #expect(reach.banner(lastHeard: nil) == "Not connected to the control plane yet")
        #expect(reach.notAnswering.hasPrefix("The control plane is not answering."))
        #expect(ControlPlaneReach(onHomeMac: false).detail.hasPrefix("The control plane does not answer."))
    }
}
