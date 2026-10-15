import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

// Stop a workspace when idle (#691 US4): a linked host that says it is idle for its whole
// set time is stopped, and says so; a turn in between starts the count again; and Stop asks
// first while agents are working there. A minute is 20 ms here.

extension ProviderHarness {
    static let quick = WorkspaceProviders.Timing(listEvery: .seconds(3600), sshAfter: .seconds(3600), giveUp: .seconds(3600),
                                                 lookEvery: .milliseconds(20), calls: .standard,
                                                 idleMinute: .milliseconds(20))

    /// Linked, online, its workspace running, stopping after `minutes` idle.
    func onlineAndLinked(stopAfter minutes: Int) async throws {
        try await link(try await add())
        _ = try await call(DaemonAPI.Method.hostsSetWorkspaceOptions,
                           try JSONValue.encoding(DaemonAPI.HostWorkspaceOptions(host: devbox, stopWhenIdleMinutes: minutes)))
        await router.setState(.online, of: devbox)
    }

    func said(_ idle: Bool, running: [String] = []) async {
        await providers.heard(devbox, status: DaemonAPI.HostStatus(idle: idle, running: running))
    }
}

@Suite("Stop when idle (#691 US4)")
struct IdleStopsTests {
    @Test func idleForTheWholeTimeStopsItAndSaysWhy() async throws {
        let h = try await ProviderHarness(timing: ProviderHarness.quick)
        try await h.onlineAndLinked(stopAfter: 2)
        await h.said(true)
        for _ in 0..<200 where await h.provider.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await h.provider.stops == 1)
        await h.router.setState(.offline(since: Date()), of: h.devbox)
        let row = try await h.waitFor("stopped")
        #expect(row.workspace?.stoppedBy == "Stopped by Agents after 2 minutes idle")
    }

    @Test func aTurnInBetweenStartsTheCountAgain() async throws {
        let h = try await ProviderHarness(timing: ProviderHarness.quick)
        try await h.onlineAndLinked(stopAfter: 5)   // 100 ms
        await h.said(true)
        try await Task.sleep(for: .milliseconds(60))
        await h.said(false, running: ["Claude (fix-login)"])
        try await Task.sleep(for: .milliseconds(80))
        // Past when the first count would have ended.
        #expect(await h.provider.stops == 0)
        await h.said(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.provider.stops == 0)
        for _ in 0..<200 where await h.provider.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await h.provider.stops == 1)
    }

    @Test func aHostThatNeverSaysIsNeverStoppedAsIdle() async throws {
        let h = try await ProviderHarness(timing: ProviderHarness.quick)
        try await h.onlineAndLinked(stopAfter: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.provider.stops == 0)
    }

    @Test func offStopsNothing() async throws {
        let h = try await ProviderHarness(timing: ProviderHarness.quick)
        try await h.onlineAndLinked(stopAfter: 0)
        await h.said(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.provider.stops == 0)
    }

    @Test func stopWhileAgentsWorkAsksFirstAndNamesThem() async throws {
        let h = try await ProviderHarness(timing: ProviderHarness.quick)
        try await h.onlineAndLinked(stopAfter: 30)
        await h.said(false, running: ["Claude (fix-login)", "Codex (docs)"])
        do {
            _ = try await h.call(DaemonAPI.Method.hostsStop, try JSONValue.encoding(DaemonAPI.HostStop(host: h.devbox)))
            Issue.record("stopped without asking")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.agentsWorking)
            #expect(error.message == "Stop devbox? Claude (fix-login) and Codex (docs) are working there.")
        }
        #expect(await h.provider.stops == 0)
        _ = try await h.call(DaemonAPI.Method.hostsStop,
                             try JSONValue.encoding(DaemonAPI.HostStop(host: h.devbox, confirmRunning: true)))
        for _ in 0..<200 where await h.provider.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await h.provider.stops == 1)
    }

    @Test func aPersonsStopIsNotSaidToBeAgents() async throws {
        let h = try await ProviderHarness(timing: ProviderHarness.quick)
        try await h.onlineAndLinked(stopAfter: 30)
        _ = try await h.call(DaemonAPI.Method.hostsStop, try JSONValue.encoding(DaemonAPI.HostStop(host: h.devbox)))
        for _ in 0..<200 where await h.provider.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await h.router.setState(.offline(since: Date()), of: h.devbox)
        let row = try await h.waitFor("stopped")
        #expect(row.workspace?.stoppedBy == nil)
    }

    /// Its idle status comes as it connects, before the start is done (seen on the #1004 walk).
    @Test func aHostIdleAsItsStartEndsIsStoppedAfterItsIdleTime() async throws {
        let h = try await ProviderHarness(timing: ProviderHarness.quick)
        try await h.link(try await h.add())
        _ = try await h.call(DaemonAPI.Method.hostsSetWorkspaceOptions,
                             try JSONValue.encoding(DaemonAPI.HostWorkspaceOptions(host: h.devbox, stopWhenIdleMinutes: 2)))
        await h.provider.set(startTakes: .milliseconds(100))
        _ = try await h.call(DaemonAPI.Method.hostsStart, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        await h.router.setState(.online, of: h.devbox)
        await h.said(true)
        _ = try await h.waitFor("online") { $0.workspace?.canStop == true }
        for _ in 0..<200 where await h.provider.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await h.provider.stops == 1)
    }

    @Test func minutesAreSaidAsAPersonWould() {
        #expect(WorkspaceProviders.words(minutes: 30) == "30 minutes")
        #expect(WorkspaceProviders.words(minutes: 60) == "1 hour")
        #expect(WorkspaceProviders.words(minutes: 120) == "2 hours")
        #expect(WorkspaceProviders.list(["A"]) == "A")
        #expect(WorkspaceProviders.list(["A", "B", "C"]) == "A, B and C")
    }
}
