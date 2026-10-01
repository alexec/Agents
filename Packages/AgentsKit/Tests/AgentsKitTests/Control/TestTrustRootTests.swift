import Foundation
import Testing
@testable import AgentsKitCore

/// A walk's stand-in root (#61) is given as PEM or as bare base64, and both read the same.
@Suite("A walk's stand-in trust root")
struct TestTrustRootTests {
    let der = Data((0..<200).map { UInt8($0) })

    @Test func pemAndBase64ReadAlike() throws {
        let base64 = der.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { start in
            let from = base64.index(base64.startIndex, offsetBy: start)
            return String(base64[from..<(base64.index(from, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex)])
        }
        let pem = (["-----BEGIN CERTIFICATE-----"] + lines + ["-----END CERTIFICATE-----", ""]).joined(separator: "\n")
        #expect(TestTrustRoot.decode(pem) == der)
        #expect(TestTrustRoot.decode(base64) == der)
        #expect(TestTrustRoot.decode("not base64!") == nil)
    }
}
