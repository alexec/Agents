@testable import AgentsKitCore
import Foundation
import Testing

/// Open File's save sends the digest of the text it began from (#1858), worked out as the host
/// works it out (Go's textDigest), so a file changed since is refused, not written over.
@Suite("Artifact write base")
struct ArtifactWriteBaseTests {
    @Test func theBaseIsTheTextsSHA256InLowerCaseHex() {
        #expect(DaemonAPI.ArtifactWriteRequest.digest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(DaemonAPI.ArtifactWriteRequest.digest("# hi") == "8a5d8b28d66ae90b5876fe0337b963d9f66ab1047f8c866ff4646b73a8a3aa41")
        #expect(DaemonAPI.ArtifactWriteRequest.digest("café") == "850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e")
    }

    @Test func aRequestWithNoBaseSaysNothingOfOne() throws {
        let json = try JSONEncoder().encode(DaemonAPI.ArtifactWriteRequest(agentID: UUID(), path: "/p/a.txt", text: "x"))
        #expect(!String(decoding: json, as: UTF8.self).contains("base"))
    }
}
