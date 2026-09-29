import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import NIOCore
import NIOPosix
import Testing

/// Three copies of the control plane over one store (058, US3, T067): any copy serves
/// anyone, a host held by one copy is reached from the others, and changes made at one
/// reach the rest.
@Suite("Copies of the control plane", .serialized, .timeLimit(.minutes(3)))
struct CopiesTests {
    let control = ControlAgreement.generate()

    struct Copy {
        let service: ControlService
        let url: URL
    }

    func copies(_ count: Int = 3, store: any ControlStore = MemoryStore()) async throws -> [Copy] {
        var started: [Copy] = []
        for _ in 0..<count {
            let port = try await freePort()
            let url = URL(string: "http://127.0.0.1:\(port)")!
            var configuration = ControlService.Configuration(store: store, privateKey: control.privateKey, url: url,
                                                             bind: "127.0.0.1", port: port, name: "copies", machineID: "m",
                                                             peerURL: url)
            configuration.copyBeat = 0.2
            let service = try ControlService(configuration)
            try await service.start()
            started.append(Copy(service: service, url: url))
        }
        // Every pair linked.
        for copy in started {
            await eventually(within: 10) { await copy.service.mesh?.peers.count == count - 1 }
        }
        return started
    }

    func stop(_ copies: [Copy]) async {
        for copy in copies { await copy.service.stop() }
    }

    func join(_ url: URL, _ credentials: ControlAuth.Credentials) async throws -> PrefixReader {
        let socket = try await ControlDial.connect(url)
        return try await ControlAuth.join(socket, origin: ControlAuth.origin(url)!, as: credentials).transport
    }

