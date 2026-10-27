import Foundation
import Testing
@testable import AgentsKitCore

/// The window's direct way to this Mac's host (#1118): the exchange over the host's local
/// socket, and the control plane's route when that is not there. Agentsd's side is
/// Go/internal/agentsd/localpath_test.go.
@Suite("The direct local path")
struct LocalHostLinkTests {
    final class Line: LineTransport, @unchecked Sendable {
        func write(line: String) throws {}
        func lines() -> AsyncThrowingStream<String, any Error> { AsyncThrowingStream { _ in } }
        func close() {}
    }

    /// A host on a socket in a folder of its own, as agentsd's `acceptLocal` is: it says
    /// hello with its key, checks the window's proof against the key it was told of, and
    /// answers `ok` naming itself, once.
    final class FakeHost: @unchecked Sendable {
        let folder: URL
        let place: URL
        let listening: Int32
        let hostKey = ControlAgreement.generate()

        init() throws {
            // Short: a socket's path is at most 104 bytes.
            folder = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            place = folder.appendingPathComponent(LocalHostLink.socketName(controlKey: Data("control key".utf8)))
            listening = place.path.withCString { path in
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                    strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), path, 103)
                }
                _ = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                listen(fd, 4)
                return fd
            }
        }

        /// Serves one window that proves `windowKey` as `client`, as host `name`. Says whether
        /// the window sent its auth at all.
        @discardableResult
        func serve(client: UUID, windowPublic: Data, as name: MachineRef) async throws -> Bool {
            let fd = accept(listening, nil, nil)
            let reader = PrefixReader(FDTransport(socket: fd))
            let nonce = ControlAuth.nonce()
            try reader.write(line: ControlAuth.Message.hello(.init(name: name.rawValue,
                                                                    control: ControlCode.base64url(hostKey.publicKey),
                                                                    nonce: ControlCode.base64url(nonce), copy: "")).line)
            guard let line = try? await reader.next(within: 5), case .auth(let auth)? = ControlAuth.Message(line: line) else {
                reader.close()
                return false
            }
            do {
                let (_, mac) = try await ControlAuth.verify(auth, serverNonce: nonce, origin: LocalHostLink.origin) { identity in
                    guard case .client(let id) = identity, id == client else { throw ControlAuth.Refusal(.unknown) }
                    return try ControlAuth.clientKey(privateKey: self.hostKey.privateKey, peer: windowPublic, client: id)
                }
                try reader.write(line: ControlAuth.Message.ok(.init(mac: ControlCode.base64url(mac), host: name)).line)
                try reader.write(line: #"{"jsonrpc":"2.0","method":"daemon/hello"}"#)
            } catch let refusal as ControlAuth.Refusal {
                try reader.write(line: ControlAuth.Message.refused(refusal.reason).line)
                reader.close()
            }
            return true
        }

        func stop() {
            close(listening)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Agentsd names the socket the same way (LocalSocketName's test key).
    @Test func theSocketIsNamedAsAgentsdNamesIt() {
        #expect(LocalHostLink.socketName(controlKey: Data("control key".utf8)) == "abf3614ee065.sock")
    }

    @Test func aPairedWindowReachesItsHostDirectly() async throws {
        let host = try FakeHost()
        defer { host.stop() }
        let window = ControlAgreement.generate()
        let id = UUID()
        async let served = host.serve(client: id, windowPublic: window.publicKey, as: .mac)
        let link = LocalHostLink(socket: host.place, client: id, privateKey: window.privateKey, host: .mac)
        let transport = try await link.transport()
        var lines = transport.lines().makeAsyncIterator()
        #expect(try await lines.next()?.contains("daemon/hello") == true)
        _ = try await served
        transport.close()
    }

    @Test func aWindowTheHostDoesNotKnowIsRefused() async throws {
        let host = try FakeHost()
        defer { host.stop() }
        let window = ControlAgreement.generate()
        async let served = host.serve(client: UUID(), windowPublic: window.publicKey, as: .mac)
        let link = LocalHostLink(socket: host.place, client: UUID(), privateKey: window.privateKey, host: .mac)
        await #expect(throws: ControlAuth.Refusal.self) { _ = try await link.transport() }
        _ = try await served
    }

    @Test func anotherHostOnTheSocketIsNotUsed() async throws {
        let host = try FakeHost()
        defer { host.stop() }
        let window = ControlAgreement.generate()
        let id = UUID()
        async let served = host.serve(client: id, windowPublic: window.publicKey, as: MachineRef(rawValue: "box"))
        let link = LocalHostLink(socket: host.place, client: id, privateKey: window.privateKey, host: .mac)
        await #expect(throws: (any Error).self) { _ = try await link.transport() }
        // Gone at its hello, before any proof (#1497): the host never counts it as connected,
        // and a client that keeps trying (`.mac`, with a control plane elsewhere) costs nothing.
        #expect(try await served == false)
    }

    /// No socket: the control plane's route, and it says so.
    @Test func noSocketGoesThroughTheControlPlane() async throws {
        let went = Went()
        let local = LocalHostLink(socket: URL(fileURLWithPath: "/tmp/no-such-\(UUID().uuidString.prefix(8)).sock"),
                                  client: UUID(), privateKey: ControlAgreement.generate().privateKey, host: .mac)
        let link = LocalFirstLink(local: local, fallback: Through()) { went.record($0) }
        _ = try await link.transport()
        #expect(went.directs == [false])
    }

    final class Went: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Bool] = []
        func record(_ direct: Bool) { lock.withLock { seen.append(direct) } }
        var directs: [Bool] { lock.withLock { seen } }
    }

    struct Through: DaemonLink {
        func transport() async throws -> any LineTransport { Line() }
    }
}
