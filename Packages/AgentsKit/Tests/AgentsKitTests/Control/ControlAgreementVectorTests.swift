import Foundation
import Testing
@testable import AgentsKitCore

/// The bytes a browser must reproduce with WebCrypto to prove its key (071, T001).
///
/// Fixed keys, nonces and origin, run through the same calls the control plane makes, and
/// written to `Web/test/vectors.json`, which the spike page and the web app's tests read.
/// The file is checked in; this fails when what Swift derives no longer matches it. Set
/// `AGENTS_WRITE_WEB_VECTORS=1` to write it again.
@Suite("Control agreement vectors for the browser")
struct ControlAgreementVectorTests {
    static let file = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Web/test/vectors.json")

    @Test func theCheckedInVectorsAreWhatSwiftDerives() throws {
        let made = try Self.vectors()
        if ProcessInfo.processInfo.environment["AGENTS_WRITE_WEB_VECTORS"] == "1" {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try made.write(to: Self.file)
        }
        let stored = try Data(contentsOf: Self.file)
        #expect(stored == made, "Web/test/vectors.json is stale; run with AGENTS_WRITE_WEB_VECTORS=1")
    }

    static func vectors() throws -> Data {
        let controlPrivate = ControlAgreement.sha256(Data("agents-web-vector-control".utf8))
        let clientPrivate = ControlAgreement.sha256(Data("agents-web-vector-client".utf8))
        let controlPublic = try ControlAgreement.publicKey(privateKey: controlPrivate)
        let clientPublic = try ControlAgreement.publicKey(privateKey: clientPrivate)
        let client = UUID(uuidString: "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8")!
        let origin = "http://localhost:8893"
        let serverNonce = ControlAgreement.sha256(Data("agents-web-vector-server-nonce".utf8))
        let peerNonce = ControlAgreement.sha256(Data("agents-web-vector-peer-nonce".utf8))

        let shared = try ControlAgreement.sharedSecret(privateKey: clientPrivate, peerPublic: controlPublic)
        let clientKey = try ControlAuth.clientKey(privateKey: clientPrivate, peer: controlPublic, client: client)
        let clientIdentity = ControlAuth.Identity.client(client).text

        let codeID = Data((0..<16).map { UInt8($0) })
        let codeSecret = try #require(ControlAuth.codeSecret(controlPrivateKey: controlPrivate, id: hex(codeID)))
        let codeKey = ControlAuth.codeKey(secret: codeSecret)
        let codeIdentity = "p:" + (try #require(ControlAuth.codeID(secret: codeSecret)))

        func macs(_ key: Data, _ identity: String) -> [String: String] {
            ["peer": hex(ControlAuth.peerMAC(key: key, serverNonce: serverNonce, peerNonce: peerNonce,
                                             identity: identity, origin: origin)),
             "server": hex(ControlAuth.serverMAC(key: key, serverNonce: serverNonce, peerNonce: peerNonce,
                                                 identity: identity, origin: origin))]
        }

        let object: [String: Any] = [
            "about": "071 T001: written by ControlAgreementVectorTests. Bytes are hex; jwk is base64url.",
            "origin": origin,
            "serverNonce": hex(serverNonce),
            "peerNonce": hex(peerNonce),
            "control": ["private": hex(controlPrivate), "public": hex(controlPublic)],
            "client": [
                "id": client.uuidString,
                "identity": clientIdentity,
                "private": hex(clientPrivate),
                "public": hex(clientPublic),
                "jwk": ["kty": "EC", "crv": "P-256",
                        "d": base64url(clientPrivate),
                        "x": base64url(clientPublic.subdata(in: 1..<33)),
                        "y": base64url(clientPublic.subdata(in: 33..<65))],
                "salt": ControlAuth.clientSalt,
                "sharedX": hex(shared),
                "key": hex(clientKey),
                "mac": macs(clientKey, clientIdentity),
            ],
            "code": [
                "secret": hex(codeSecret),
                "secretBase64url": base64url(codeSecret),
                "identity": codeIdentity,
                "salt": "agents-control-code-v1",
                "key": hex(codeKey),
                "mac": macs(codeKey, codeIdentity),
            ],
        ]
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
