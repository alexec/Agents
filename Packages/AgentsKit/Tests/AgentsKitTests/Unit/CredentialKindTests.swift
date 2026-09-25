import Foundation
import Testing
@testable import AgentsKitCore

/// Telling a pasted Claude credential's kind, and never printing it (043, D1).
@Suite("A runtime credential")
struct CredentialKindTests {
    @Test func aSubscriptionTokenAndAnAPIKeyAreToldApartByPrefix() throws {
        let token = try #require(Secret("sk-ant-oat01-abcdefghijkl-a3f9"))
        #expect(token.kind == .oauthToken)
        #expect(token.kind.environmentVariable == "CLAUDE_CODE_OAUTH_TOKEN")
        let key = try #require(Secret("  sk-ant-api03-abcdefghijkl-9x9z\n"))
        #expect(key.kind == .apiKey)
        #expect(key.kind.environmentVariable == "ANTHROPIC_API_KEY")
        #expect(key.reveal() == "sk-ant-api03-abcdefghijkl-9x9z")
    }

    @Test(arguments: ["", "hello", "sk-ant-", "sk-ant-oat", "sk-proj-abcdefgh", "ghp_abcdefghijk"])
    func anythingElseIsRefused(_ text: String) {
        #expect(Secret(text) == nil)
    }

    @Test func itOnlyEverPrintsAsItsMask() throws {
        let secret = try #require(Secret("sk-ant-oat01-SECRETSECRET-a3f9"))
        #expect(secret.mask == "sk-ant-oat…a3f9")
        #expect("\(secret)" == "sk-ant-oat…a3f9")
        #expect(String(describing: secret) == "sk-ant-oat…a3f9")
        #expect(!String(reflecting: secret).contains("SECRET"))
        #expect(!"\([secret])".contains("SECRET"))
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("SECRET"))
    }
}
