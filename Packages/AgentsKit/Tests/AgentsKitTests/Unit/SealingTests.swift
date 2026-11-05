#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import AgentsKitCore

/// Client sealing (#3397): the window and the Remote make Go's associated data byte for byte,
/// open what Go sealed (`Fixtures/sealing/vectors.json`, which Go's TestTheSealingVectorsOpen
/// and the web page's sealing.test.mjs read too), and what they seal for a recipient missing
/// opens there.
struct SealingTests {
    struct Vector: Decodable {
        var item: String
        var id: String?
        var user: String?
        var recipient: String
        var field: String
        var version: Int
        var kind: String?
        var vendor: String?
        var settings: DaemonAPI.OrgRouteSettings?
        var ad: String
        var value: String
        var sealed: Envelope

        var associated: Data {
            item == "userSecret"
                ? ClientSealing.userSecretAD(user: user ?? "", recipient: recipient, name: field, version: version)
                : ClientSealing.orgRouteAD(route: id ?? "", recipient: recipient, field: field, sealVersion: version,
                                           kind: kind ?? "", vendor: vendor, settings: settings)
        }
        var info: String { item == "userSecret" ? ClientSealing.userSecretPurpose : ClientSealing.orgRoutePurpose }
    }

    struct Vectors: Decodable {
        var privateKey: String
        var vectors: [Vector]
    }

    static func vectors() throws -> Vectors {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/sealing/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    static func raw(_ hex: String) -> Data {
        var out = Data()
        var at = hex.startIndex
        while at < hex.endIndex {
            let next = hex.index(at, offsetBy: 2)
            out.append(UInt8(hex[at..<next], radix: 16)!)
            at = next
        }
        return out
    }

    @Test func theAssociatedDataIsGosAndWhatGoSealedOpensHere() throws {
        let file = try Self.vectors()
        let key = try DeviceKey.software(privateKey: Self.raw(file.privateKey))
        #expect(file.vectors.count == 3)
        for v in file.vectors {
            #expect(String(decoding: v.associated, as: UTF8.self) == v.ad)
            let plain = try key.open(v.sealed, info: v.info, authenticating: v.associated)
            #expect(String(decoding: plain, as: UTF8.self) == v.value)
            #expect(throws: (any Error).self) {
                try key.open(v.sealed, info: v.info, authenticating: Data((v.ad + "x").utf8))
            }
        }
    }

    @Test func sealingWorkSealsACopyForEachRecipientMissing() throws {
        let admin = DeviceKey.ephemeral()
        let later = DeviceKey.ephemeral()
        let adminID = UUID()
        let laterID = UUID()
        let settings = DaemonAPI.OrgRouteSettings(address: "https://llm.acme.example")
        let me = ClientSealing.clientRecipient(adminID)
        let mine = try Envelope.seal(Data("sk-here".utf8), to: admin.publicKey, info: ClientSealing.orgRoutePurpose,
                                     authenticating: ClientSealing.orgRouteAD(route: "acme", recipient: me, field: "apiKey", sealVersion: 3,
                                                                              kind: "baseURL", vendor: "openai", settings: settings))
        let missing = DaemonAPI.SealRecipient(id: ClientSealing.clientRecipient(laterID), name: "Phone", publicKey: later.publicKey)
        let item = DaemonAPI.SealingItem(item: .orgRoute, id: "acme", user: nil, version: 3, kind: "baseURL", vendor: "openai",
                                         settings: settings, mine: ["apiKey": mine], missing: [missing])
        let added = ClientSealing.seal(DaemonAPI.SealingWork(items: [item]), with: admin, client: adminID)
        #expect(added.count == 1)
        let theirs = try #require(added.first?.values[missing.id]?["apiKey"])
        var copy = item
        copy.mine = ["apiKey": theirs]
        #expect(try ClientSealing.open(copy, with: later, client: laterID)["apiKey"] == Data("sk-here".utf8))
        // A control plane that changed the address gets nothing sealed again.
        var moved = item
        moved.settings = DaemonAPI.OrgRouteSettings(address: "https://elsewhere.example")
        #expect(ClientSealing.seal(DaemonAPI.SealingWork(items: [moved]), with: admin, client: adminID).isEmpty)
    }

    @Test func aSecretIsSetAboveTheKeptVersion() {
        let row = DaemonAPI.UserSecretRow(name: "A", updated: "", machines: [], leftOn: nil, version: 4, waiting: ["box"])
        #expect(UserScopeWords.nextVersion(row, now: Date(timeIntervalSince1970: 1)) == 5)
        #expect(UserScopeWords.nextVersion(nil, now: Date(timeIntervalSince1970: 1_762_300_000)) == 1_762_300_000_000)
        #expect(UserScopeWords.waiting(row) == "1 machine waits for one of your apps to seal it there. This happens when you open Agents.")
    }
}
#endif
