#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKitCore

/// The machine lock's checks and the join's digits (#3490), against what Go signed and made
/// (`Fixtures/lock/vectors.json`, which Go's TestTheLockVectors writes and the web page's
/// machineLock.test.mjs reads), so the three check a chain and make the digits the same way.
@Suite("Machine lock")
struct MachineLockTests {
    struct Member: Decodable {
        var key: Data
        var kind: String
        var name: String?
        var clientKind: String?
    }

    struct Join: Decodable {
        var key: Data
        var clientNonce: Data
        var signerNonce: Data
        var commitment: Data
        var digits: String
    }

    struct Vectors: Decodable {
        var lock: DaemonAPI.Lock
        var root: String
        var head: String
        var members: [Member]
        var forged: DaemonAPI.Lock
        var join: Join
    }

    static func vectors() throws -> Vectors {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/lock/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func whatGoSignedChecksHere() throws {
        let file = try Self.vectors()
        let state = try MachineLock.check(file.lock.entries)
        #expect(Self.hex(state.root) == file.root)
        #expect(Self.hex(state.head) == file.head)
        #expect(state.person == file.lock.person)
        for want in file.members {
            let member = state.members[want.key]
            #expect(member?.kind.rawValue == want.kind && member?.name == want.name && member?.clientKind == want.clientKind)
            #expect(state.isSigner(want.key))
        }
        #expect(throws: MachineLock.Failure.self) { try MachineLock.check(file.forged.entries) }
        do {
            _ = try MachineLock.check(file.forged.entries)
        } catch {
            guard case .forged = error else { Issue.record("\(error)"); return }
        }
    }

    @Test func theDigitsAreGos() throws {
        let join = try Self.vectors().join
        #expect(MachineLock.commitment(key: join.key, nonce: join.clientNonce) == join.commitment)
        #expect(MachineLock.digits(key: join.key, clientNonce: join.clientNonce, signerNonce: join.signerNonce) == join.digits)
        #expect(MachineLock.shown("012345") == "012 345")
    }

    @Test func aChainSignedHereChecksAndFollows() throws {
        let mac = LockSigningKey.ephemeral(), phone = LockSigningKey.ephemeral(), stranger = LockSigningKey.ephemeral()
        let root = try MachineLock.sign(DaemonAPI.LockBody(kind: .root, person: "alex", key: mac.publicKey, clientKind: "mac"),
                                        after: nil, with: mac)
        var state = try MachineLock.check([root])
        let pin = state.pin
        let add = try MachineLock.sign(DaemonAPI.LockBody(kind: .addClient, person: "", key: phone.publicKey, name: "Phone",
                                                          clientKind: "remote"), after: state, with: mac)
        try state.add(add)
        #expect(state.isSigner(phone.publicKey))
        let lock = DaemonAPI.Lock(person: "alex", entries: [root, add])
        #expect(try MachineLock.follow(pin, lock).count == 2)
        // Kept back, or forked: refused.
        #expect(throws: MachineLock.Failure.behind("2 entries, and 3 were seen")) {
            try MachineLock.follow(MachineLock.Pin(person: "alex", count: 3, head: Data()), lock)
        }
        let other = try MachineLock.sign(DaemonAPI.LockBody(kind: .root, person: "alex", key: stranger.publicKey),
                                         after: nil, with: stranger)
        #expect(throws: MachineLock.Failure.self) { try MachineLock.follow(pin, DaemonAPI.Lock(person: "alex", entries: [other])) }
        // A key that is not in the lock cannot add one.
        let first = try MachineLock.check([root])
        let forged = try MachineLock.sign(DaemonAPI.LockBody(kind: .addClient, person: "", key: phone.publicKey),
                                          after: first, with: stranger)
        #expect(throws: MachineLock.Failure.self) { try MachineLock.check([root, forged]) }
    }

    @Test func eachClientKindIsAnEntrysKind() {
        #expect(MachineLock.clientKind(.mac) == "mac")
        #expect(MachineLock.clientKind(.iPhone) == "remote")
        #expect(MachineLock.clientKind(.iPad) == "remote")
        #expect(MachineLock.clientKind(.browser) == "web")
    }
}
#endif
