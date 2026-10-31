import Foundation
import Testing
@testable import AgentsKitCore

/// No runtime takes a pasted credential now that Gemini, the only kind Settings ever
/// offered (056), is retired (#3043): `CredentialKind` has no case, so nothing is ever a
/// `Secret`, and every runtime's kind list is empty. The type stays for
/// `PoolEntry.credentialKind` (052).
@Suite("A runtime credential")
struct CredentialKindTests {
    @Test(arguments: ["", "hello", "sk-ant-", "AIzaSyFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234",
                       "AQ.Ab8RN6FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE5678", "ghp_abcdefghijk"])
    func nothingIsEverACredential(_ text: String) {
        #expect(Secret(text) == nil)
    }

    @Test(arguments: ["claude", "codex", "grok", "copilot", "cursor", "antigravity", "opencode"])
    func noRuntimeTakesOne(_ runtimeID: String) {
        #expect(CredentialKind.kinds(for: runtimeID).isEmpty)
        #expect(CredentialKind.variables(for: runtimeID).isEmpty)
    }
}
