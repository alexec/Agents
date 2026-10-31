import Foundation
import Testing
@testable import AgentsKitCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The key exchange at the start of every WebSocket (058, R6, contracts/wire.md, T036).
@Suite("Proving keys to the control plane")
struct ControlAuthTests {
    let control = ControlAgreement.generate()
    let origin = "https://mini.local:8791"

    /// Runs a whole exchange: the server's side with `key`, the peer's with `peerKey`.
    func exchange(identity: ControlAuth.Identity, peerKey: Data, origin peerOrigin: String? = nil,
                  serverOrigin: String? = nil, controlSeen: Data? = nil,
                  key: @escaping (ControlAuth.Identity) async throws -> Data) async throws -> ControlAuth.Identity {
        let serverNonce = ControlAuth.nonce()
        let hello = ControlAuth.Hello(name: "test", control: ControlCode.base64url(controlSeen ?? control.publicKey),
                                      nonce: ControlCode.base64url(serverNonce), copy: "one")
        // Every message crosses as its line.
        guard case .hello(let heard)? = ControlAuth.Message(line: ControlAuth.Message.hello(hello).line) else {
            throw ControlAuth.Refusal(.badMessage)
        }
        let (auth, expect) = try ControlAuth.answer(heard, identity: identity, key: peerKey,
                                                    origin: peerOrigin ?? origin, kind: "mac",
                                                    expecting: control.publicKey)
        guard case .auth(let got)? = ControlAuth.Message(line: ControlAuth.Message.auth(auth).line) else {
            throw ControlAuth.Refusal(.badMessage)
        }
        let (who, mac) = try await ControlAuth.verify(got, serverNonce: serverNonce, origin: serverOrigin ?? origin, key: key)
        try ControlAuth.check(ControlAuth.OK(mac: ControlCode.base64url(mac)), expect: expect)
        return who
    }

    @Test func aClientProvesItsKeyAndTheControlPlaneProvesItsOwn() async throws {
        let client = ControlAgreement.generate()
        let id = UUID()
        let peerKey = try ControlAuth.clientKey(privateKey: client.privateKey, peer: control.publicKey, client: id)
        let who = try await exchange(identity: .client(id), peerKey: peerKey) { identity in
            guard case .client(let asked) = identity, asked == id else { throw ControlAuth.Refusal(.unknown) }
            return try ControlAuth.clientKey(privateKey: control.privateKey, peer: client.publicKey, client: asked)
        }
        #expect(who == .client(id))
    }

    @Test func aHostProvesItsKey() async throws {
        let host = ControlAgreement.generate()
        let id = MachineRef(rawValue: "k3v9x0qa")
        let peerKey = try ControlAuth.hostKey(privateKey: host.privateKey, peer: control.publicKey, host: id)
        let who = try await exchange(identity: .host(id), peerKey: peerKey) { _ in
            try ControlAuth.hostKey(privateKey: control.privateKey, peer: host.publicKey, host: id)
        }
        #expect(who == .host(id))
    }

    /// A code shown by one copy is checked by any other, with nothing secret in the store.
    @Test func aCodeFromOneCopyIsCheckedByAnother() async throws {
        let (id, secret) = ControlAuth.makeCodeSecret(controlPrivateKey: control.privateKey)
        #expect(ControlAuth.codeID(secret: secret) == id)
        let who = try await exchange(identity: .pairing(id), peerKey: ControlAuth.codeKey(secret: secret)) { identity in
            guard case .pairing(let asked) = identity,
                  let expected = ControlAuth.codeSecret(controlPrivateKey: control.privateKey, id: asked) else {
                throw ControlAuth.Refusal(.unknown)
            }
            return ControlAuth.codeKey(secret: expected)
        }
        #expect(who == .pairing(id))
        // A made-up secret with a real-looking id is not one.
        let forged = Data(secret.prefix(16)) + Data(repeating: 0, count: 16)
        #expect(forged != ControlAuth.codeSecret(controlPrivateKey: control.privateKey, id: id))
    }

