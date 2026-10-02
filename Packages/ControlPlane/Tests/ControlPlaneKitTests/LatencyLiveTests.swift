import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// R14 and SC-004 (058, T101): what the control plane adds to a keystroke's echo and to a
/// question reaching the window, against `daemon.sock` today.
///
///   AGENTS_LATENCY=1 swift test --filter Latency
///   # and through Caddy, with Caddy proxying https://127.0.0.1:<port> to <backend>:
///   AGENTS_LATENCY_CADDY=https://127.0.0.1:18443 AGENTS_LATENCY_CADDY_PIN=<pin> \
///   AGENTS_LATENCY_CADDY_BACKEND=18444 AGENTS_LATENCY=1 swift test --filter Latency
///
/// One host daemon's server is reached every way: over its Unix socket, and over its uplink
/// through one copy, through two (client at one, host at the other) and through Caddy. The
/// window's side dials as the apps do, with `URLSession` (`WebSocketLink`); the host's as
/// `agentsd` does, with NIO.
///
/// - **Keystroke:** the client sends a key; the server says it back as a notification, as a
///   shell's echo comes back as `shell/output`. Timed from the call to the echo arriving.
/// - **Question:** the server says something nobody asked for, as a question arrives.
///   Timed from the server saying it to the client hearing it.
///
/// A shell and a runtime take the same time on every path, so neither is in it: this is
/// what the path adds. Two hundred of each, after twenty to warm up; median and 90th
/// percentile, in milliseconds.
@Suite("Latency through the control plane", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LATENCY"] != nil))
struct LatencyLiveTests {
    let base = ControlServiceTests()
    let environment = ProcessInfo.processInfo.environment
    static let samples = 200
    static let warmUp = 20

    /// The host daemon's server: a key said back, a question said on demand.
    final class Probe: @unchecked Sendable {
        let root: URL
        private(set) var server: DaemonServer!

        init() throws {
            root = URL(fileURLWithPath: "/tmp/lat-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            server = DaemonServer(url: root.appendingPathComponent("daemon.sock")) { [weak self] _, method, params in
                if method == "latency/key", let params { self?.server.broadcast("latency/echo", params) }
                return .success([:])
            }
            try server.start()
        }

        func ask(_ n: Int) {
            server.broadcast("latency/question", ["n": .int(n), "at": .int(Int(Self.now()))])
        }

        func stop() {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    }

    /// Everything a client hears, by number, as it arrives.
    actor Heard {
        private var echoes: [Int: UInt64] = [:]
        private var questions: [Int: UInt64] = [:]
        private var waiting: [String: CheckedContinuation<UInt64, Never>] = [:]

        func heard(_ method: String, _ n: Int, sentAt: UInt64?) {
            let at = Probe.now()
            let key = "\(method)#\(n)"
            let value = method == "latency/question" ? at - (sentAt ?? at) : at
            if let waiter = waiting.removeValue(forKey: key) { waiter.resume(returning: value); return }
            if method == "latency/question" { questions[n] = value } else { echoes[n] = value }
        }

        func wait(_ method: String, _ n: Int) async -> UInt64 {
            if method == "latency/question", let value = questions.removeValue(forKey: n) { return value }
            if method == "latency/echo", let value = echoes.removeValue(forKey: n) { return value }
            return await withCheckedContinuation { waiting["\(method)#\(n)"] = $0 }
        }
    }

    struct Result: CustomStringConvertible {
        let path: String
        let key: [Double]
        let question: [Double]

        static func median(_ values: [Double]) -> Double { percentile(values, 0.5) }
        static func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
        }

        var description: String {
            String(format: "LATENCY %@ | key median %.2f p90 %.2f | question median %.2f p90 %.2f",
                   path, Self.median(key), Self.percentile(key, 0.9),
                   Self.median(question), Self.percentile(question, 0.9))
        }
    }

    /// Two hundred keys and two hundred questions over `client`.
    func measure(_ path: String, probe: Probe, client: DaemonClient) async throws -> Result {
        try await client.connect(startIfNeeded: false)
        let heard = Heard()
        let listening = Task {
            for await note in client.notifications() {
                guard let n = note.params?["n"]?.intValue else { continue }
                await heard.heard(note.method, n, sentAt: note.params?["at"]?.intValue.map { UInt64($0) })
            }
        }
        defer { listening.cancel() }
        var keys: [Double] = []
        var questions: [Double] = []
        for n in 0..<(Self.warmUp + Self.samples) {
            let sent = Probe.now()
            _ = try await client.call("latency/key", ["n": JSONValue.int(n)])
            let echoed = await heard.wait("latency/echo", n)
            if n >= Self.warmUp { keys.append(Double(echoed - sent) / 1_000_000) }
        }
        for n in 0..<(Self.warmUp + Self.samples) {
            probe.ask(n)
            let took = await heard.wait("latency/question", n)
            if n >= Self.warmUp { questions.append(Double(took) / 1_000_000) }
            try await Task.sleep(for: .milliseconds(2))
        }
        let result = Result(path: path, key: keys, question: questions)
        print(result)
        return result
    }

    /// The probe as a host of the control plane at `url`: enrolled by code, dialled with NIO.
    func uplink(_ probe: Probe, service: ControlService, url: URL, pin: String?) async throws -> (HostID, ControlUplink) {
        let key = ControlAgreement.generate()
        let code = try await service.codes.issue(.host).text
        let announced = try await base.use(code, at: url, method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "probe", platform: "macOS", version: "1",
                                   machineID: "probe-\(UUID())")), pin: pin)
        let host = try #require(try announced.decode(DaemonAPI.Admitted.self).host)
        let hostKey = try ControlAuth.hostKey(privateKey: key.privateKey, peer: base.control.publicKey, host: host)
        let uplink = ControlUplink(server: probe.server, hello: DaemonAPI.HostHello(host: host, version: "1", platform: "macOS",
                                                                                  machineID: "probe")) { [base] in
            try await base.join(url, .init(identity: .host(host), key: hostKey, kind: "host",
                                           controlKey: base.control.publicKey), pin: pin)
        }
        uplink.start()
        await eventually(within: 10) { await service.router.state(of: host)?.isOnline == true }
        return (host, uplink)
    }

    /// A window paired at `url`, dialling as the apps do.
    func window(service: ControlService, url: URL, pin: String?) async throws -> ControlLink {
        let (_, _, credentials) = try await base.pairedClient(
            at: url, code: try await service.codes.issue(.client).text, pin: pin)
        return ControlLink {
            let socket = try await WebSocketLink.connect(url, pin: pin)
            return try await ControlAuth.join(socket, origin: ControlAuth.origin(url)!, as: credentials).transport
        }
    }

    @Test func throughEveryPath() async throws {
        var results: [Result] = []  // index-ok: the first two paths each add one, or throw

        // Today: the window on daemon.sock.
        do {
            let probe = try Probe()
            defer { probe.stop() }
            let client = DaemonClient(link: SocketLink(locations: StoreLocations(root: probe.root)))
            results.append(try await measure("daemon.sock", probe: probe, client: client))
            await client.disconnect()
        }

        // One copy, terminating TLS itself as Agents Host's does.
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lat-tls-\(UUID())")
            defer { try? FileManager.default.removeItem(at: dir) }
            let (context, pin) = try SelfSigned.make(in: dir, name: "127.0.0.1")
            let running = try await base.start(tls: context, pin: pin)
            defer { Task { await running.service.stop() } }
            let probe = try Probe()
            defer { probe.stop() }
            let (host, uplink) = try await uplink(probe, service: running.service, url: running.url, pin: pin)
            defer { uplink.stop() }
            let link = try await window(service: running.service, url: running.url, pin: pin)
            defer { link.disconnect() }
            results.append(try await measure("one copy (TLS)", probe: probe, client: DaemonClient(link: link.link(for: host))))
        }

        // Two copies over one store: the host at A, the window at B.
        do {
            let store = MemoryStore()
            var copies: [(ControlService, URL)] = []  // index-ok: the loop adds two, or throws
            for _ in 0..<2 {
                let port = try await freePort()
                let url = URL(string: "http://127.0.0.1:\(port)")!
                var configuration = ControlService.Configuration(store: store, privateKey: base.control.privateKey, url: url,
                                                                 bind: "127.0.0.1", port: port, name: "latency",
                                                                 machineID: "m", peerURL: url)
                configuration.copyBeat = 0.2
                let service = try ControlService(configuration)
                try await service.start()
                copies.append((service, url))
            }
            defer { for (service, _) in copies { Task { await service.stop() } } }
            for (service, _) in copies { await eventually(within: 10) { await service.mesh?.peers.count == 1 } }
            let probe = try Probe()
            defer { probe.stop() }
            let (host, uplink) = try await uplink(probe, service: copies[0].0, url: copies[0].1, pin: nil)
            defer { uplink.stop() }
            let link = try await window(service: copies[1].0, url: copies[1].1, pin: nil)
            defer { link.disconnect() }
            results.append(try await measure("two copies", probe: probe, client: DaemonClient(link: link.link(for: host))))
        }

        // One copy behind Caddy, which terminates TLS as the deploy does.
        if let caddy = environment["AGENTS_LATENCY_CADDY"].flatMap(URL.init(string:)),
           let backend = environment["AGENTS_LATENCY_CADDY_BACKEND"].flatMap(Int.init) {
            let pin = environment["AGENTS_LATENCY_CADDY_PIN"]
            let service = try ControlService(.init(store: MemoryStore(), privateKey: base.control.privateKey, url: caddy,
                                                   pin: pin, bind: "0.0.0.0", port: backend, name: "latency", machineID: "m"))
            try await service.start()
            defer { Task { await service.stop() } }
            let probe = try Probe()
            defer { probe.stop() }
            let (host, uplink) = try await uplink(probe, service: service, url: caddy, pin: pin)
            defer { uplink.stop() }
            let link = try await window(service: service, url: caddy, pin: pin)
            defer { link.disconnect() }
            results.append(try await measure("one copy behind Caddy", probe: probe, client: DaemonClient(link: link.link(for: host))))
        }

        // SC-004, on the one-copy path.
        let direct = results[0]
        let one = results[1]
        let addedKey = Result.median(one.key) - Result.median(direct.key)
        let addedQuestion = Result.median(one.question) - Result.median(direct.question)
        print(String(format: "LATENCY SC-004 one copy adds: key %.2f ms (limit 10), question %.2f ms (limit 50)",
                     addedKey, addedQuestion))
        #expect(addedKey <= 10)
        #expect(addedQuestion <= 50)
    }
}
