#if canImport(Network)
import CryptoKit
import Foundation
import Network
import Testing
@testable import AgentsKitCore

/// The direct link's lock, over loopback with the keys the phone and the Mac really use
/// (security review, Phase 3). Nothing without the key gets a byte through, and the
/// bridge learns which device it is from the key, never from the device.
@Suite("The direct link's TLS", .serialized, .timeLimit(.minutes(1)))
struct LinkTLSTests {
    let mac = DeviceKey.ephemeral()
    let phone = DeviceKey.ephemeral()
    let phoneID = UUID()

    /// A listener taking `keys`, which hands back each ready connection's chosen identity
    /// and what it sent first.
    final class Listener: @unchecked Sendable {
        let chosen = ChosenIdentities()
        let listener: NWListener
        private let lock = NSLock()
        private var heard: [(identity: String?, suiteAgreed: Bool, line: String)] = []

        init(keys: [String: SymmetricKey]) throws {
            listener = try NWListener(using: LinkTLS.server(keys: keys, chosen: chosen), on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    let identity = self.chosen.take(for: connection)
                    let agreed = LinkTLS.agreedTheSuite(connection)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                        let line = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        self.lock.withLock { self.heard.append((identity, agreed, line)) }
                    }
                }
                connection.start(queue: .global())
            }
        }

        func start() async throws -> NWEndpoint.Port {
            listener.start(queue: .global())
            for _ in 0..<100 {
                if let port = listener.port, port.rawValue != 0 { return port }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CancellationError()
        }

        var all: [(identity: String?, suiteAgreed: Bool, line: String)] { lock.withLock { heard } }
        func stop() { listener.cancel() }
    }

    /// Connect, send one line, and say whether the handshake finished.
    private func send(_ line: String, to port: NWEndpoint.Port, identity: String, key: SymmetricKey) async -> Bool {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: LinkTLS.client(identity: identity, key: key))
        let transport = NWTransport(connection: connection)
        defer { transport.close() }
        do {
            try await transport.waitUntilReady(timeout: .seconds(5))
            try transport.write(line: line)
            try await Task.sleep(for: .milliseconds(300))
            return true
        } catch {
            return false
        }
    }

    @Test func thePhoneAndTheMacComeToTheSameKey() throws {
        #expect(try phone.linkKey(with: mac.publicKey, device: phoneID) == mac.linkKey(with: phone.publicKey, device: phoneID))
        #expect(try phone.linkKey(with: mac.publicKey, device: phoneID) != phone.linkKey(with: mac.publicKey, device: UUID()),
                "the id is part of it")
    }

    @Test func aPairedPhoneGetsThroughAndIsKnownByItsKey() async throws {
        let identity = LinkKey.deviceIdentity(phoneID)
        let server = try Listener(keys: [identity: try mac.linkKey(with: phone.publicKey, device: phoneID)])
        defer { server.stop() }
        let port = try await server.start()

        #expect(await send("hello", to: port, identity: identity, key: try phone.linkKey(with: mac.publicKey, device: phoneID)))
        let heard = try #require(server.all.first)
        #expect(heard.identity == identity)
        #expect(LinkKey.device(fromIdentity: heard.identity ?? "") == phoneID)
        #expect(heard.suiteAgreed, "ECDHE-PSK with ChaCha20, not plain PSK")
        #expect(heard.line.hasPrefix("hello"))
    }

    /// A phone coming straight back is told as itself again. A resumed TLS session skips
    /// choosing a key, which left the bridge not knowing who it was.
    @Test func aPhoneThatComesStraightBackIsKnownAgain() async throws {
        let identity = LinkKey.deviceIdentity(phoneID)
        let key = try phone.linkKey(with: mac.publicKey, device: phoneID)
        let server = try Listener(keys: [identity: try mac.linkKey(with: phone.publicKey, device: phoneID)])
        defer { server.stop() }
        let port = try await server.start()

        #expect(await send("first", to: port, identity: identity, key: key))
        #expect(await send("second", to: port, identity: identity, key: key))
        #expect(server.all.map(\.identity) == [identity, identity])
    }

    /// Somebody on the network who knows a paired phone's id, but not its key.
    @Test func anotherKeyUnderAPairedPhonesNameGetsNothingThrough() async throws {
        let identity = LinkKey.deviceIdentity(phoneID)
        let server = try Listener(keys: [identity: try mac.linkKey(with: phone.publicKey, device: phoneID)])
        defer { server.stop() }
        let port = try await server.start()

        let stranger = DeviceKey.ephemeral()
        #expect(await send("hello", to: port, identity: identity,
                           key: try stranger.linkKey(with: mac.publicKey, device: phoneID)) == false)
        #expect(server.all.isEmpty)
    }

    @Test func anUnknownNameGetsNothingThrough() async throws {
        let server = try Listener(keys: [LinkKey.deviceIdentity(phoneID): try mac.linkKey(with: phone.publicKey, device: phoneID)])
        defer { server.stop() }
        let port = try await server.start()
        #expect(await send("hello", to: port, identity: LinkKey.deviceIdentity(UUID()),
                           key: SymmetricKey(size: .bits256)) == false)
        #expect(server.all.isEmpty)
    }

    /// The code's secret opens the listener as a pairing connection, and names it as one.
    @Test func thePairingCodeOpensTheListener() async throws {
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let identity = LinkKey.pairingIdentity(secret)
        let server = try Listener(keys: [identity: LinkKey.pairing(secret)])
        defer { server.stop() }
        let port = try await server.start()

        #expect(await send("pairing", to: port, identity: identity, key: LinkKey.pairing(secret)))
        #expect(server.all.first?.identity == identity)
        #expect(LinkKey.isPairing(identity))
        #expect(!identity.contains(secret.base64EncodedString()), "the name gives nothing away")
    }
}
#endif
