import Foundation
import Testing
@testable import AgentsKitCore

/// A machine's row under Machines (#3973): its dot, its menu and swipes, and Delete's question.
/// The web page's machineRow is tested with the same cases (#3974).
@Suite("A machine's row, in the sidebar")
struct MachineRowActionsTests {
    private func row(_ state: String, workspace: Bool = true, canStart: Bool = true,
                     canStop: Bool = true) -> DaemonAPI.ControlMachine {
        var row = DaemonAPI.ControlMachine(id: MachineRef(rawValue: "devbox"), name: "devbox", platform: "linux", version: "0.17",
                                           state: state, reach: "direct", machineID: nil)
        if workspace {
            row.workspace = DaemonAPI.MachineWorkspace(provider: ProviderID(rawValue: "do"), providerName: "DigitalOcean",
                                                       workspace: "w", workspaceName: "w", workspaceState: state,
                                                       canStart: canStart, canStop: canStop)
        }
        return row
    }

    @Test func theDotSaysOnlyTheMachinesOwnState() {
        #expect(MachineDot.of(row("online"), online: true, starting: false) == .online)
        #expect(MachineDot.of(row("starting"), online: false, starting: false) == .busy)
        #expect(MachineDot.of(row("stopped"), online: false, starting: true) == .busy)
        #expect(MachineDot.of(row("stopped"), online: false, starting: false) == .stopped)
        #expect(MachineDot.of(row("offline", workspace: false), online: false, starting: false) == .offline)
        #expect(MachineDot.of(row("needsUpdate"), online: true, starting: false) == .attention)
        #expect(MachineDot.of(nil, online: true, starting: false) == .online)
    }

    @Test func aMadeMachineStartsStopsAndDeletes() {
        #expect(MachineRowActions.of(row("stopped"), isThisMac: false) == MachineRowActions(start: true, delete: true))
        #expect(MachineRowActions.of(row("online"), isThisMac: false) == MachineRowActions(stop: true, delete: true))
        #expect(MachineRowActions.of(row("starting"), isThisMac: false) == MachineRowActions(delete: true))
        #expect(MachineRowActions.of(row("online", canStop: false), isThisMac: false) == MachineRowActions(delete: true))
    }

    @Test func aRegisteredMachineIsOnlyRemoved() {
        #expect(MachineRowActions.of(row("online", workspace: false), isThisMac: false) == MachineRowActions(remove: true))
    }

    @Test func thisMacOffersNothing() {
        #expect(MachineRowActions.of(row("online"), isThisMac: true) == MachineRowActions())
        #expect(MachineRowActions.of(nil, isThisMac: false) == MachineRowActions())
    }

    @Test func deleteSaysHowManySessionsStop() {
        #expect(MachineRowActions.deleteMessage(row("online"), sessions: 0) == "DigitalOcean deletes this machine and its disk.")
        #expect(MachineRowActions.deleteMessage(row("online"), sessions: 1)
                == "DigitalOcean deletes this machine and its disk. 1 session on it stops.")
        #expect(MachineRowActions.deleteMessage(row("online"), sessions: 2)
                == "DigitalOcean deletes this machine and its disk. 2 sessions on it stop.")
    }
}
