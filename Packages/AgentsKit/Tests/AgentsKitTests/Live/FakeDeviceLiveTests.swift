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
/// It pairs with the code; connects as the device; then checks it may do what the window
/// may (#111), the bare way (its connection's home host) and the wrapped way (every host).
@Suite("A fake iPhone through a control plane",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_CODE"] != nil),
       .serialized, .timeLimit(.minutes(30)))
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
            let folders = try await phone.call(DaemonAPI.Method.foldersList, DaemonAPI.FoldersListRequest(includeArchived: false),
                                                returning: [DaemonAPI.FolderSummary].self)
            print("fake-device: bare folders/list → \(folders.map(\.name))")
            await expectNotRefused(phone, DaemonAPI.Method.credentialsOffer, "bare")
        }

        // 4. The wrapped wire, over one more connection: every host.
        let wrapped = ControlLink(dial: dial)
        let control = DaemonClient(link: wrapped.controlLink)
        try await control.connect(startIfNeeded: false)
        let hosts = try await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlMachine].self)
        print("fake-device: hosts/list → \(hosts.map { "\($0.name) (\($0.id), \($0.state))" })")
        for host in hosts where host.state == "online" {
            let there = DaemonClient(link: wrapped.link(for: host.id))
            try await there.connect(startIfNeeded: false)
            let listed = try await there.call(DaemonAPI.Method.foldersList, DaemonAPI.FoldersListRequest(includeArchived: false),
                                              returning: [DaemonAPI.FolderSummary].self)
            print("fake-device: \(host.name) folders → \(listed.map(\.name))")
            await expectNotRefused(there, DaemonAPI.Method.runtimesInstall, "on \(host.id)")
        }
        let clients = try await control.call(DaemonAPI.Method.clientsList)
        print("fake-device: clients/list → \(clients.arrayValue?.count ?? 0) clients")
        wrapped.disconnect()
        await phone.disconnect()
        print("FAKE-DEVICE-ID \(id)")
    }

    /// A call only the window could make before #111, which a device may make now: asked
    /// with no params, so it does nothing, and the answer is about the params (-32602),
    /// never `notPermitted`.
    func expectNotRefused(_ client: DaemonClient, _ method: String, _ how: String) async {
        do {
            _ = try await client.call(method)
            print("fake-device: \(how) \(method) answered")
        } catch let error as JSONRPCError {
            #expect(error.code != DaemonAPI.Failure.notPermitted, "\(how) \(method) refused to a device")
            print("fake-device: \(how) \(method) not refused (\(error.code))")
        } catch {
            Issue.record("\(how) \(method): \(error)")
        }
    }

    /// The move's own live test (US7) still uses this name for the first build's link.
    typealias Fixed = FixedLink

    struct FixedLink: DaemonLink {
        let make: @Sendable () async throws -> any LineTransport
        func transport() async throws -> any LineTransport { try await make() }
        func start() async throws {}
    }
}
