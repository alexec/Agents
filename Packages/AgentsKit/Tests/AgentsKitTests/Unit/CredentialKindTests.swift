import Foundation
import Testing
@testable import AgentsKitCore

/// A pasted credential: Gemini's key is the only kind (056), and never prints (043, D1).
@Suite("A runtime credential")
struct CredentialKindTests {
    @Test(arguments: ["", "hello", "sk-ant-", "sk-ant-oat", "sk-ant-xyz-abcdefghijkl", "sk-12", "ghp_abcdefghijk"])
    func anythingElseIsRefused(_ text: String) {
        #expect(Secret(text) == nil)
    }

    @Test func itOnlyEverPrintsAsItsMask() throws {
        let secret = try #require(Secret("AQ." + "Ab8RN6SECRETSECRET-a3f9"))
        #expect(secret.mask == "key …a3f9")
        #expect("\(secret)" == "key …a3f9")
        #expect(String(describing: secret) == "key …a3f9")
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
        #expect(Secret("ghp_something-long-enough") == nil)
    }

    @Test func geminisVariables() {
        #expect(CredentialKind.variables(for: "gemini") == ["GEMINI_API_KEY", "GOOGLE_API_KEY"])
    }
}

/// Codex takes no key (047): a server's Codex signs in through the Mac's ChatGPT sign-in.
@Suite("No OpenAI key")
struct NoOpenAIKeyTests {
    @Test func anOpenAIKeyIsNobodys() {
        #expect(Secret("sk-" + "proj-FAKEFAKEFAKEFAKEFAKEFAKE1234") == nil)
        #expect(Secret("sk-" + "FAKEFAKEFAKEFAKEFAKE5678") == nil)
        #expect(CredentialKind.kinds(for: "codex").isEmpty)
    }

    /// Claude takes no token either (056): a server's Claude signs in through the Mac's
    /// own Claude sign-in, so a pasted token or key is nobody's.
    @Test func aClaudeTokenOrKeyIsNobodysNow() {
        #expect(Secret("sk-ant-api03-abcdefghijkl-9x9z") == nil)
        #expect(Secret("sk-ant-oat01-abcdefghijkl-a3f9") == nil)
        #expect(CredentialKind.kinds(for: "claude").isEmpty)
    }
}
