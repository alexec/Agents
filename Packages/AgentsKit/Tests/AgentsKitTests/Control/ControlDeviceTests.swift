import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A phone the bridge lets in, as a client of the control plane (058, US4): today's bare
/// lines still reach its Mac's host, and the wrapped wire reaches every other host, both
/// as a device.
@Suite("A device through the control plane", .serialized, .timeLimit(.minutes(1)))
struct ControlDeviceTests {
    /// Two hosts, each answering with its name and the role it was asked with.
    func plane() async throws -> (ControlPlane, URL, [ControlUplink]) {
        let root = URL(fileURLWithPath: "/tmp/cd-\(UUID().uuidString.prefix(6))")
        let plane = ControlPlane(root: root, version: "test")
        try await plane.start()
        var uplinks: [ControlUplink] = []
        for host in [HostID.mac, HostID(rawValue: "devbox")] {
            let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { context, method, _ in
                .success(["host": .string(host.rawValue), "method": .string(method), "role": .string(context.role.rawValue)])
            }
            let uplink = ControlUplink(server: server,
                                       hello: DaemonAPI.HostHello(host: host, version: "1", platform: "test",
                                                                  machineID: host == .mac ? MachineID.current : "other")) {
                let (ours, theirs) = PairedTransport.pair()
                Task { await plane.hostArrived(theirs, as: nil) }
                return ours
            }
            uplink.start()
            uplinks.append(uplink)
            await eventually { await plane.router.state(of: host)?.isOnline == true }
        }
        return (plane, root, uplinks)
    }

    /// A link that hands out one more device connection each time it is asked.
    struct DeviceLink: DaemonLink {
        let plane: ControlPlane
        let id: UUID
        func transport() async throws -> any LineTransport {
            await plane.attachDevice(id, name: "iPhone", kind: .iPhone)
        }
    }

    @Test func todaysRemoteReachesItsMacAsADeviceAndCanFindTheControlPlane() async throws {
        let (plane, root, uplinks) = try await plane()
        defer { uplinks.forEach { $0.stop() }; plane.stop(); try? FileManager.default.removeItem(at: root) }
        let phone = UUID()
        let client = DaemonClient(link: DeviceLink(plane: plane, id: phone))
        try await client.connect(startIfNeeded: false)
        let listed = try await client.call(DaemonAPI.Method.agentsList)
        #expect(listed["host"]?.stringValue == "mac")
        #expect(listed["role"]?.stringValue == "device")
        // A bare control/status is the control plane's: how the Remote finds out it is there.
        let status = try await client.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        #expect(status.homeHost == .mac)
        #expect(await plane.methods.client(phone)?.grant == .device)
    }

    @Test func overTheWrappedWireADeviceReachesEveryHostAndIsRefusedWhatItMayNotDo() async throws {
        let (plane, root, uplinks) = try await plane()
        defer { uplinks.forEach { $0.stop() }; plane.stop(); try? FileManager.default.removeItem(at: root) }
        let phone = UUID()
        let link = ControlLink { await plane.attachDevice(phone, name: "iPhone", kind: .iPhone) }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        let hosts = try await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        #expect(Set(hosts.map(\.id)) == [.mac, HostID(rawValue: "devbox")])

        let devbox = DaemonClient(link: link.link(for: HostID(rawValue: "devbox")))
        try await devbox.connect(startIfNeeded: false)
        let listed = try await devbox.call(DaemonAPI.Method.agentsList)
        #expect(listed["host"]?.stringValue == "devbox")
        #expect(listed["role"]?.stringValue == "device")
        do {
            _ = try await devbox.call(DaemonAPI.Method.credentialsLend)
            Issue.record("a device lent a credential on another host")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.notPermitted)
        }
    }

    @Test func forgettingADeviceClientTellsTheBridgeSoItsKeyStopsWorking() async throws {
        let (plane, root, uplinks) = try await plane()
        defer { uplinks.forEach { $0.stop() }; plane.stop(); try? FileManager.default.removeItem(at: root) }
        final class Forgotten: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [UUID] = []
            func add(_ id: UUID) { lock.withLock { ids.append(id) } }
            var all: [UUID] { lock.withLock { ids } }
        }
        let forgotten = Forgotten()
        plane.onClientForgotten = { forgotten.add($0) }
        let phone = UUID()
        _ = await plane.attachDevice(phone, name: "iPhone", kind: .iPhone)
        // An operator, so there is somebody left to change grants.
        try await plane.methods.admit(ClientRecord(id: UUID(), name: "Mac", kind: .mac, publicKey: Data(),
                                                   grant: .operator, paired: Date()))
        let window = ControlRouter.Caller(session: UUID(), client: UUID(), grant: .operator, kind: .mac)
        _ = try await plane.methods.handle(method: DaemonAPI.Method.clientsForget, params: ["client": .string(phone.uuidString)],
                                           from: window)
        await eventually { forgotten.all == [phone] }
    }
}
