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

    private func provider(_ id: String, _ workspaces: [DaemonAPI.MachineInfo]) -> DaemonAPI.ProviderSummary {
        DaemonAPI.ProviderSummary(id: ProviderID(rawValue: id), name: id.capitalized, kind: "command",
                                  capabilities: ["create"], workspaces: workspaces)
    }

    /// A machine New Machine made has a row until it joins (#4610): Making… while the control
    /// plane waits, the reason once it gave up; none once linked, or once a machine of its name is here.
    @Test func aMadeMachineHasARowUntilItJoins() throws {
        let making = DaemonAPI.MachineInfo(id: "ws-1", name: "machine-1", state: "starting", joining: true)
        let gaveUp = DaemonAPI.MachineInfo(id: "ws-2", name: "machine-2", state: "running",
                                           notJoined: "Made at Do, but it didn’t join in 10 minutes.")
        let linked = DaemonAPI.MachineInfo(id: "ws-3", name: "machine-3", state: "running",
                                           host: MachineRef(rawValue: "h3"), joining: true)
        let joinedByName = DaemonAPI.MachineInfo(id: "ws-4", name: "machine-4", state: "running", joining: true)
        let plain = DaemonAPI.MachineInfo(id: "ws-5", name: "old", state: "running")
        let rows = MachineMaking.rows([provider("do", [gaveUp, plain, making, linked, joinedByName])], hostNames: ["machine-4"])
        #expect(rows.map(\.name) == ["machine-1", "machine-2"])
        let still = try #require(rows.first)
        let gone = try #require(rows.last)
        #expect(still.line == "Making…")
        #expect(still.notJoined == nil)
        #expect(gone.line == "Made at Do, but it didn’t join in 10 minutes.")
        #expect(gone.id == "do/ws-2")
        #expect(gone.deleteMessage == "Do deletes machine-2. Nothing was installed on it, so there is nothing to back up.")
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

    @Test func deleteNamesTheWorktreesWithWorkNotPushed() {
        let work = DaemonAPI.UnpushedWork(folder: URL(fileURLWithPath: "/src/Agents"), worktree: URL(fileURLWithPath: "/src/Agents/wt"),
                                          branch: "agents/fix-3928", ahead: 3)
        let preview = DaemonAPI.StartedMachinePreview(host: MachineRef(rawValue: "devbox"), name: "devbox", state: "online",
                                                      unpushed: [work])
        #expect(MachineRowActions.deleteMessage(row("online"), sessions: 0, preview: preview)
                == "DigitalOcean deletes this machine and its disk. 1 worktree has work not pushed, which is lost:\n"
                + "Agents · agents/fix-3928 (3 commits not pushed)")
        #expect(MachineRowActions.deleteMessage(row("online"), sessions: 0, asking: true)
                == "DigitalOcean deletes this machine and its disk. Asking devbox what work on it is not pushed…")
        let offline = DaemonAPI.StartedMachinePreview(host: MachineRef(rawValue: "devbox"), name: "devbox", state: "stopped",
                                                      unknown: "devbox is not online, so it could not be asked.")
        #expect(MachineRowActions.deleteMessage(row("stopped"), sessions: 0, preview: offline)
                == "DigitalOcean deletes this machine and its disk. devbox is not online, so it could not be asked.")
    }

    @Test func theIconSaysTheStateMostUrgentFirst() {
        #expect(MachineIcon.of(.online, diskLow: false) == .accent)
        #expect(MachineIcon.of(.busy, diskLow: true) == .busy)
        #expect(MachineIcon.of(.offline, diskLow: false) == .failure)
        #expect(MachineIcon.of(.online, diskLow: true) == .failure)
        #expect(MachineIcon.of(.attention, diskLow: true) == .failure)
        #expect(MachineIcon.of(.attention, diskLow: false) == .attention)
        #expect(MachineIcon.of(.stopped, diskLow: false) == .stopped)
    }

    @Test func theIconsShapeSaysTheKind() {
        #expect(MachineIcon.symbol(isThisMac: true, row: row("online")) == "laptopcomputer")
        #expect(MachineIcon.symbol(isThisMac: false, row: row("online")) == "cloud")
        #expect(MachineIcon.symbol(isThisMac: false, row: row("online", workspace: false)) == "server.rack")
    }
}
