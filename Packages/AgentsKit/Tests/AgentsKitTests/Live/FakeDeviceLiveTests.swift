#if canImport(Network) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Network
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A fake iPhone against a scratch control plane and its bridge, for the 058 US4 walk:
/// paired and connected exactly as the Remote is, over the bridge's TLS direct link.
///
///     AGENTS_FAKE_DEVICE_CONTROL=<control root> AGENTS_FAKE_DEVICE_PORT=<bridge port> \
///       swift test --filter FakeDeviceLiveTests
///
/// It asks this Mac's host for a pairing code through the control plane, as the window's
/// Pair a Device does; announces a new device with it; connects as that device; then says
/// what it could and could not do, the old bare way and the new wrapped way.
@Suite("A fake iPhone through a scratch control plane",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_CONTROL"] != nil),
       .serialized, .timeLimit(.minutes(2)))
struct FakeDeviceLiveTests {
    let control = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_CONTROL"] ?? "/nowhere")
    let port = NWEndpoint.Port(ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_PORT"] ?? "8799")!

    struct Fixed: DaemonLink {
        let make: @Sendable () async throws -> any LineTransport
        func transport() async throws -> any LineTransport { try await make() }
    }

    func dial(identity: String, key: SymmetricKey) async throws -> NWTransport {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: LinkTLS.client(identity: identity, key: key))
        let transport = NWTransport(connection: connection)
        try await transport.waitUntilReady()
        return transport
    }

    @Test func pairConnectAndSeeEveryHostAsADevice() async throws {
        // 1. A pairing code from this Mac's host, asked through the control plane.
        let socket = ControlPlane.clientSocket(root: control).path
        let window = ControlLink { FDTransport(socket: try connectUnixSocket(path: socket)) }
        let mac = DaemonClient(link: window.link(for: .mac))
        try await mac.connect(startIfNeeded: false)
        let code = try await mac.call(DaemonAPI.Method.devicesStartPairing, returning: DaemonAPI.PairingCode.self)
        print("fake-device: pairing code for \(code.name)")

        // 2. Announce a new iPhone over the pairing identity, as the Remote does after a scan.
        let key = DeviceKey.ephemeral()
        let id = UUID()
        // The bridge takes the code's key once it has heard of it, a moment after.
        var opened: NWTransport?
        for _ in 0..<20 where opened == nil {
            opened = try? await dial(identity: LinkKey.pairingIdentity(code.secret), key: LinkKey.pairing(code.secret))
            if opened == nil { try await Task.sleep(for: .milliseconds(300)) }
        }
        let pairing = try #require(opened, "the bridge never took the pairing code's key")
        let announcing = DaemonClient(link: Fixed { pairing })
        try await announcing.connect(startIfNeeded: false)
        _ = try await announcing.call(DaemonAPI.Method.devicesAnnounce,
                                      DaemonAPI.DeviceAnnouncement(id: id, publicKey: key.publicKey,
                                                                   name: "Fake iPhone", kind: .iPhone))
        await announcing.disconnect()
        print("fake-device: announced \(id)")

        // 3. Connect as the device, once the bridge listens with its key.
        let psk = try key.linkKey(with: code.macKey, device: id)
        let identity = LinkKey.deviceIdentity(id)
        var device: DaemonClient?
        for _ in 0..<30 {
            if let transport = try? await dial(identity: identity, key: psk) {
                let client = DaemonClient(link: Fixed { transport })
                if (try? await client.connect(startIfNeeded: false)) != nil { device = client; break }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let phone = try #require(device, "the bridge never took the new device's key")

        // 4. Today's Remote: bare lines reach this Mac's host, as a device.
        let projects = try await phone.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                                            returning: [DaemonAPI.ProjectSummary].self)
        print("fake-device: bare projects/list → \(projects.map(\.name))")
        let status = try await phone.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        print("fake-device: bare control/status → \(status.name), home host \(status.homeHost?.rawValue ?? "-")")
        do {
            _ = try await phone.call(DaemonAPI.Method.credentialsLend)
            Issue.record("the device lent a credential")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.notPermitted)
            print("fake-device: credentials/lend refused (\(error.code))")
        }

        // 5. The wrapped wire, over one more connection: every host.
        let wrapped = ControlLink { [self] in try await dial(identity: identity, key: psk) }
        let controlClient = DaemonClient(link: wrapped.controlLink)
        try await controlClient.connect(startIfNeeded: false)
        let hosts = try await controlClient.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        print("fake-device: hosts/list → \(hosts.map { "\($0.name) (\($0.id), \($0.state))" })")
        for host in hosts where host.state == "online" {
            let there = DaemonClient(link: wrapped.link(for: host.id))
            try await there.connect(startIfNeeded: false)
            let listed = try await there.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                                              returning: [DaemonAPI.ProjectSummary].self)
            print("fake-device: \(host.name) projects → \(listed.map(\.name))")
            do {
                _ = try await there.call(DaemonAPI.Method.hostsInstall, ["destination": "x"])
                Issue.record("the device installed a host")
            } catch let error as JSONRPCError {
                print("fake-device: on \(host.id) an operator-only call was refused (\(error.code))")
            }
        }
        do {
            _ = try await controlClient.call(DaemonAPI.Method.clientsList)
            Issue.record("the device listed clients")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.notPermitted)
            print("fake-device: clients/list refused by the control plane (\(error.code))")
        }
        print("FAKE-DEVICE-ID \(id)")
    }
}
#endif
