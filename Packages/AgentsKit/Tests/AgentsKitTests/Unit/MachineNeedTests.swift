import Foundation
import Testing
@testable import AgentsKitCore

/// A machine's grey line under Machines (#3764): the most urgent need, or none. The web page's
/// machineNeed is tested with the same cases.
@Suite("What a machine needs, in the sidebar")
struct MachineNeedTests {
    private func row(_ state: String, workspace: String? = nil, problem: String? = nil) -> DaemonAPI.ControlMachine {
        var row = DaemonAPI.ControlMachine(id: MachineRef(rawValue: "devbox"), name: "devbox", platform: "linux", version: "0.17",
                                           state: state, reach: "direct", machineID: nil)
        row.workspace = workspace.map {
            DaemonAPI.MachineWorkspace(provider: ProviderID(rawValue: "coder"), providerName: "Coder", workspace: "w", workspaceName: "w",
                                       workspaceState: $0, problem: problem, canStart: true)
        }
        return row
    }

    private func runtime(_ name: String, _ availability: RuntimeAvailability,
                         signIn: RuntimeStatus.SignIn? = nil) -> RuntimeStatus {
        var status = RuntimeStatus(runtime: Runtime(id: name.lowercased(), name: name, executable: name, arguments: []),
                                   availability: availability)
        status.signIn = signIn
        return status
    }

    private let available = RuntimeAvailability.available(path: "/p", supportsResume: true)
    private var notSignedIn: RuntimeStatus { runtime("Claude", .needsSignIn(authMethods: [], fixCommand: nil)) }

    @Test func aMachineThatNeedsNothingSaysNothing() {
        #expect(MachineNeed.most(row: row("online"), offline: false, runtimes: [runtime("Claude", available)]) == nil)
        #expect(MachineNeed.most(row: nil, offline: false, runtimes: []) == nil)
    }

    @Test func offlineGoesBeforeEverythingElse() {
        #expect(MachineNeed.most(row: row("offline"), offline: true, runtimes: [notSignedIn]) == .offline)
        #expect(MachineNeed.most(row: nil, offline: true, runtimes: []) == .offline)
    }

    @Test func aStoppedWorkspaceSaysStopped() {
        #expect(MachineNeed.most(row: row("stopped", workspace: "stopped"), offline: true, runtimes: []) == .stopped)
        #expect(MachineNeed.most(row: row("starting", workspace: "starting"), offline: true, runtimes: []) == .stopped)
        #expect(MachineNeed.most(row: row("failed", workspace: "failed", problem: "No quota"), offline: true, runtimes: [])
                == .stopped)
        // Its workspace runs, so agentsd is what went.
        #expect(MachineNeed.most(row: row("offline", workspace: "running"), offline: true, runtimes: []) == .offline)
    }

    @Test func aFailedSetUpSaysSo() {
        #expect(MachineNeed.most(row: row("failed"), offline: true, runtimes: []) == .setupFailed)
    }

    private func disk(_ volume: String, _ level: DiskLevel, free: Int64) -> DiskAlarm {
        DiskAlarm(reading: DiskReading(volume: volume, mount: "/\(volume)", freeBytes: free, totalBytes: 494 * DiskSpace.gigabyte),
                  level: level, threshold: 24_700_000_000)
    }

    @Test func aLowDiskSaysWhyTheIconIsRed() {
        let low = disk("Data", .low, free: 24_100_000_000)
        let full = disk("Scratch", .critical, free: 1_800_000_000)
        #expect(MachineNeed.most(row: row("needsUpdate"), offline: false, runtimes: [notSignedIn], disks: [low]) == .disk(low))
        #expect(MachineNeed.most(row: row("online"), offline: false, runtimes: [], disks: [low, full]) == .disk(full))
        #expect(MachineNeed.most(row: row("online"), offline: false, runtimes: [],
                                 disks: [disk("Data", .ok, free: 300 * DiskSpace.gigabyte)]) == nil)
        // An offline machine cannot say how its disk is now.
        #expect(MachineNeed.most(row: row("failed"), offline: true, runtimes: [], disks: [low]) == .setupFailed)
        #expect(DiskSpace.needWords(low) == "Disk low: 24.1 GB free")
        #expect(DiskSpace.needWords(full) == "Disk almost full: 1.8 GB free")
    }

    @Test func anUpdateGoesBeforeSignIn() {
        #expect(MachineNeed.most(row: row("needsUpdate"), offline: false, runtimes: [notSignedIn]) == .update)
    }

    @Test func signInNamesEachRuntimeNotSignedIn() {
        let runtimes = [notSignedIn, runtime("Codex", available, signIn: .init(signedIn: false)),
                        runtime("Grok", available, signIn: .init(signedIn: false, relayed: true)),
                        runtime("Copilot", available, signIn: .init(signedIn: true)),
                        runtime("OpenCode", .missing(lookedIn: []))]
        #expect(MachineNeed.most(row: row("online"), offline: false, runtimes: runtimes) == .signIn(["Claude", "Codex"]))
    }
}
