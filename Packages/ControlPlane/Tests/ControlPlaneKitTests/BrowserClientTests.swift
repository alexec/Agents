import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// A browser as a client (071, contracts/browser-auth.md): it pairs and connects through the
/// loopback listener, its proofs are bound to that listener's origin, and the kinds stay on
/// their own listeners.
@Suite("A browser as a client", .timeLimit(.minutes(2)))
struct BrowserClientTests {
    let base = ControlServiceTests()
    var control: (privateKey: Data, publicKey: Data) { base.control }

    struct Running {
        let service: ControlService
        let tls: URL
        let web: URL
        var webOrigin: String { ControlAuth.origin(web)! }
    }

    func start() async throws -> Running {
        let port = try await freePort()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        var configuration = ControlService.Configuration(store: MemoryStore(), privateKey: control.privateKey, url: url,
                                                         bind: "127.0.0.1", port: port, name: "test", machineID: "m")
        configuration.web = .init(folder: LoopbackListenerTests.dist, port: 0)
        let service = try ControlService(configuration)
        try await service.start()
        let web = try #require(service.webPort)
        return Running(service: service, tls: url, web: URL(string: "http://localhost:\(web)")!)
    }

    /// Dials the loopback listener as a page on it would, and proves `credentials` with the
    /// transcript bound to `origin` (the listener's own, unless a test says otherwise).
    func joinWeb(_ running: Running, _ credentials: ControlAuth.Credentials, origin: String? = nil) async throws -> PrefixReader {
        let socket = try await ControlDial.connect(running.web, origin: running.webOrigin)
        return try await ControlAuth.join(socket, origin: origin ?? running.webOrigin, as: credentials).transport
    }

    func joinTLS(_ running: Running, _ credentials: ControlAuth.Credentials, origin: String? = nil) async throws -> PrefixReader {
        let socket = try await ControlDial.connect(running.tls)
        return try await ControlAuth.join(socket, origin: origin ?? ControlAuth.origin(running.tls)!, as: credentials).transport
    }