    func use(_ code: String, at url: URL, method: String, params: JSONValue) async throws -> JSONValue {
        let parsed = try #require(ControlCode(text: code))
        let id = try #require(ControlAuth.codeID(secret: parsed.secret))
        let identity: ControlAuth.Identity = if case .host = parsed.purpose { .enrolling(id) } else { .pairing(id) }
        let reader = try await join(url, .init(identity: identity, key: ControlAuth.codeKey(secret: parsed.secret),
                                               kind: "mac", controlKey: parsed.controlKey))
        defer { reader.close() }
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(1), method: method, params: params)))
        let line = try #require(try await reader.next(within: 10))
        switch try JSONRPCCodec.decode(line: line) {
        case .success(_, let result): return result
        case .failure(_, let error): throw error
        default: throw ControlService.Failure("not a reply: \(line)")
        }
    }

    /// A host that dials the copies in turn, as it would a load balancer in front of them.
    func host(code: String, dialling urls: [URL]) async throws -> (HostID, ControlUplink) {
        let key = ControlAgreement.generate()
        let announced = try await use(code, at: urls[0], method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "devbox", platform: "Linux arm64", version: "1",
                                   machineID: "linux-1")))
        let host = try #require(try announced.decode(DaemonAPI.Admitted.self).host)
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { context, method, _ in
            .success(["host": .string(host.rawValue), "method": .string(method), "role": .string(context.role.rawValue)])
        }
        let hostKey = try ControlAuth.hostKey(privateKey: key.privateKey, peer: control.publicKey, host: host)
        let turn = Turn(count: urls.count)
        let uplink = ControlUplink(server: server, hello: DaemonAPI.HostHello(host: host, version: "1", platform: "Linux arm64",
                                                                             machineID: "linux-1")) { [control] in
            try await join(urls[turn.next()], .init(identity: .host(host), key: hostKey, kind: "host", controlKey: control.publicKey))
        }
        uplink.start()
        return (host, uplink)
    }

    final class Turn: @unchecked Sendable {
        let count: Int
        private var at = -1
        private let lock = NSLock()
        init(count: Int) { self.count = count }
        func next() -> Int { lock.withLock { at = (at + 1) % count; return at } }
    }

    func client(at url: URL, code: String, kind: ClientRecord.Kind = .mac) async throws -> (UUID, ControlLink) {
        let key = ControlAgreement.generate()
        let id = UUID()
        _ = try await use(code, at: url, method: DaemonAPI.Method.clientsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.ClientAnnounce(id: id, publicKey: key.publicKey, name: "window", kind: kind)))
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: control.publicKey, client: id)
        let credentials = ControlAuth.Credentials(identity: .client(id), key: shared, kind: "mac", controlKey: control.publicKey)
        return (id, ControlLink { try await join(url, credentials) })
    }

    func leaseHolder(_ host: HostID, in store: any ControlStore) async throws -> HostLease? {
        guard let object = try await store.get(Leases.key(host)) else { return nil }
        return try ControlRecords.decoder.decode(HostLease.self, from: object.data)
    }

    // MARK: The tests

    @Test func aClientOnEachCopySeesEveryHost() async throws {
        let store = MemoryStore()
        let all = try await copies(store: store)
        defer { Task { await stop(all) } }
        let (host, uplink) = try await host(code: try await all[0].service.codes.issue(.host).text, dialling: [all[0].url])
        defer { uplink.stop() }
        for copy in all { await eventually(within: 10) { await copy.service.router.state(of: host)?.isOnline == true } }
        #expect(try await leaseHolder(host, in: store)?.copy == all[0].service.copyID)

        for copy in all {
            let (_, link) = try await client(at: copy.url, code: try await copy.service.codes.issue(.client(.operator)).text)
            defer { link.disconnect() }
            let toHost = DaemonClient(link: link.link(for: host))
            try await toHost.connect(startIfNeeded: false)
            let answer = try await toHost.call(DaemonAPI.Method.agentsList)
            #expect(answer["host"]?.stringValue == host.rawValue)
            #expect(answer["role"]?.stringValue == "control")
        }
    }

    /// The grant is checked where the client is: a device on another copy is refused before
    /// anything reaches the holder.
    @Test func aDeviceIsRefusedAtItsOwnCopy() async throws {
        let all = try await copies(2)
        defer { Task { await stop(all) } }
        let (host, uplink) = try await host(code: try await all[0].service.codes.issue(.host).text, dialling: [all[0].url])
        defer { uplink.stop() }
        await eventually(within: 10) { await all[1].service.router.state(of: host)?.isOnline == true }
        let (_, link) = try await client(at: all[1].url, code: try await all[1].service.codes.issue(.client(.device)).text,
                                         kind: .iPhone)
        defer { link.disconnect() }
        let toHost = DaemonClient(link: link.link(for: host))
        try await toHost.connect(startIfNeeded: false)
        #expect(try await toHost.call(DaemonAPI.Method.agentsList)["role"]?.stringValue == "device")
        await #expect(throws: JSONRPCError.self) { _ = try await toHost.call(DaemonAPI.Method.runtimesInstall) }
    }

    @Test func killingTheHolderMovesTheLeaseAndTheHostRedials() async throws {
        let store = MemoryStore()
        let all = try await copies(store: store)
        defer { Task { await stop(all) } }
        let (host, uplink) = try await host(code: try await all[0].service.codes.issue(.host).text,
                                            dialling: all.map(\.url))
        defer { uplink.stop() }
        await eventually(within: 10) { await all[2].service.router.state(of: host)?.isOnline == true }
        let first = try #require(try await leaseHolder(host, in: store))
        #expect(first.copy == all[0].service.copyID)

        await all[0].service.stop()
        // The host dials the next copy, which takes the lease over.
        await eventually(within: 15) { (try? await leaseHolder(host, in: store))?.copy == all[1].service.copyID }
        let moved = try #require(try await leaseHolder(host, in: store))
        #expect(moved.epoch > first.epoch)
        await eventually(within: 10) { await all[2].service.router.state(of: host)?.isOnline == true }

        let (_, link) = try await client(at: all[2].url, code: try await all[2].service.codes.issue(.client(.operator)).text)
        defer { link.disconnect() }
        let toHost = DaemonClient(link: link.link(for: host))
        try await toHost.connect(startIfNeeded: false)
        #expect(try await toHost.call(DaemonAPI.Method.agentsList)["host"]?.stringValue == host.rawValue)
    }

    @Test func aCodeShownAtOneCopyWorksOnceAtAnother() async throws {
        let all = try await copies(2)
        defer { Task { await stop(all) } }
        let code = try await all[0].service.codes.issue(.client(.device)).text
        _ = try await client(at: all[1].url, code: code, kind: .iPhone)
        await #expect(throws: (any Error).self) { _ = try await client(at: all[0].url, code: code, kind: .iPhone) }
    }

    @Test func aForgetReachesEveryCopyWithinTwoSeconds() async throws {
        let all = try await copies()
        defer { Task { await stop(all) } }
        let (phone, phoneLink) = try await client(at: all[2].url,
                                                  code: try await all[2].service.codes.issue(.client(.device)).text, kind: .iPhone)
        defer { phoneLink.disconnect() }
        let control = DaemonClient(link: phoneLink.controlLink)
        try await control.connect(startIfNeeded: false)
        await eventually { await !all[2].service.router.sessions(of: phone).isEmpty }

        let (_, operatorLink) = try await client(at: all[0].url,
                                                 code: try await all[0].service.codes.issue(.client(.operator)).text)
        defer { operatorLink.disconnect() }
        let mine = DaemonClient(link: operatorLink.controlLink)
        try await mine.connect(startIfNeeded: false)
        let asked = Date()
        _ = try await mine.call(DaemonAPI.Method.clientsForget, JSONValue.object(["client": .string(phone.uuidString)]))
        await eventually(within: 2) { await all[2].service.router.sessions(of: phone).isEmpty }
        #expect(Date().timeIntervalSince(asked) < 2)
    }

    @Test func twoGrantChangesRaceAndOneIsToldChangedElsewhere() async throws {
        let all = try await copies(2)
        defer { Task { await stop(all) } }
        let (phone, link) = try await client(at: all[0].url, code: try await all[0].service.codes.issue(.client(.device)).text,
                                             kind: .iPhone)
        link.disconnect()
        let (admin, adminLink) = try await client(at: all[0].url, code: try await all[0].service.codes.issue(.client(.operator)).text)
        adminLink.disconnect()
        // Both copies have read the phone's record as it is now.
        for copy in all { try await copy.service.methods.refresh() }
        let caller = ControlRouter.Caller(session: UUID(), client: admin, grant: .operator, kind: .mac)
        let params: JSONValue = ["client": .string(phone.uuidString), "grant": "operator"]
        _ = try await all[0].service.methods.handle(method: DaemonAPI.Method.clientsSetGrant, params: params, from: caller)
        do {
            _ = try await all[1].service.methods.handle(method: DaemonAPI.Method.clientsSetGrant,
                                                        params: ["client": .string(phone.uuidString), "grant": "device"],
                                                        from: caller)
            // The event may have reached the second copy first, in which case its change
            // came second rather than at once: then it is simply the last word.
            #expect(await all[1].service.methods.client(phone)?.grant == .device)
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.changedElsewhere)
        }
    }

    @Test func withTheStoreDownLiveCallsCarryOnAndPairingIsRefused() async throws {
        let store = MemoryStore()
        let all = try await copies(2, store: store)
        defer { Task { await stop(all) } }
        let (host, uplink) = try await host(code: try await all[0].service.codes.issue(.host).text, dialling: [all[0].url])
        defer { uplink.stop() }
        await eventually(within: 10) { await all[1].service.router.state(of: host)?.isOnline == true }
        let (_, link) = try await client(at: all[1].url, code: try await all[1].service.codes.issue(.client(.operator)).text)
        defer { link.disconnect() }
        let toHost = DaemonClient(link: link.link(for: host))
        try await toHost.connect(startIfNeeded: false)
        let mine = DaemonClient(link: link.controlLink)
        try await mine.connect(startIfNeeded: false)

        await store.setDown(true)
        #expect(try await toHost.call(DaemonAPI.Method.agentsList)["host"]?.stringValue == host.rawValue)
        do {
            _ = try await mine.call(DaemonAPI.Method.clientsStartPairing, JSONValue.object(["grant": "device"]))
            Issue.record("pairing worked with the store down")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.storeUnavailable)
        }
        await store.setDown(false)
    }
}
