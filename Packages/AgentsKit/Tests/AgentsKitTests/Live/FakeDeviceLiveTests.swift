import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A fake iPhone against a control plane, dialling exactly as the Remote does since 058's
/// US5 (T078): a version 2 device code, then the control plane's one address over
/// `URLSession`'s WebSocket with the pin from the code, and a key of its own.
///
///     AGENTS_FAKE_DEVICE_CODE='agents-control:2:c:device:…' swift test --filter FakeDeviceLiveTests
///
/// It pairs with the code; connects as the device; then says what it could and could not
/// do, the bare way (its connection's home host) and the wrapped way (every host).
/// `AGENTS_FAKE_DEVICE_RELAY=1`, through `agents-relay`, comes with T096.
@Suite("A fake iPhone through a control plane",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_CODE"] != nil),
       .serialized, .timeLimit(.minutes(2)))
struct FakeDeviceLiveTests {
    let codeText = ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_CODE"] ?? ""

    static let dial: ControlCodeUse.Dial = { url, pin in try await WebSocketLink.connect(url, pin: pin) }

    @Test func pairConnectAndSeeEveryHostAsADevice() async throws {
        // 1. Pair with the device code, as the Remote does after a scan.
        let code = try #require(ControlCode(text: codeText), "AGENTS_FAKE_DEVICE_CODE is not a code")
        let key = ControlAgreement.generate()
        let id = UUID()
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key.privateKey, id: id, name: "Fake iPhone",
                                                             kind: .iPhone, dial: Self.dial)
        print("fake-device: paired with \(code.name) as \(id)")

        // 2. Connect as the device: over WebSocketLink, with the pin.
        let dial = try ControlCodeUse.clientDial(membership, privateKey: key.privateKey, kind: "iphone", dial: Self.dial)
        let phone = DaemonClient(link: FixedLink(make: dial))
        try await phone.connect(startIfNeeded: false)

        // 3. Bare lines reach the home host, as a device.
        let status = try await phone.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        print("fake-device: control/status → \(status.name), home host \(status.homeHost?.rawValue ?? "-")")
        if status.homeHost != nil {
            let projects = try await phone.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                                                returning: [DaemonAPI.ProjectSummary].self)
            print("fake-device: bare projects/list → \(projects.map(\.name))")
            do {
                _ = try await phone.call(DaemonAPI.Method.credentialsLend)
                Issue.record("the device lent a credential")
            } catch let error as JSONRPCError {
                #expect(error.code == DaemonAPI.Failure.notPermitted)
                print("fake-device: credentials/lend refused (\(error.code))")
            }
        }

        // 4. The wrapped wire, over one more connection: every host.
        let wrapped = ControlLink(dial: dial)
        let control = DaemonClient(link: wrapped.controlLink)
        try await control.connect(startIfNeeded: false)
        let hosts = try await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        print("fake-device: hosts/list → \(hosts.map { "\($0.name) (\($0.id), \($0.state))" })")
        for host in hosts where host.state == "online" {
            let there = DaemonClient(link: wrapped.link(for: host.id))
            try await there.connect(startIfNeeded: false)
            let listed = try await there.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                                              returning: [DaemonAPI.ProjectSummary].self)
            print("fake-device: \(host.name) projects → \(listed.map(\.name))")
            do {
                _ = try await there.call(DaemonAPI.Method.runtimesInstall, ["runtime": "claude"])
                Issue.record("the device installed a runtime")
            } catch let error as JSONRPCError {
                print("fake-device: on \(host.id) an operator-only call was refused (\(error.code))")
            }
        }
        do {
            _ = try await control.call(DaemonAPI.Method.clientsList)
            Issue.record("the device listed clients")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.notPermitted)
            print("fake-device: clients/list refused by the control plane (\(error.code))")
        }
        wrapped.disconnect()
        await phone.disconnect()
        print("FAKE-DEVICE-ID \(id)")
    }

    /// The move's own live test (US7) still uses this name for the first build's link.
    typealias Fixed = FixedLink

    struct FixedLink: DaemonLink {
        let make: @Sendable () async throws -> any LineTransport
        func transport() async throws -> any LineTransport { try await make() }
        func start() async throws {}
    }
}
