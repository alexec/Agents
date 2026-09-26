import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The whole path in memory: a `DaemonClient` per host over one `ControlLink`, the
/// router, each host's uplink, and each host's `DaemonServer`.
@Suite("Client to host through the control plane", .timeLimit(.minutes(1)))
struct ControlEndToEndTests {
    struct Rig {
        let router: ControlRouter
        let link: ControlLink
        let servers: [HostID: DaemonServer]
        let uplinks: [ControlUplink]
    }

    /// Each host answers any call with its own name and the role it was asked with.
    func rig(hosts: [HostID], grant: Grant = .operator) async -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-e2e-\(UUID())")
        let methods = ControlMethods(store: GrantStore(root: root),
                                     settings: ControlSettings(name: "test", machineID: "m"), version: "1")
        let router = ControlRouter(handler: methods, homeHost: hosts.first)
        await methods.attach(router)
        var servers: [HostID: DaemonServer] = [:]
        var uplinks: [ControlUplink] = []
        for host in hosts {
            let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { context, method, _ in
                .success(["host": .string(host.rawValue), "method": .string(method), "role": .string(context.role.rawValue)])
            }
            servers[host] = server
            let uplink = ControlUplink(server: server,
                                       hello: DaemonAPI.HostHello(host: host, version: "1", platform: "test", machineID: "m")) {
                let (ours, theirs) = PairedTransport.pair()
                await router.attachHost(host, transport: theirs)
                return ours
            }
            uplink.start()
            uplinks.append(uplink)
        }
        let record = ClientRecord(id: UUID(), name: "window", kind: .mac, publicKey: Data(), grant: grant, paired: Date())
        let link = ControlLink {
            let (ours, theirs) = PairedTransport.pair()
            await router.attachClient(record, transport: theirs)
            return ours
        }
        for host in hosts {
            await eventually { await router.state(of: host)?.isOnline == true }
        }
        return Rig(router: router, link: link, servers: servers, uplinks: uplinks)
    }

    @Test func aClientPerHostReachesItsOwnHostOverOneConnection() async throws {
        let mac = HostID.mac
        let devbox = HostID(rawValue: "k3v9x0qa")
        let rig = await rig(hosts: [mac, devbox])
        defer { rig.uplinks.forEach { $0.stop() } }

        let toMac = DaemonClient(link: rig.link.link(for: mac))
        let toDevbox = DaemonClient(link: rig.link.link(for: devbox))
        try await toMac.connect(startIfNeeded: false)
        try await toDevbox.connect(startIfNeeded: false)
        let a = try await toMac.call(DaemonAPI.Method.agentsList)
        let b = try await toDevbox.call(DaemonAPI.Method.agentsList)
        #expect(a["host"]?.stringValue == "mac")
        #expect(b["host"]?.stringValue == "k3v9x0qa")
        #expect(a["role"]?.stringValue == "control")

        let control = DaemonClient(link: rig.link.controlLink)
        try await control.connect(startIfNeeded: false)
        let hosts = try await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        #expect(Set(hosts.map(\.id)) == [mac, devbox])
        #expect(hosts.allSatisfy { $0.state == "online" })
    }

    @Test func aHostsBroadcastReachesOnlyItsOwnClient() async throws {
        let mac = HostID.mac
        let devbox = HostID(rawValue: "k3v9x0qa")
        let rig = await rig(hosts: [mac, devbox])
        defer { rig.uplinks.forEach { $0.stop() } }
        let toMac = DaemonClient(link: rig.link.link(for: mac))
        let toDevbox = DaemonClient(link: rig.link.link(for: devbox))
        try await toMac.connect(startIfNeeded: false)
        try await toDevbox.connect(startIfNeeded: false)

        let macHeard = Box()
        let devboxHeard = Box()
        let listening = [
            Task { for await note in toMac.notifications() { macHeard.add(note.method) } },
            Task { for await note in toDevbox.notifications() { devboxHeard.add(note.method) } },
        ]
        defer { listening.forEach { $0.cancel() } }
        rig.servers[devbox]?.broadcast(DaemonAPI.Notification.agentChanged, ["x": 1])
        await eventually { devboxHeard.all == [DaemonAPI.Notification.agentChanged] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(macHeard.all.isEmpty)
    }

    @Test func aHostThatGoesEndsItsClientsConnectionAndOnlyThatOne() async throws {
        let mac = HostID.mac
        let devbox = HostID(rawValue: "k3v9x0qa")
        let rig = await rig(hosts: [mac, devbox])
        defer { rig.uplinks.forEach { $0.stop() } }
        let toMac = DaemonClient(link: rig.link.link(for: mac))
        let toDevbox = DaemonClient(link: rig.link.link(for: devbox))
        try await toMac.connect(startIfNeeded: false)
        try await toDevbox.connect(startIfNeeded: false)
        // The control plane's own client hears the host go, which ends the host's route.
        let control = DaemonClient(link: rig.link.controlLink)
        try await control.connect(startIfNeeded: false)

        rig.uplinks[1].stop()
        await eventually { await rig.router.state(of: devbox)?.isOnline == false }
        await #expect(throws: (any Error).self) { _ = try await toDevbox.call(DaemonAPI.Method.agentsList) }
        _ = try await toMac.call(DaemonAPI.Method.agentsList)
    }

    @Test func aDeviceIsRefusedAtTheControlPlaneForWhatOnlyAnOperatorMayAsk() async throws {
        let rig = await rig(hosts: [.mac], grant: .device)
        defer { rig.uplinks.forEach { $0.stop() } }
        let client = DaemonClient(link: rig.link.link(for: .mac))
        try await client.connect(startIfNeeded: false)
        let list = try await client.call(DaemonAPI.Method.agentsList)
        #expect(list["role"]?.stringValue == "device")
        do {
            _ = try await client.call(DaemonAPI.Method.credentialsLend)
            Issue.record("a device lent a credential")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.notPermitted)
        }
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }
}
