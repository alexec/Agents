import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore
import ControlDial

/// A fake iPhone on the bare wire while the Mac's host restarts behind a real control plane
/// (#77): its connection ends rather than staying open on a daemon that knows nothing of
/// it, and it is answered again once the host is back.
///
///     AGENTS_RESTART_DEVICE_CODE='agents-control:2:c:device:…' \
///     AGENTS_RESTART_ROOT=/tmp/run-xyz \
///     AGENTS_RESTART_AGENTSD='…/Agents Host.app/Contents/Helpers/agentsd' \
///       swift test --filter HostRestartLiveTests
///
/// The root is a run-app scratch root; the host is stopped by the pid in that root's
/// `daemon.lock` and started again on it with `--control-network`, nothing else.
@Suite("A fake iPhone while the host restarts",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_RESTART_DEVICE_CODE"] != nil),
       .serialized, .timeLimit(.minutes(5)))
struct HostRestartLiveTests {
    let environment = ProcessInfo.processInfo.environment

    @Test func aHostRestartEndsTheBareConnectionAndTheDeviceIsAnsweredAgain() async throws {
        let code = try #require(ControlCode(text: environment["AGENTS_RESTART_DEVICE_CODE"] ?? ""))
        let root = URL(filePath: try #require(environment["AGENTS_RESTART_ROOT"]), directoryHint: .isDirectory)
        let agentsd = URL(filePath: try #require(environment["AGENTS_RESTART_AGENTSD"]))

        let key = ControlAgreement.generate()
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key.privateKey, id: UUID(), name: "Fake iPhone",
                                                             kind: .iPhone, dial: FakeDeviceLiveTests.dial)
        let dial = try ControlCodeUse.clientDial(membership, privateKey: key.privateKey, kind: "iphone",
                                                 dial: FakeDeviceLiveTests.dial)
        let phone = DaemonClient(link: FakeDeviceLiveTests.FixedLink(make: dial))
        try await phone.connect(startIfNeeded: false)
        _ = try await phone.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false))
        print("restart: connected on the bare wire")

        // The host goes.
        let lock = try String(contentsOf: root.appending(path: "daemon.lock"), encoding: .utf8)
        let pid = try #require(Int32(lock.trimmingCharacters(in: .whitespacesAndNewlines)))
        let started = ContinuousClock.now
        kill(pid, SIGTERM)

        // Its connection ends: the control plane let the bare session go with the host.
        let ended = await eventually("the bare connection ended", within: .seconds(30)) { await !phone.isConnected }
        #expect(ended)
        print("restart: the bare connection ended \(ContinuousClock.now - started) after the host was stopped")

        // The host comes back on the same root, as launchd would start it.
        let host = Process()
        host.executableURL = agentsd
        host.arguments = ["--control-network"]
        var hostEnvironment = environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("AGENTS_") }
        hostEnvironment["AGENTS_ROOT"] = root.path(percentEncoded: false)
        host.environment = hostEnvironment
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        try host.run()
        let back = ContinuousClock.now

        // And the phone is answered again on a fresh connection.
        var answered = false
        while ContinuousClock.now - back < .seconds(60), !answered {
            if (try? await phone.connect(startIfNeeded: false)) != nil,
               (try? await DaemonClient.$patience.withValue(.seconds(5)) {
                   try await phone.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false))
               }) != nil {
                answered = true
            } else {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        #expect(answered, "the phone was not answered within a minute of the host coming back")
        print("restart: answered again \(ContinuousClock.now - back) after the host was started")
    }
}