    @Test func copiesProveTheyHoldTheControlKey() async throws {
        let key = ControlAuth.copyKey(controlPrivateKey: control.privateKey)
        let who = try await exchange(identity: .copy("b"), peerKey: key) { _ in key }
        #expect(who == .copy("b"))
        let stranger = ControlAuth.copyKey(controlPrivateKey: ControlAgreement.generate().privateKey)
        await #expect(throws: ControlAuth.Refusal(.badProof)) {
            _ = try await exchange(identity: .copy("b"), peerKey: stranger) { _ in key }
        }
    }

    @Test func aWrongKeyIsRefused() async throws {
        let id = UUID()
        let right = try ControlAuth.clientKey(privateKey: ControlAgreement.generate().privateKey,
                                              peer: control.publicKey, client: id)
        await #expect(throws: ControlAuth.Refusal(.badProof)) {
            _ = try await exchange(identity: .client(id), peerKey: Data(repeating: 1, count: 32)) { _ in right }
        }
    }

    /// A proof made for one control plane's address cannot be replayed to another.
    @Test func aProofForAnotherOriginIsRefused() async throws {
        let key = Data(repeating: 7, count: 32)
        await #expect(throws: ControlAuth.Refusal(.badProof)) {
            _ = try await exchange(identity: .copy("b"), peerKey: key, origin: "https://elsewhere:8791") { _ in key }
        }
    }

    /// A server that does not hold the key the peer trusts is not its control plane.
    @Test func theWrongControlPlaneIsNoticed() async throws {
        let key = Data(repeating: 7, count: 32)
        await #expect(throws: ControlAuth.Refusal(.wrongControlPlane)) {
            _ = try await exchange(identity: .copy("b"), peerKey: key,
                                   controlSeen: ControlAgreement.generate().publicKey) { _ in key }
        }
        // And one that answers with a MAC it could not have made.
        let (_, expect) = try ControlAuth.answer(
            ControlAuth.Hello(name: "t", control: ControlCode.base64url(control.publicKey),
                              nonce: ControlCode.base64url(ControlAuth.nonce()), copy: "a"),
            identity: .copy("b"), key: key, origin: origin, kind: "copy", expecting: nil)
        #expect(throws: ControlAuth.Refusal(.wrongControlPlane)) {
            try ControlAuth.check(ControlAuth.OK(mac: ControlCode.base64url(Data(repeating: 0, count: 32))), expect: expect)
        }
    }

    /// After a rotation (#997) a member that trusts the previous key still knows its
    /// control plane, and takes the new key only with the proof the previous key's holder
    /// makes: the same bytes as Go's (TestTheNewKeyProofIsTheClientsOwn).
    @Test func aRotatedKeyIsTakenOnlyWithItsProof() throws {
        let previous = ControlAgreement.generate().publicKey
        let hello = ControlAuth.Hello(name: "t", control: ControlCode.base64url(control.publicKey),
                                      nonce: ControlCode.base64url(ControlAuth.nonce()), copy: "a",
                                      previous: ControlCode.base64url(previous))
        let key = Data(repeating: 7, count: 32)
        _ = try ControlAuth.answer(hello, identity: .client(UUID()), key: key, origin: origin, kind: "mac", expecting: previous)
        #expect(throws: ControlAuth.Refusal(.wrongControlPlane)) {
            _ = try ControlAuth.answer(hello, identity: .client(UUID()), key: key, origin: origin, kind: "mac",
                                       expecting: ControlAgreement.generate().publicKey)
        }
        let shared = Data(repeating: 1, count: 32)
        let fresh = Data([4]) + Data(repeating: 2, count: 64)
        let proof = ControlAuth.newKeyProof(shared: shared, newKey: fresh)
        #expect(ControlCode.base64url(proof) == "v9-kYG-84IN39u6AMjxueMV9PJ0RFPVWlUAghG140Wg")
        var ok = ControlAuth.OK(mac: "", newKey: .init(key: ControlCode.base64url(fresh), proof: ControlCode.base64url(proof)))
        #expect(try ControlAuth.newKey(ok, shared: shared) == fresh)
        ok.newKey?.proof = ControlCode.base64url(Data(repeating: 0, count: 32))
        #expect(throws: ControlAuth.Refusal(.wrongControlPlane)) { _ = try ControlAuth.newKey(ok, shared: shared) }
        // The book keeps it, for the next dial and the next launch.
        let membership = ControlMembership(client: UUID(), controlKey: previous, addresses: [], name: "t",
                                           url: "https://control.example:8790", pin: nil)
        let book = EndpointBook(membership)
        ok.newKey?.proof = ControlCode.base64url(proof)
        book.answered(at: try #require(membership.endpointsToDial.first), ok: ok)
        #expect(book.current.controlKey == fresh)
    }

    /// A client says what it has (#1748); a host or a copy says nothing here.
    @Test func aClientSaysItsCapabilities() throws {
        let hello = ControlAuth.Hello(name: "t", control: ControlCode.base64url(control.publicKey),
                                      nonce: ControlCode.base64url(ControlAuth.nonce()), copy: "a")
        let key = Data(repeating: 7, count: 32)
        let (client, _) = try ControlAuth.answer(hello, identity: .client(UUID()), key: key, origin: origin, kind: "mac",
                                                 expecting: nil)
        #expect(client.capabilities == [Capability.clientWire1, Capability.clientTeam1])
        guard case .auth(let heard)? = ControlAuth.Message(line: ControlAuth.Message.auth(client).line) else {
            Issue.record("the auth line did not read back")
            return
        }
        #expect(heard.capabilities == [Capability.clientWire1, Capability.clientTeam1])
        let (copy, _) = try ControlAuth.answer(hello, identity: .copy("b"), key: key, origin: origin, kind: "copy",
                                               expecting: nil)
        #expect(copy.capabilities == nil)
    }

    @Test func aFlippedNonceIsRefused() async throws {
        let key = Data(repeating: 7, count: 32)
        let serverNonce = ControlAuth.nonce()
        let hello = ControlAuth.Hello(name: "t", control: ControlCode.base64url(control.publicKey),
                                      nonce: ControlCode.base64url(serverNonce), copy: "a")
        let (auth, _) = try ControlAuth.answer(hello, identity: .copy("b"), key: key, origin: origin, kind: "copy",
                                               expecting: control.publicKey)
        var other = serverNonce
        other[0] ^= 1
        await #expect(throws: ControlAuth.Refusal(.badProof)) {
            _ = try await ControlAuth.verify(auth, serverNonce: other, origin: origin) { _ in key }
        }
    }

    @Test func originsAreWrittenOneWay() {
        #expect(ControlAuth.origin(URL(string: "wss://Mini.Local:8791/v1/connect")!) == "https://mini.local:8791")
        #expect(ControlAuth.origin(URL(string: "https://agents.example.com")!) == "https://agents.example.com:443")
    }

    @Test func junkIsNotAMessage() {
        #expect(ControlAuth.Message(line: "{}") == nil)
        #expect(ControlAuth.Message(line: "not json") == nil)
        #expect(ControlAuth.Message(line: #"{"refused":{"reason":"spent"}}"#) == .refused(.spent))
        #expect(ControlAuth.Identity(text: "c:not-a-uuid") == nil)
        #expect(ControlAuth.Identity(text: "p:short") == nil)
    }

    #if canImport(CryptoKit)
    /// A key paired under the first build (CryptoKit, `ControlKeys`) proves itself under
    /// the pure-Swift derivation: nobody pairs again (FR-038).
    @Test func aKeyPairedUnderTheFirstBuildStillProvesItself() throws {
        let mac = P256.KeyAgreement.PrivateKey()
        let phone = P256.KeyAgreement.PrivateKey()
        let id = UUID()
        let ours = try ControlAuth.clientKey(privateKey: mac.rawRepresentation,
                                             peer: phone.publicKey.x963Representation, client: id)
        let theirs = try phone.sharedSecretFromKeyAgreement(with: mac.publicKey)
            .hkdfDerivedSymmetricKey(using: CryptoKit.SHA256.self, salt: Data(ControlAuth.clientSalt.utf8),
                                     sharedInfo: Data(id.uuidString.utf8), outputByteCount: 32)
        #expect(ours == theirs.withUnsafeBytes { Data($0) })
        #expect(ControlAgreement.hmacSHA256(key: ours, message: Data("x".utf8))
                == Data(CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: Data("x".utf8), using: theirs)))
    }
    #endif
}
