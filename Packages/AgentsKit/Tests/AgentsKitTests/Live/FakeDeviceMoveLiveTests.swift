#if canImport(Network) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Network
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A fake iPhone for the 058 US6 walk: paired the old way, to a root's own daemon and
/// bridge, then connecting again after the move with the key it already had.
///
///     AGENTS_FAKE_DEVICE_MOVE=pair|again AGENTS_FAKE_DEVICE_ROOT=<root> \
///     AGENTS_FAKE_DEVICE_PORT=<bridge port> swift test --filter FakeDeviceMoveLiveTests
///
/// Its key and what pairing gave it are kept in `<root>-fake/`, as a phone keeps them.
@Suite("A fake iPhone across the move",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_MOVE"] != nil),
       .serialized, .timeLimit(.minutes(2)))
struct FakeDeviceMoveLiveTests {
    let environment = ProcessInfo.processInfo.environment
    var root: URL { URL(fileURLWithPath: environment["AGENTS_FAKE_DEVICE_ROOT"] ?? "/nowhere") }
    var kept: URL { URL(fileURLWithPath: root.path + "-fake") }
    var port: NWEndpoint.Port { NWEndpoint.Port(environment["AGENTS_FAKE_DEVICE_PORT"] ?? "8799")! }

    struct Paired: Codable { var id: UUID; var macKey: Data }

    func dial(identity: String, key: SymmetricKey) async throws -> NWTransport {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: LinkTLS.client(identity: identity, key: key))
        let transport = NWTransport(connection: connection)
        try await transport.waitUntilReady()
        return transport
    }

    func connected(identity: String, key: SymmetricKey) async throws -> DaemonClient {
        for _ in 0..<30 {
            if let transport = try? await dial(identity: identity, key: key) {
                let client = DaemonClient(link: FakeDeviceLiveTests.Fixed { transport })
                if (try? await client.connect(startIfNeeded: false)) != nil { return client }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CocoaError(.featureUnsupported)
    }

    func projects(_ client: DaemonClient) async throws -> [String] {
        try await client.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                              returning: [DaemonAPI.ProjectSummary].self).map(\.name)
    }

    @Test func acrossTheMove() async throws {
        let key = try DeviceKey.load(file: kept.appendingPathComponent("device-key"))
        let record = kept.appendingPathComponent("paired.json")
        if environment["AGENTS_FAKE_DEVICE_MOVE"] == "pair" {
            // The old way: a pairing code from the root's own daemon, as Settings ▸ Devices asks.
            let socket = StoreLocations(root: root).socket.path
            let window = DaemonClient(link: FakeDeviceLiveTests.Fixed { FDTransport(socket: try connectUnixSocket(path: socket)) })
            try await window.connect(startIfNeeded: false)
            let code = try await window.call(DaemonAPI.Method.devicesStartPairing, returning: DaemonAPI.PairingCode.self)
            let id = UUID()
            var opened: NWTransport?
            for _ in 0..<20 where opened == nil {
                opened = try? await dial(identity: LinkKey.pairingIdentity(code.secret), key: LinkKey.pairing(code.secret))
                if opened == nil { try await Task.sleep(for: .milliseconds(300)) }
            }
            let pairing = try #require(opened, "the bridge never took the pairing code's key")
            let announcing = DaemonClient(link: FakeDeviceLiveTests.Fixed { pairing })
            try await announcing.connect(startIfNeeded: false)
            _ = try await announcing.call(DaemonAPI.Method.devicesAnnounce,
                                          DaemonAPI.DeviceAnnouncement(id: id, publicKey: key.publicKey,
                                                                       name: "Fake iPhone", kind: .iPhone))
            await announcing.disconnect()
            try JSONEncoder().encode(Paired(id: id, macKey: code.macKey)).write(to: record)
            print("fake-device: paired the old way as \(id)")
        }

        let paired = try JSONDecoder().decode(Paired.self, from: Data(contentsOf: record))
        let psk = try key.linkKey(with: paired.macKey, device: paired.id)
        let identity = LinkKey.deviceIdentity(paired.id)
        let phone = try await connected(identity: identity, key: psk)
        print("fake-device: connected with its own key; projects → \(try await projects(phone))")
        let agents = try await phone.call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest(),
                                          returning: [Agent].self)
        print("fake-device: agents → \(agents.map(\.id))")

        guard environment["AGENTS_FAKE_DEVICE_MOVE"] == "again" else { return }
        let status = try await phone.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        print("fake-device: control/status → \(status.name), home host \(status.homeHost?.rawValue ?? "-")")
        let wrapped = ControlLink { [self] in try await dial(identity: identity, key: psk) }
        let control = DaemonClient(link: wrapped.controlLink)
        try await control.connect(startIfNeeded: false)
        let hosts = try await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        print("fake-device: hosts/list → \(hosts.map { "\($0.name) (\($0.id), \($0.state))" })")
        for host in hosts where host.state == "online" {
            let there = DaemonClient(link: wrapped.link(for: host.id))
            try await there.connect(startIfNeeded: false)
            print("fake-device: \(host.name) projects → \(try await projects(there))")
        }
    }
}
#endif
