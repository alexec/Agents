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
               pin: String? = nil, bind: String = "127.0.0.1") async throws -> Running {
        let chosen: Int
        if let port { chosen = port } else { chosen = try await freePort() }
        let port = chosen
        let url = URL(string: "\(tls == nil ? "http" : "https")://127.0.0.1:\(port)")!
        let service = try ControlService(.init(store: store, privateKey: control.privateKey, url: url, pin: pin, tls: tls,
                                               bind: bind, port: port, name: "test", machineID: "m"))
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
    func client(at url: URL, code: String, pin: String? = nil, kind: ClientRecord.Kind = .mac) async throws -> (UUID, ControlLink) {
        let (id, link, _) = try await pairedClient(at: url, code: code, pin: pin, kind: kind)
        return (id, link)
    }

    func pairedClient(at url: URL, code: String, pin: String? = nil, kind: ClientRecord.Kind = .mac)
        async throws -> (UUID, ControlLink, ControlAuth.Credentials) {
        let key = ControlAgreement.generate()
        let id = UUID()
        _ = try await use(code, at: url, method: DaemonAPI.Method.clientsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.ClientAnnounce(id: id, publicKey: key.publicKey, name: "window", kind: kind)), pin: pin)
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: control.publicKey, client: id)
        let credentials = ControlAuth.Credentials(identity: .client(id), key: shared, kind: kind.rawValue.lowercased(),
                                                  controlKey: control.publicKey)
        let link = ControlLink { try await join(url, credentials, pin: pin) }
        return (id, link, credentials)
    }

    @Test func aHostEnrolsAClientPairsAndACallReachesTheHost() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (host, uplink) = try await host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }

        let (_, link) = try await client(at: running.url, code: try await running.service.codes.issue(.client).text)
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

    /// Fifty connections one after another, over TLS: every one finishes the key exchange.
    /// A server's first frame arriving with the upgrade's response must not be lost.
    @Test func everyConnectionFinishesTheKeyExchange() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
        let made = try SelfSigned.make(in: dir, name: "127.0.0.1")
        let running = try await start(tls: made.0, pin: made.pin)
        defer { Task { await running.service.stop() } }
        let (_, link) = try await client(at: running.url, code: try await running.service.codes.issue(.client).text,
                                         pin: made.pin)
        var slow = 0
        for _ in 0..<50 {
            let started = Date()
            let control = DaemonClient(link: link.controlLink)
            try await control.connect(startIfNeeded: false, timeout: .seconds(20))
            _ = try await control.call(DaemonAPI.Method.hostsList)
            if Date().timeIntervalSince(started) > 2 { slow += 1 }
            link.disconnect()
        }
        #expect(slow == 0)
    }

    /// A server's way in (T070, T071): the script is served, and a host code comes with the
    /// line that runs it, pinned.
    @Test func aHostCodeComesWithItsCommand() async throws {
        let running = try await start(pin: "2UzJa_LFGyMNe2ZNiDRxlVlv6-iVoUATcy_Xg7jQW4Y")
        defer { Task { await running.service.stop() } }
        let shown = try await running.service.codes.issue(.host)
        let command = try #require(shown.command)
        #expect(command.hasPrefix("curl -fsSL --insecure --pinnedpubkey sha256//2UzJa/LFGyMNe2ZNiDRxlVlv6+iVoUATcy/Xg7jQW4Y= "))
        #expect(command.hasSuffix("/v1/install.sh | sh -s -- '\(shown.text)'"))
        #expect(try await running.service.codes.issue(.client).command == nil)

        let (data, response) = try await URLSession.shared.data(from: running.url.appendingPathComponent("v1/install.sh"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == HostInstallScript.text)
        let (_, missing) = try await URLSession.shared.data(from: running.url.appendingPathComponent("v1/servers/../../etc/passwd"))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }

    /// `scripts/host-install.sh` is what every copy serves.
    @Test func theCheckedInScriptIsTheServedOne() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/host-install.sh")
        #expect(try String(contentsOf: file, encoding: .utf8) == HostInstallScript.text)
    }

    @Test func aCodeWorksOnce() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let code = try await running.service.codes.issue(.client).text
        _ = try await client(at: running.url, code: code)
        await #expect(throws: (any Error).self) { _ = try await client(at: running.url, code: code) }
    }

    /// One grant (#111): a phone asks the control plane and a host what only an operator
    /// could before, over TLS, as the window does.
    @Test func aPhoneMayDoWhatOnlyAnOperatorCouldBefore() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (host, uplink) = try await host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }
        let (phone, link) = try await client(at: running.url, code: try await running.service.codes.issue(.client).text,
                                             kind: .iPhone)
        defer { link.disconnect() }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        let clients = try await control.call(DaemonAPI.Method.clientsList, returning: [ClientRecord].self)
        #expect(clients.map(\.id) == [phone])
        let code = try await control.call(DaemonAPI.Method.clientsStartPairing, returning: DaemonAPI.ControlCodeShown.self)
        #expect(ControlCode(text: code.text)?.purpose == .client)
        let enrol = try await control.call(DaemonAPI.Method.hostsStartEnroll, returning: DaemonAPI.ControlCodeShown.self)
        #expect(ControlCode(text: enrol.text)?.purpose == .host)
        let toHost = DaemonClient(link: link.link(for: host))
        try await toHost.connect(startIfNeeded: false)
        let installed = try await toHost.call(DaemonAPI.Method.runtimesInstall)
        #expect(installed["method"]?.stringValue == DaemonAPI.Method.runtimesInstall)
        #expect(installed["role"]?.stringValue == "device")
    }

    @Test func aForgottenClientIsCutOffAndRefusedAfter() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (_, window) = try await client(at: running.url, code: try await running.service.codes.issue(.client).text)
        defer { window.disconnect() }
        let (phoneID, phone, phoneCredentials) = try await pairedClient(
            at: running.url, code: try await running.service.codes.issue(.client).text)
        let phoneControl = DaemonClient(link: phone.controlLink)
        try await phoneControl.connect(startIfNeeded: false)
        await eventually { await running.service.router.sessions(of: phoneID).count == 1 }

        let operatorControl = DaemonClient(link: window.controlLink)
        try await operatorControl.connect(startIfNeeded: false)
        _ = try await operatorControl.call(DaemonAPI.Method.clientsForget,
                                           try JSONValue.encoding(DaemonAPI.ClientRequest(client: phoneID)))
        await eventually { await running.service.router.sessions(of: phoneID).isEmpty }
        phone.disconnect()
        // `forgotten` while the tombstone is kept, rather than `unknown` (071 FR-014).
        await #expect(throws: ControlAuth.Refusal(.forgotten)) {
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
        let (_, link) = try await client(at: first.url, code: try await first.service.codes.issue(.client).text)
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

    @Test func theDefaultListenerAcceptsIPv4AndIPv6() async throws {
        let running = try await start(bind: "0.0.0.0")
        defer { Task { await running.service.stop() } }
        #expect(try await status(URL(string: "http://127.0.0.1:\(running.port)/healthz")!) == 200)
        #expect(try await status(URL(string: "http://[::1]:\(running.port)/healthz")!) == 200)
    }

    /// A self-signed copy, reached by pin; a wrong pin gets nowhere.
    @Test func aSelfSignedCopyIsReachedByItsPin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (context, pin) = try SelfSigned.make(in: dir, name: "127.0.0.1")
        let running = try await start(tls: context, pin: pin)
        defer { Task { await running.service.stop() } }
        let (_, link) = try await client(at: running.url, code: try await running.service.codes.issue(.client).text,
                                         pin: pin)
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        _ = try await control.call(DaemonAPI.Method.controlStatus)
        link.disconnect()
        let wrong = ControlCode.base64url(Data(repeating: 1, count: 32))
        await #expect(throws: (any Error).self) { _ = try await ControlDial.connect(running.url, pin: wrong) }
    }

    /// A refused connection is an error to retry, never a crash (the dialler once left a
    /// promise behind, and NIO trapped on it when agentsd redialled a restarting copy).
    @Test func dialingAPortNobodyListensOnFailsAndCanBeTriedAgain() async throws {
        let port = try await freePort()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        for _ in 0..<3 {
            await #expect(throws: (any Error).self) { _ = try await ControlDial.connect(url) }
        }
    }

    /// The apps' transport, `URLSession`, reaches the same service, by pin (T040, S2).
    @Test func anAppDialsWithURLSessionByPin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (context, pin) = try SelfSigned.make(in: dir, name: "127.0.0.1")
        let running = try await start(tls: context, pin: pin)
        defer { Task { await running.service.stop() } }
        let (id, _, credentials) = try await pairedClient(
            at: running.url, code: try await running.service.codes.issue(.client).text, pin: pin)
        let link = ControlLink { [url = running.url] in
            let socket = try await WebSocketLink.connect(url, pin: pin)
            return try await ControlAuth.join(socket, origin: ControlAuth.origin(url)!, as: credentials).transport
        }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        let status = try await control.call(DaemonAPI.Method.controlStatus)
        #expect(status["you"]?.stringValue?.lowercased() == id.uuidString.lowercased())
        link.disconnect()
        let wrong = ControlCode.base64url(Data(repeating: 1, count: 32))
        await #expect(throws: (any Error).self) { _ = try await WebSocketLink.connect(running.url, pin: wrong) }
    }

    /// A host on the control plane's own machine is its home host, `mac`; any other
    /// machine's gets an id of its own.
    @Test func theHostOnTheControlPlanesMachineIsMac() async throws {
        let port = try await freePort()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let service = try ControlService(.init(store: MemoryStore(), privateKey: control.privateKey, url: url,
                                               bind: "127.0.0.1", port: port, name: "test", machineID: "linux-1"))
        try await service.start()
        defer { Task { await service.stop() } }
        let (home, first) = try await host(at: url, code: try await service.codes.issue(.host).text)
        first.stop()
        #expect(home == .mac)
        let (other, second) = try await host(at: url, code: try await service.codes.issue(.host).text)
        second.stop()
        #expect(other != .mac)
    }

    // MARK: Helpers

    /// A control plane of servers only (the review demo, T092) has a home host: the first to
    /// join, until a host on its own machine does.
    @Test func aServerIsHomeUntilTheControlPlanesOwnMachineJoins() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (server, uplink) = try await host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.methods.controlSettings.homeHost == server }
        #expect(await running.service.methods.controlSettings.homeHost == server)

        // This machine's own host ("m", as `start` names the control plane's).
        let key = ControlAgreement.generate()
        let announced = try await use(try await running.service.codes.issue(.host).text, at: running.url,
                                      method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "this Mac", platform: "macOS arm64", version: "1", machineID: "m")))
        let mac = try #require(try announced.decode(DaemonAPI.Admitted.self).host)
        let server2 = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { _, _, _ in .success([:]) }
        let hostKey = try ControlAuth.hostKey(privateKey: key.privateKey, peer: control.publicKey, host: mac)
        let macUplink = ControlUplink(server: server2, hello: DaemonAPI.HostHello(host: mac, version: "1", platform: "macOS arm64",
                                                                                machineID: "m")) { [control] in
            try await join(running.url, .init(identity: .host(mac), key: hostKey, kind: "host", controlKey: control.publicKey))
        }
        macUplink.start()
        defer { macUplink.stop() }
        await eventually { await running.service.methods.controlSettings.homeHost == mac }
        #expect(await running.service.methods.controlSettings.homeHost == mac)
    }

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
