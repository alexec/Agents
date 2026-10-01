import Foundation
import Testing
@testable import AgentsKitCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The Linux host's keys are the Mac listener's keys (058, T044).
@Suite("Control agreement")
struct ControlAgreementTests {
    @Test func sha256MatchesTheKnownAnswers() {
        #expect(hex(ControlAgreement.sha256(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(ControlAgreement.sha256(Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func theGeneratorIsPrivateKeyOne() throws {
        let one = Data(repeating: 0, count: 31) + [1]
        let pub = try ControlAgreement.portablePublicKey(privateKey: one)
        #expect(hex(pub) == "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
    }

    @Test func twiceTheGeneratorIsTheKnownPoint() throws {
        let two = Data(repeating: 0, count: 31) + [2]
        let pub = try ControlAgreement.portablePublicKey(privateKey: two)
        #expect(hex(pub) == "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1")
    }

    #if canImport(CryptoKit)
    @Test func keysMatchCryptoKit() throws {
        for _ in 0..<4 {
            let a = P256.KeyAgreement.PrivateKey()
            let b = P256.KeyAgreement.PrivateKey()
            // This file's own arithmetic, which Linux uses, held to CryptoKit's.
            #expect(try ControlAgreement.portablePublicKey(privateKey: a.rawRepresentation) == a.publicKey.x963Representation)
            let ours = try ControlAgreement.portableSharedSecret(privateKey: a.rawRepresentation,
                                                        peerPublic: b.publicKey.x963Representation)
            let kit = try a.sharedSecretFromKeyAgreement(with: b.publicKey)
            #expect(ours == kit.withUnsafeBytes { Data($0) })
            let host = HostID(rawValue: "devbox01")
            let derived = kit.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                      salt: Data("agents-control-host-v1".utf8),
                                                      sharedInfo: Data(host.rawValue.utf8), outputByteCount: 32)
            #expect(try ControlAgreement.hostKey(privateKey: a.rawRepresentation,
                                                 peer: b.publicKey.x963Representation, host: host)
                    == derived.withUnsafeBytes { Data($0) })
        }
        let secret = Data((0..<32).map { UInt8($0 &+ 1) })
        let code = ControlCode(purpose: .host, controlKey: Data([0x04]) + Data(repeating: 2, count: 64),
                               secret: secret, addresses: ["127.0.0.1:1"], name: "t")
        #expect(ControlAgreement.codeIdentity(secret: secret, host: true) == ControlKeys.codeIdentity(code))
        let codeKey = ControlKeys.codeKey(secret)
        #expect(ControlAgreement.codeKey(secret) == codeKey.withUnsafeBytes { Data($0) })
        #expect(ControlAgreement.sha256(secret) == Data(SHA256.hash(data: secret)))
    }
    #endif

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
