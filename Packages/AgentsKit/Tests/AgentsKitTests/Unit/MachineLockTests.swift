#if canImport(CryptoKit)
import CryptoKit
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

    /// A machine's key: P-256, X9.63.
    enum P256Key {
        static func make() -> Data { MachineLock.inviteKey().publicKey.x963Representation }
    }

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

    /// #3491 (D3): a host code with an invite is the version 4 code Go's `controllink.ParseCode`
    /// reads; the web page's `inviteCode` makes the same text (machineLock.test.mjs).
    @Test func anInviteGoesInAHostCode() {
        let code = "agents-control:2:h:-:KEY:SECRET:https%3A%2F%2Fx:-:Sam%27s"
        let pin = MachineLock.Pin(person: "sam.p", count: 3, head: Data(repeating: 9, count: 32))
        #expect(MachineLock.inviteCode(code, invite: Data(repeating: 7, count: 32), pin: pin)
            == "agents-control:4:h:-:KEY:SECRET:https%3A%2F%2Fx:-:Sam%27s:-:BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc:sam.p:3:CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk")
        // A client's code, or one already with an invite, comes back as it was.
        let client = "agents-control:2:c:-:KEY:SECRET:https%3A%2F%2Fx:-:Sam%27s"
        #expect(MachineLock.inviteCode(client, invite: Data(repeating: 7, count: 32), pin: pin) == client)
        #expect(MachineLock.escapeField("Sam’s Mac") == "Sam%E2%80%99s%20Mac")
    }

    /// #3491 (D3, D8): a machine added with an invite is in the lock with its sealing key, the
    /// invite is spent, and only machines the lock names are sealed to.
    @Test func aMachineAddedWithAnInviteIsSealedTo() async throws {
        let mac = LockSigningKey.ephemeral()
        let root = try MachineLock.sign(DaemonAPI.LockBody(kind: .root, person: "alex", key: mac.publicKey), after: nil, with: mac)
        var state = try MachineLock.check([root])
        let invite = MachineLock.inviteKey()
        try state.add(MachineLock.sign(DaemonAPI.LockBody(kind: .invite, person: "", key: invite.publicKey.x963Representation,
                                                          expires: Date().addingTimeInterval(300)), after: state, with: mac))
        let box = P256Key.make()
        // The machine signs its own addMachine with the invite's key, as agentsd does.
        var body = DaemonAPI.LockBody(kind: .addMachine, person: "alex", previous: state.head, signer: invite.publicKey.x963Representation,
                                      key: box, sealingKey: box, id: "h-box", name: "box")
        let data = try JSONEncoder().encode(body)
        try state.add(DaemonAPI.LockEntry(body: data, sig: try invite.signature(for: MachineLock.signed(data)).rawRepresentation))
        #expect(state.members[box]?.kind == .addMachine && state.members[invite.publicKey.x963Representation] == nil)
        #expect(MachineLock.sealsTo(state, key: box))
        body.key = P256Key.make()
        let stranger = body.key
        let recipients = [
            DaemonAPI.SealRecipient(id: "c:PHONE", name: "Phone", publicKey: stranger),
            DaemonAPI.SealRecipient(id: "m:h-box", name: "box", owner: "alex", publicKey: box),
            DaemonAPI.SealRecipient(id: "m:h-evil", name: "not mine", owner: "alex", publicKey: stranger),
            DaemonAPI.SealRecipient(id: "m:h-kim", name: "Kim's", owner: "kim", publicKey: box),
        ]
        let checked = state
        let signed = await MachineLock.signedRecipients(recipients) { person in person == "alex" ? checked : nil }
        #expect(signed.map(\.id) == ["c:PHONE", "m:h-box"])
    }

    /// A machine's request names it, and decodes with or without it.
    @Test func aMachinesRequestNamesIt() throws {
        let json = #"{"request":"r1","client":"h-box","machine":"h-box","name":"box","kind":"unknown","key":"","commitment":"","expires":0}"#
        let request = try JSONDecoder().decode(DaemonAPI.LockJoinRequest.self, from: Data(json.utf8))
        #expect(request.machine == "h-box")
    }

    @Test func eachClientKindIsAnEntrysKind() {
        #expect(MachineLock.clientKind(.mac) == "mac")
        #expect(MachineLock.clientKind(.iPhone) == "remote")
        #expect(MachineLock.clientKind(.iPad) == "remote")
        #expect(MachineLock.clientKind(.browser) == "web")
    }
}
#endif
