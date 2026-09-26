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

/// Gemini's key (046): two shapes, one kind, never printed.
@Suite("A Gemini key")
struct GeminiKeyKindTests {
    @Test func bothShapesAreGeminiKeys() throws {
        for text in ["AIza" + "SyFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234", "AQ." + "Ab8RN6FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE5678"] {
            let secret = try #require(Secret(text))
            #expect(secret.kind == .geminiAPIKey)
            #expect(secret.kind.runtimeID == "gemini")
            #expect(secret.kind.environmentVariable == "GEMINI_API_KEY")
            #expect(secret.kind.isLentOnTheMac)
            #expect(!"\(secret)".contains(text.dropLast(4)))
            #expect(secret.mask.hasPrefix("key …"))
        }
    }

    @Test func tooShortOrOtherwiseIsNotOne() {
        #expect(Secret("AIza12") == nil)
        #expect(Secret("AQ.123") == nil)
        #expect(Secret("sk-live-something-long-enough") == nil)
    }

    @Test func claudesKindsAreUnchanged() {
        #expect(CredentialKind.kinds(for: "claude") == [.oauthToken, .apiKey])
        #expect(!CredentialKind.oauthToken.isLentOnTheMac && !CredentialKind.apiKey.isLentOnTheMac)
        #expect(CredentialKind.allVariables == ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"])
        #expect(CredentialKind.variables(for: "gemini") == ["GEMINI_API_KEY", "GOOGLE_API_KEY"])
    }
}
