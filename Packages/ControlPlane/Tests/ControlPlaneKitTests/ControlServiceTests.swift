import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing

/// One copy of the service on loopback, a real host behind a real uplink, and clients
/// paired by codes, all over WebSockets (058, T043).
@Suite("The control plane as a service", .timeLimit(.minutes(2)))
struct ControlServiceTests {
    let control = ControlAgreement.generate()

    struct Running {
        let service: ControlService
        let url: URL
        let port: Int
    }

    func start(store: any ControlStore = MemoryStore(), port: Int? = nil, tls: NIOSSLContext? = nil,
               pin: String? = nil) async throws -> Running {
        let chosen: Int
        if let port { chosen = port } else { chosen = try await freePort() }
        let port = chosen
        let url = URL(string: "\(tls == nil ? "http" : "https")://127.0.0.1:\(port)")!
        let service = try ControlService(.init(store: store, privateKey: control.privateKey, url: url, pin: pin, tls: tls,
                                               bind: "127.0.0.1", port: port, name: "test", machineID: "m"))
        try await service.start()
        return Running(service: service, url: url, port: port)
    }

    /// Dials and proves `credentials`; the socket after the exchange.
    func join(_ url: URL, _ credentials: ControlAuth.Credentials, pin: String? = nil) async throws -> PrefixReader {
        let socket = try await ControlDial.connect(url, pin: pin)
        return try await ControlAuth.join(socket, origin: ControlAuth.origin(url)!, as: credentials).transport
    }

