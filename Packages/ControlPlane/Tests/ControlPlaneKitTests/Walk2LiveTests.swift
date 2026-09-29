import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// Quickstart Walk 2 against `deploy/compose.yaml` (058, T069): three copies over MinIO
/// behind Caddy. Only when `AGENTS_WALK_COMPOSE` names the compose file; it stops and starts
/// the containers, so it is never part of an ordinary run.
///
///   AGENTS_WALK_COMPOSE=$PWD/deploy/compose.yaml swift test --filter Walk2
@Suite("Walk 2: copies behind a load balancer", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WALK_COMPOSE"] != nil))
struct Walk2LiveTests {
    let compose = ProcessInfo.processInfo.environment["AGENTS_WALK_COMPOSE"] ?? ""
    let url = URL(string: "https://127.0.0.1:8443")!
    var pin: String {
        (try? String(contentsOfFile: URL(fileURLWithPath: compose).deletingLastPathComponent()
            .appendingPathComponent("secrets/pin").path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    let bucket = S3Store(.init(endpoint: URL(string: "http://127.0.0.1:19100")!, bucket: "agents-walk", prefix: "w1",
                               pathStyle: true), credentials: .init(accessKey: "walkuser", secretKey: "walkwalkwalk"))

    // MARK: Docker

    @discardableResult
    func docker(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "compose", "-f", compose] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func code(_ purpose: [String]) throws -> String {
        let out = try docker(["exec", "-T", "cp1", "/agents-control", "code"] + purpose)
        return try #require(out.split(separator: "\n").last { $0.hasPrefix("agents-control:2:") }).description
    }

    /// Which container a copy id is, from each copy's first log line.
    func container(of copy: String) throws -> String? {
        for name in ["cp1", "cp2", "cp3"] where try docker(["logs", name]).contains("agents-control[\(copy)]") { return name }
        return nil
    }

    func note(_ line: String) { print("WALK2 \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)") }

    // MARK: Joining through Caddy

    func join(_ credentials: ControlAuth.Credentials) async throws -> PrefixReader {
        try await ControlJoin.dial(url, pin: pin, as: credentials)
    }

    func use(_ code: String, method: String, params: JSONValue) async throws -> JSONValue {
        let parsed = try #require(ControlCode(text: code))
        let id = try #require(ControlAuth.codeID(secret: parsed.secret))
        let identity: ControlAuth.Identity = if case .host = parsed.purpose { .enrolling(id) } else { .pairing(id) }
        let reader = try await join(.init(identity: identity, key: ControlAuth.codeKey(secret: parsed.secret), kind: "mac",
                                          controlKey: parsed.controlKey))
        defer { reader.close() }
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(1), method: method, params: params)))
        let line = try #require(try await reader.next(within: 10))
        switch try JSONRPCCodec.decode(line: line) {
        case .success(_, let result): return result
        case .failure(_, let error): throw error
        default: throw ControlService.Failure("not a reply: \(line)")
        }
    }

    func client(_ code: String, kind: ClientRecord.Kind) async throws -> (UUID, ControlLink) {
        let parsed = try #require(ControlCode(text: code))
        let key = ControlAgreement.generate()
        let id = UUID()
        _ = try await use(code, method: DaemonAPI.Method.clientsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.ClientAnnounce(id: id, publicKey: key.publicKey, name: "walk \(kind.rawValue)", kind: kind)))
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: parsed.controlKey, client: id)
        let credentials = ControlAuth.Credentials(identity: .client(id), key: shared, kind: "mac", controlKey: parsed.controlKey)
        return (id, ControlLink { try await join(credentials) })
    }

    func host(_ code: String) async throws -> (HostID, ControlUplink) {
        let parsed = try #require(ControlCode(text: code))
        let key = ControlAgreement.generate()
        let announced = try await use(code, method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "walk host", platform: "Linux arm64", version: "1",
                                   machineID: "walk-host")))
        let host = try #require(try announced.decode(DaemonAPI.Admitted.self).host)
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { context, method, _ in
            .success(["host": .string(host.rawValue), "method": .string(method), "role": .string(context.role.rawValue)])
        }
        let hostKey = try ControlAuth.hostKey(privateKey: key.privateKey, peer: parsed.controlKey, host: host)
        let controlKey = parsed.controlKey
        let uplink = ControlUplink(server: server, hello: DaemonAPI.HostHello(host: host, version: "1", platform: "Linux arm64",
                                                                             machineID: "walk-host")) {
            try await join(.init(identity: .host(host), key: hostKey, kind: "host", controlKey: controlKey))
        }
        uplink.start()
        return (host, uplink)
    }

    func lease(_ host: HostID) async -> HostLease? {
        guard let object = try? await bucket.get(Leases.key(host)) else { return nil }
        return try? ControlRecords.decoder.decode(HostLease.self, from: object.data)
    }

    /// Polls until `condition`, and says how long it took.
    func within(_ seconds: Double, _ what: String, _ condition: () async -> Bool) async -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if await condition() {
                let took = Date().timeIntervalSince(start)
                note("\(what): \(String(format: "%.1f", took)) s")
                return took
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("\(what): not within \(seconds) s")
        return nil
    }

    /// A call as the window makes it: a connection that ended is dialled again first, as
    /// the app's own reconnect loop does (the link redials on the next connect).
    func call(_ client: DaemonClient, _ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        do {
            return try await client.call(method, params)
        } catch let error as JSONRPCError {
            throw error
        } catch {
            try await client.connect(startIfNeeded: false, timeout: .seconds(3))
            return try await client.call(method, params)
        }
    }

    func reaches(_ client: DaemonClient, _ host: HostID) async -> Bool {
        (try? await call(client, DaemonAPI.Method.agentsList))?["host"]?.stringValue == host.rawValue
    }

    /// Many connections through Caddy, one after another: each must finish the key exchange.
    @Test func connectionsThroughTheBalancer() async throws {
        let (_, link) = try await client(try code(["--client", "operator"]), kind: .mac)
        var failures = 0
        for n in 0..<20 {
            let started = Date()
            let control = DaemonClient(link: link.controlLink)
            do {
                try await control.connect(startIfNeeded: false, timeout: .seconds(20))
                _ = try await control.call(DaemonAPI.Method.hostsList)
                note("connection \(n): \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            } catch {
                failures += 1
                note("connection \(n) failed after \(String(format: "%.2f", Date().timeIntervalSince(started))) s: \(error)")
            }
            link.disconnect()
        }
        #expect(failures == 0)
    }

    // MARK: The walk

    @Test func walk2() async throws {
        #expect(!pin.isEmpty)
        // 1–3: a host, an operator window and a device, all through Caddy.
        let (host, uplink) = try await host(try code(["--host"]))
        defer { uplink.stop() }
        let (_, window) = try await client(try code(["--client", "operator"]), kind: .mac)
        defer { window.disconnect() }
        let (phone, device) = try await client(try code(["--client", "device"]), kind: .iPhone)
        defer { device.disconnect() }
        let toHost = DaemonClient(link: window.link(for: host))
        try await toHost.connect(startIfNeeded: false)
        _ = await within(15, "the window reaches the host") { await reaches(toHost, host) }
        let control = DaemonClient(link: window.controlLink)
        try await control.connect(startIfNeeded: false)
        let phoneControl = DaemonClient(link: device.controlLink)
        try await phoneControl.connect(startIfNeeded: false)

        // 4: who holds the host, and which copy the window is on.
        let held = try #require(await lease(host))
        let holder = try #require(try container(of: held.copy))
        let windowOn = try ["cp1", "cp2", "cp3"].last { try docker(["logs", $0]).contains("walk mac (operator) connected") }
        note("the window is on \(windowOn ?? "?")")
        note("host \(host) held by \(holder) (copy \(held.copy), epoch \(held.epoch))")

        // 5: kill the holder. The host redials through Caddy to another copy, the epoch goes
        // up, and the window reaches it again (SC-003: within 10 s).
        try docker(["kill", holder])
        let killed = Date()
        _ = await within(20, "the lease moves off \(holder)") {
            guard let now = await lease(host) else { return false }
            return now.copy != held.copy && now.epoch > held.epoch && now.expires > Date()
        }
        let moved = await within(20, "the window reaches the host again") { await reaches(toHost, host) }
        note("host back after \(String(format: "%.1f", Date().timeIntervalSince(killed))) s from the kill")
        #expect((moved ?? 99) <= 10)
        try docker(["start", holder])

        // 6: kill the copy the window is on: it reconnects through Caddy, and every host is
        // still listed.
        // Only what was said since the first kill: a restarted container keeps its old lines.
        let since = killed.formatted(.iso8601)
        let logs = try ["cp1", "cp2", "cp3"].map { ($0, try docker(["logs", "--since", since, $0])) }
        if let on = logs.last(where: { $0.1.contains("walk mac (operator) connected") })?.0 {
            note("the window is on \(on)")
            try docker(["kill", on])
            _ = await within(20, "the window lists the host again") {
                ((try? await call(control, DaemonAPI.Method.hostsList).decode([DaemonAPI.ControlHost].self)) ?? [])
                    .contains { $0.id == host && $0.state == "online" }
            }
            try docker(["start", on])
        }

        // 7: a code from one copy, used through Caddy wherever it lands: once only.
        let once = try code(["--client", "device"])
        _ = try await client(once, kind: .iPhone)
        await #expect(throws: (any Error).self) { _ = try await client(once, kind: .iPhone) }
        note("a code works once across copies")

        // 8: forget the device from the window: its socket, wherever it is, closes in 2 s.
        _ = await within(10, "the device is connected") { (try? await call(phoneControl, DaemonAPI.Method.hostsList)) != nil }
        _ = try await call(control, DaemonAPI.Method.clientsForget, JSONValue.object(["client": .string(phone.uuidString)]))
        _ = await within(2, "the forgotten device is cut off") {
            (try? await phoneControl.call(DaemonAPI.Method.hostsList)) == nil
        }

        // 9: two grant changes at once, from two operator windows.
        let (target, targetLink) = try await client(try code(["--client", "device"]), kind: .iPad)
        targetLink.disconnect()
        let (_, second) = try await client(try code(["--client", "operator"]), kind: .mac)
        defer { second.disconnect() }
        let other = DaemonClient(link: second.controlLink)
        try await other.connect(startIfNeeded: false)
        async let a: Result<JSONValue, any Error> = Result {
            try await call(control, DaemonAPI.Method.clientsSetGrant,
                                   JSONValue.object(["client": .string(target.uuidString), "grant": "operator"]))
        }
        async let b: Result<JSONValue, any Error> = Result {
            try await call(other, DaemonAPI.Method.clientsSetGrant,
                                 JSONValue.object(["client": .string(target.uuidString), "grant": "device"]))
        }
        let results = await [a, b]
        let refused = results.compactMap { if case .failure(let e as JSONRPCError) = $0 { e.code } else { nil } }
        note("race: \(results.map { if case .success = $0 { "ok" } else { "refused" } }) codes \(refused)")
        #expect(refused.allSatisfy { $0 == DaemonAPI.Failure.changedElsewhere })

        // 10: the store stops. Live calls carry on, pairing is refused, and /readyz says so.
        try docker(["stop", "minio"])
        defer { _ = try? docker(["start", "minio"]) }
        #expect(await reaches(toHost, host))
        do {
            _ = try await call(control, DaemonAPI.Method.clientsStartPairing, JSONValue.object(["grant": "device"]))
            Issue.record("pairing worked with the store stopped")
        } catch let error as JSONRPCError {
            note("pairing with the store stopped: \(error.code) \(error.message)")
            #expect(error.code == DaemonAPI.Failure.storeUnavailable)
        }
        note("live call with the store stopped: ok")
    }
}
