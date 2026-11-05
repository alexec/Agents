#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import AgentsKitCore

/// The recovery key (#3493, D4), against what Go made (`Fixtures/lock/recovery.json`, which Go's
/// TestTheRecoveryVectors writes and the web page's machineLock.test.mjs reads): the text, the
/// ways a person types it, and a sealed key that opens with the secret and signs for the lock.
@Suite("Machine lock recovery")
struct MachineLockRecoveryTests {
    struct Vectors: Decodable {
        var secret: Data
        var text: String
        var typed: [String]
        var typos: [String]
        var other: String
        var lock: DaemonAPI.Lock
        var `public`: Data
        var `private`: Data
    }

    static func vectors() throws -> Vectors {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/lock/recovery.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test func theTextIsGos() throws {
        let v = try Self.vectors()
        #expect(MachineLock.recoveryText(v.secret) == v.text)
        for typed in [v.text] + v.typed {
            #expect(try MachineLock.parseRecovery(typed) == v.secret)
        }
        for typo in v.typos {
            #expect(throws: MachineLock.RecoveryError.typo) { try MachineLock.parseRecovery(typo) }
        }
    }

    @Test func goSealedKeyOpensAndSigns() throws {
        let v = try Self.vectors()
        var state = try MachineLock.check(v.lock.entries)
        let publicKey = try #require(state.recovery)
        let sealed = try #require(state.recoverySealed)
        #expect(publicKey == v.public)
        let key = try MachineLock.openRecovery(v.secret, publicKey: publicKey, sealed: sealed)
        #expect(key.publicKey == v.public)
        // It signs as the lock's recovery key.
        let laptop = LockSigningKey.ephemeral()
        let entry = try MachineLock.sign(DaemonAPI.LockBody(kind: .addClient, person: "", key: laptop.publicKey), after: state, with: key)
        try state.add(entry)
        #expect(state.isSigner(laptop.publicKey))
        let other = try MachineLock.parseRecovery(v.other)
        #expect(throws: MachineLock.RecoveryError.notThisLock) {
            try MachineLock.openRecovery(other, publicKey: publicKey, sealed: sealed)
        }
    }

    @Test func aKeyMadeHereOpensWithItsText() throws {
        let made = try MachineLock.makeRecovery()
        #expect(made.text.count == 39)
        let key = try MachineLock.openRecovery(try MachineLock.parseRecovery(made.text.lowercased()), publicKey: made.publicKey, sealed: made.sealed)
        #expect(key.publicKey == made.publicKey)
    }
}
#endif