    /// Uses a code: joins as its holder, announces, and returns the reply's result.
    func use(_ code: String, at url: URL, method: String, params: JSONValue, pin: String? = nil) async throws -> JSONValue {
        let parsed = try #require(ControlCode(text: code))
        let id = try #require(ControlAuth.codeID(secret: parsed.secret))
        let identity: ControlAuth.Identity = if case .host = parsed.purpose { .enrolling(id) } else { .pairing(id) }
        let reader = try await join(url, .init(identity: identity, key: ControlAuth.codeKey(secret: parsed.secret),
                                               kind: "mac", controlKey: parsed.controlKey), pin: pin)
        defer { reader.close() }
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(1), method: method, params: params)))
        let line = try #require(try await reader.next(within: 10))
        switch try JSONRPCCodec.decode(line: line) {
        case .success(_, let result): return result
        case .failure(_, let error): throw error
        default: throw ControlService.Failure("not a reply: \(line)")
        }
    }

    /// A host enrolled by code, answering every call with its name and the role asked with.
    func host(at url: URL, code: String, pin: String? = nil) async throws -> (HostID, ControlUplink) {
        let key = ControlAgreement.generate()
        let announced = try await use(code, at: url, method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "devbox", platform: "Linux arm64", version: "1",
                                   machineID: "linux-1")), pin: pin)
        let host = try #require(try announced.decode(DaemonAPI.Admitted.self).host)
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { context, method, _ in
            .success(["host": .string(host.rawValue), "method": .string(method), "role": .string(context.role.rawValue)])
        }
        let hostKey = try ControlAuth.hostKey(privateKey: key.privateKey, peer: control.publicKey, host: host)
        let uplink = ControlUplink(server: server, hello: DaemonAPI.HostHello(host: host, version: "1", platform: "Linux arm64",
                                                                             machineID: "linux-1")) { [control] in
            try await join(url, .init(identity: .host(host), key: hostKey, kind: "host", controlKey: control.publicKey), pin: pin)
        }
        uplink.start()
        return (host, uplink)
    }

    /// A client paired by code, and a link that dials as it.
    func client(at url: URL, code: String, pin: String? = nil) async throws -> (UUID, ControlLink) {
        let (id, link, _) = try await pairedClient(at: url, code: code, pin: pin)
        return (id, link)
    }

    func pairedClient(at url: URL, code: String, pin: String? = nil)
        async throws -> (UUID, ControlLink, ControlAuth.Credentials) {
        let key = ControlAgreement.generate()
        let id = UUID()
        _ = try await use(code, at: url, method: DaemonAPI.Method.clientsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.ClientAnnounce(id: id, publicKey: key.publicKey, name: "window", kind: .mac)), pin: pin)
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: control.publicKey, client: id)
        let credentials = ControlAuth.Credentials(identity: .client(id), key: shared, kind: "mac", controlKey: control.publicKey)
        let link = ControlLink { try await join(url, credentials, pin: pin) }
        return (id, link, credentials)
    }

    @Test func aHostEnrolsAClientPairsAndACallReachesTheHost() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (host, uplink) = try await host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }

        let (_, link) = try await client(at: running.url, code: try await running.service.codes.issue(.client(.operator)).text)
        let toHost = DaemonClient(link: link.link(for: host))
        try await toHost.connect(startIfNeeded: false)
        let answer = try await toHost.call(DaemonAPI.Method.agentsList)
        #expect(answer["host"]?.stringValue == host.rawValue)
        #expect(answer["role"]?.stringValue == "control")

        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        let hosts = try await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        #expect(hosts.map(\.id) == [host])
        link.disconnect()
    }

    @Test func aCodeWorksOnce() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let code = try await running.service.codes.issue(.client(.device)).text
        _ = try await client(at: running.url, code: code)
        await #expect(throws: (any Error).self) { _ = try await client(at: running.url, code: code) }
    }

    @Test func aDeviceIsRefusedWhatOnlyAnOperatorMayDo() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (host, uplink) = try await host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }
        let (_, link) = try await client(at: running.url, code: try await running.service.codes.issue(.client(.device)).text)
        defer { link.disconnect() }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        await #expect(throws: JSONRPCError.self) { _ = try await control.call(DaemonAPI.Method.clientsList) }
        let toHost = DaemonClient(link: link.link(for: host))
        try await toHost.connect(startIfNeeded: false)
        await #expect(throws: JSONRPCError.self) { _ = try await toHost.call(DaemonAPI.Method.runtimesInstall) }
    }

    @Test func aForgottenClientIsCutOffAndRefusedAfter() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (_, window) = try await client(at: running.url, code: try await running.service.codes.issue(.client(.operator)).text)
        defer { window.disconnect() }
        let (phoneID, phone, phoneCredentials) = try await pairedClient(
            at: running.url, code: try await running.service.codes.issue(.client(.device)).text)
        let phoneControl = DaemonClient(link: phone.controlLink)
        try await phoneControl.connect(startIfNeeded: false)
        await eventually { await running.service.router.sessions(of: phoneID).count == 1 }

        let operatorControl = DaemonClient(link: window.controlLink)
        try await operatorControl.connect(startIfNeeded: false)
        _ = try await operatorControl.call(DaemonAPI.Method.clientsForget,
                                           try JSONValue.encoding(DaemonAPI.ClientRequest(client: phoneID)))
        await eventually { await running.service.router.sessions(of: phoneID).isEmpty }
        phone.disconnect()
        await #expect(throws: ControlAuth.Refusal(.unknown)) {
            _ = try await join(running.url, phoneCredentials)
        }
    }

    @Test func aStoreBelongingToAnotherKeyIsRefused() async throws {
        let store = MemoryStore()
        let running = try await start(store: store)
        await running.service.stop()
        let other = try ControlService(.init(store: store, privateKey: ControlAgreement.generate().privateKey,
                                             url: running.url, bind: "127.0.0.1", port: try await freePort(), name: "x"))
        await #expect(throws: ControlService.Failure.self) { try await other.start() }
    }

    /// After a restart on the same store and port, the host redials and a client comes back.
    @Test func bothEndsComeBackAfterARestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await start(store: FolderStore(root: root))
        let (host, uplink) = try await host(at: first.url, code: try await first.service.codes.issue(.host).text)
        defer { uplink.stop() }
        let (_, link) = try await client(at: first.url, code: try await first.service.codes.issue(.client(.operator)).text)
        await eventually { await first.service.router.state(of: host)?.isOnline == true }
        await first.service.stop()

        let second = try await start(store: FolderStore(root: root), port: first.port)
        defer { Task { await second.service.stop() } }
        await eventually(within: 30) { await second.service.router.state(of: host)?.isOnline == true }
        let toHost = DaemonClient(link: link.link(for: host))
        try await toHost.connect(startIfNeeded: false)
        #expect(try await toHost.call(DaemonAPI.Method.agentsList)["host"]?.stringValue == host.rawValue)
        link.disconnect()
    }

    @Test func healthAndReadinessAnswerPlainHTTP() async throws {
        let store = MemoryStore()
        let running = try await start(store: store)
        defer { Task { await running.service.stop() } }
        #expect(try await status(running.url.appendingPathComponent("healthz")) == 200)
        #expect(try await status(running.url.appendingPathComponent("readyz")) == 200)
        await store.setDown(true)
        await running.service.refresh()
        #expect(try await status(running.url.appendingPathComponent("readyz")) == 503)
    }

    /// A self-signed copy, reached by pin; a wrong pin gets nowhere.
    @Test func aSelfSignedCopyIsReachedByItsPin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (context, pin) = try SelfSigned.make(in: dir, name: "127.0.0.1")
        let running = try await start(tls: context, pin: pin)
        defer { Task { await running.service.stop() } }
        let (_, link) = try await client(at: running.url, code: try await running.service.codes.issue(.client(.operator)).text,
                                         pin: pin)
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        _ = try await control.call(DaemonAPI.Method.controlStatus)
        link.disconnect()
        let wrong = ControlCode.base64url(Data(repeating: 1, count: 32))
        await #expect(throws: (any Error).self) { _ = try await ControlDial.connect(running.url, pin: wrong) }
    }

    // MARK: Helpers

    func status(_ url: URL) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

func freePort() async throws -> Int {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .bind(host: "127.0.0.1", port: 0).get()
    let port = channel.localAddress?.port ?? 0
    try await channel.close()
    return port
}

func eventually(within seconds: Double = 5, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("the condition never held")
}
