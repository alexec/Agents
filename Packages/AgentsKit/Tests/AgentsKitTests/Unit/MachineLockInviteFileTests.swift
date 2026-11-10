#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import AgentsKitCore

/// The invite the Mac window keeps for its own host (#4248): the file Go's
/// `controllink.LoadLockInvite` reads, 0600, with the invite's 32-byte private key.
@Suite("Machine lock invite file")
struct MachineLockInviteFileTests {
    struct GoInvite: Decodable {
        var key: Data
        var person: String
        var count: Int
        var head: Data
    }

    @Test func theFileIsGos() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "invite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let invite = MachineLock.inviteKey()
        let pin = MachineLock.Pin(person: "p-1", count: 2, head: Data(repeating: 7, count: 32))

        try MachineLock.keepInvite(invite.rawRepresentation, pin: pin, in: locations)
        try MachineLock.keepInvite(invite.rawRepresentation, pin: pin, in: locations)

        let kept = try JSONDecoder().decode(GoInvite.self, from: Data(contentsOf: locations.lockInvite))
        #expect(kept.key.count == 32)
        #expect(try P256.Signing.PrivateKey(rawRepresentation: kept.key).publicKey.rawRepresentation == invite.publicKey.rawRepresentation)
        #expect(kept.person == pin.person && kept.count == pin.count && kept.head == pin.head)
        let mode = try FileManager.default.attributesOfItem(atPath: locations.lockInvite.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["lock-invite.json"])
    }
}
#endif