    /// Holds `code` on `join`, announces `kind`, and returns the reply's result.
    func announce(_ code: String, kind: ClientRecord.Kind, name: String = "Chrome", id: UUID = UUID(),
                  publicKey: Data, join: (ControlAuth.Credentials) async throws -> PrefixReader) async throws -> JSONValue {
        let parsed = try #require(ControlCode(text: code))
        let codeID = try #require(ControlAuth.codeID(secret: parsed.secret))
        let reader = try await join(.init(identity: .pairing(codeID), key: ControlAuth.codeKey(secret: parsed.secret),
                                          kind: kind.rawValue, controlKey: parsed.controlKey))
        defer { reader.close() }
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(1), method: DaemonAPI.Method.clientsAnnounce,
            params: try JSONValue.encoding(DaemonAPI.ClientAnnounce(id: id, publicKey: publicKey, name: name, kind: kind)))))
        let line = try #require(try await reader.next(within: 10))
        switch try JSONRPCCodec.decode(line: line) {
        case .success(_, let result): return result
        case .failure(_, let error): throw error
        default: throw ControlService.Failure("not a reply: \(line)")
        }
    }

    /// A browser paired by a device code through the loopback listener, and its credentials.
    func pairBrowser(_ running: Running, grant: Grant = .device) async throws -> (UUID, ControlAuth.Credentials) {
        let key = ControlAgreement.generate()
        let id = UUID()
        _ = try await announce(try await running.service.codes.issue(.client(grant)).text, kind: .browser, id: id,
                               publicKey: key.publicKey) { try await joinWeb(running, $0) }
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: control.publicKey, client: id)
        return (id, .init(identity: .client(id), key: shared, kind: "browser", controlKey: control.publicKey))
    }

    func refusal(_ body: () async throws -> PrefixReader) async -> ControlAuth.Reason? {
        do {
            let reader = try await body()
            reader.close()
            return nil
        } catch let refusal as ControlAuth.Refusal {
            return refusal.reason
        } catch {
            Issue.record("not a refusal: \(error)")
            return nil
        }
    }

    // MARK: Pairing and connecting

    @Test func aBrowserPairsAndConnectsThroughTheLoopbackListener() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (id, credentials) = try await pairBrowser(running)

        let record = try #require(await running.service.records.client(id))
        #expect(record.kind == .browser)
        #expect(record.grant == .device)
        #expect(record.name.hasPrefix("Chrome on "))
        #expect(record.name.count > "Chrome on ".count)

        let reader = try await joinWeb(running, credentials)
        defer { reader.close() }
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(7), method: DaemonAPI.Method.controlStatus, params: nil)))
        let line = try #require(try await reader.next(within: 10))
        guard case .success(.number(7), _) = try JSONRPCCodec.decode(line: line) else {
            Issue.record("control/status was not answered: \(line)"); return
        }
    }

    @Test func twoTabsOfOneBrowserWorkAtOnce() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (_, credentials) = try await pairBrowser(running)
        let first = try await joinWeb(running, credentials)
        let second = try await joinWeb(running, credentials)
        defer { first.close(); second.close() }
        for (n, reader) in [first, second].enumerated() {
            try reader.write(line: JSONRPCCodec.encode(.request(id: .number(n + 1), method: DaemonAPI.Method.controlStatus,
                                                                params: nil)))
            let line = try #require(try await reader.next(within: 10))
            guard case .success = try JSONRPCCodec.decode(line: line) else { Issue.record("tab \(n + 1): \(line)"); return }
        }
    }

    // MARK: The origin each proof is bound to (FR-006)

    @Test func aProofMadeForTheTLSAddressFailsOnTheLoopbackListener() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (_, credentials) = try await pairBrowser(running)
        #expect(await refusal { try await joinWeb(running, credentials, origin: ControlAuth.origin(running.tls)!) } == .badProof)
    }

    @Test func aProofMadeForTheLoopbackListenerFailsOnTheTLSAddress() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (_, window, credentials) = try await base.pairedClient(at: running.tls,
            code: try await running.service.codes.issue(.client(.operator)).text)
        window.disconnect()
        #expect(await refusal { try await joinTLS(running, credentials, origin: running.webOrigin) } == .badProof)
    }

    // MARK: Kinds on their own listeners

    @Test func aBrowserKeyIsRefusedOnTheTLSAddress() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (_, credentials) = try await pairBrowser(running)
        #expect(await refusal { try await joinTLS(running, credentials) } == .unknown)
    }

    @Test func aWindowKeyIsRefusedOnTheLoopbackListener() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (_, window, credentials) = try await base.pairedClient(at: running.tls,
            code: try await running.service.codes.issue(.client(.operator)).text)
        window.disconnect()
        #expect(await refusal { try await joinWeb(running, credentials) } == .unknown)
    }

    @Test func aBrowserCannotPairThroughTLSNorAnythingElseThroughLoopback() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let key = ControlAgreement.generate().publicKey
        await #expect(throws: JSONRPCError.self) {
            _ = try await announce(try await running.service.codes.issue(.client(.device)).text, kind: .browser,
                                   publicKey: key) { try await joinTLS(running, $0) }
        }
        await #expect(throws: JSONRPCError.self) {
            _ = try await announce(try await running.service.codes.issue(.client(.device)).text, kind: .iPhone,
                                   publicKey: key) { try await joinWeb(running, $0) }
        }
        #expect(await running.service.records.clients.isEmpty)
    }

    @Test func aHostCodeIsRefusedOnTheLoopbackListener() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let code = try #require(ControlCode(text: try await running.service.codes.issue(.host).text))
        let id = try #require(ControlAuth.codeID(secret: code.secret))
        #expect(await refusal {
            try await joinWeb(running, .init(identity: .enrolling(id), key: ControlAuth.codeKey(secret: code.secret),
                                             kind: "host", controlKey: code.controlKey))
        } == .unknown)
    }

    @Test func aBrowserIsNeverARelaysDevice() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        _ = try await pairBrowser(running)
        let clients = await running.service.methods.allClients
        #expect(clients.count == 1)
        #expect(clients.allSatisfy { $0.kind == .browser })
    }

    // MARK: Forgetting (FR-014, FR-015)

    /// Sends a control plane method on a joined socket and reads its reply.
    func ask(_ reader: PrefixReader, _ method: String, id: Int = 9) async throws -> JSONRPCMessage {
        try reader.write(line: ControlWire.wrap(host: nil, message: JSONRPCCodec.encode(.request(id: .number(id), method: method,
                                                                                                     params: nil))))
        // A reply from the control plane itself is {"m": …}, with no "h".
        guard let line = try await reader.next(within: 10),
              let message = try JSONValue.parse(Data(line.utf8))["m"] else {
            throw ControlService.Failure("no reply to \(method)")
        }
        return try JSONRPCCodec.decode(line: String(decoding: try JSONEncoder().encode(message), as: UTF8.self))
    }

    /// Whether the socket ends within `seconds`.
    func ends(_ reader: PrefixReader, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            do {
                guard try await reader.next(within: deadline.timeIntervalSinceNow) != nil else { return true }
            } catch {
                return true
            }
        }
        return false
    }

    @Test func aBrowserForgetsItselfAndIsThenRefusedAsForgotten() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        _ = try await operatorWindow(running)
        let (id, credentials) = try await pairBrowser(running)
        let tab = try await joinWeb(running, credentials)
        let other = try await joinWeb(running, credentials)
        guard case .success = try await ask(tab, DaemonAPI.Method.clientsForgetSelf) else {
            Issue.record("forgetSelf was not answered with success"); return
        }
        #expect(await ends(tab, within: 2))
        #expect(await ends(other, within: 2))
        #expect(await running.service.records.client(id) == nil)
        #expect(await refusal { try await joinWeb(running, credentials) } == .forgotten)
    }

    /// A window paired as an operator: a set-up always has one, and the store refuses to
    /// forget anything that would leave none (058 FR-016).
    func operatorWindow(_ running: Running) async throws -> UUID {
        let (window, link, _) = try await base.pairedClient(at: running.tls,
            code: try await running.service.codes.issue(.client(.operator)).text)
        link.disconnect()
        return window
    }

    @Test func theLastOperatorCannotForgetItself() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (id, credentials) = try await pairBrowser(running, grant: .operator)
        let tab = try await joinWeb(running, credentials)
        defer { tab.close() }
        guard case .failure(_, let error) = try await ask(tab, DaemonAPI.Method.clientsForgetSelf) else {
            Issue.record("the last operator forgot itself"); return
        }
        #expect(error.code == DaemonAPI.Failure.lastOperator)
        #expect(await running.service.records.client(id) != nil)
    }

    @Test func forgettingFromSettingsCutsTheBrowserOffWithinTwoSeconds() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (window, _, _) = try await base.pairedClient(at: running.tls,
            code: try await running.service.codes.issue(.client(.operator)).text)
        let (id, credentials) = try await pairBrowser(running)
        let tab = try await joinWeb(running, credentials)
        let started = Date()
        _ = try await running.service.methods.handle(
            method: DaemonAPI.Method.clientsForget, params: ["client": .string(id.uuidString)],
            from: .init(session: UUID(), client: window, grant: .operator, kind: .mac))
        #expect(await ends(tab, within: 2))
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(await refusal { try await joinWeb(running, credentials) } == .forgotten)
    }

    @Test func forgetSelfIsOpenToADeviceAndOnlyForgetsItself() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        _ = try await operatorWindow(running)
        let (first, _) = try await pairBrowser(running)
        let (second, credentials) = try await pairBrowser(running)
        let tab = try await joinWeb(running, credentials)
        let reply = try await ask(tab, DaemonAPI.Method.clientsForgetSelf)
        guard case .success = reply else {
            Issue.record("a device could not forget itself: \(reply)"); return
        }
        await eventually { await running.service.records.client(second) == nil }
        #expect(await running.service.records.client(first) != nil)
    }
}

