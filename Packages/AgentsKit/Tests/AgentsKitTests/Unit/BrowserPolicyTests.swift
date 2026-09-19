import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Where the browser pane may go")
struct BrowserPolicyTests {
    @Test(arguments: ["http://localhost:3000", "https://example.com", "about:blank", "file:///tmp/page.html"])
    func theFourAllowedSchemesAreAllowed(address: String) {
        #expect(BrowserPolicy.decide(URL(string: address)).isAllowed)
    }

    @Test(arguments: ["mailto:someone@example.com", "javascript:alert(1)", "ftp://example.com",
                      "data:text/html,<h1>hi</h1>", "tel:+441234567890", "agents://open"])
    func everythingElseIsRefused(address: String) {
        // Refuse by default: a scheme nobody considered is refused rather than allowed.
        // The app is not sandboxed, so this is the only gate there is (FR-034).
        let decision = BrowserPolicy.decide(URL(string: address))
        #expect(decision.isAllowed == false)
    }

    @Test func aRefusalSaysWhatItRefused() {
        guard case .refuse(let message) = BrowserPolicy.decide(URL(string: "mailto:a@b.com")) else {
            Issue.record("expected a refusal")
            return
        }
        // "It did nothing" is the worst answer, so the scheme is named.
        #expect(message.contains("mailto"))
    }

    @Test func nothingAtAllIsRefused() {
        #expect(BrowserPolicy.decide(nil).isAllowed == false)
    }

    @Test func schemeMatchingIgnoresCase() {
        #expect(BrowserPolicy.decide(URL(string: "HTTP://example.com")).isAllowed)
        #expect(BrowserPolicy.decide(URL(string: "HtTpS://example.com")).isAllowed)
    }

    @Test func aBareHostAndPortBecomesHTTP() {
        // What anyone actually types when a dev server is running.
        let url = BrowserPolicy.url(fromTyped: "localhost:3000")
        #expect(url?.scheme == "http")
        #expect(url?.host() == "localhost")
        #expect(url?.port == 3000)
    }

    @Test func aBareHostBecomesHTTP() {
        #expect(BrowserPolicy.url(fromTyped: "example.com")?.absoluteString == "http://example.com")
    }

    @Test func anAddressThatAlreadyHasASchemeIsLeftAlone() {
        #expect(BrowserPolicy.url(fromTyped: "https://example.com/x")?.absoluteString == "https://example.com/x")
    }

    @Test func surroundingSpaceIsIgnored() {
        #expect(BrowserPolicy.url(fromTyped: "  localhost:8080  ")?.port == 8080)
    }

    @Test func nothingTypedIsNothingToOpen() {
        #expect(BrowserPolicy.url(fromTyped: "") == nil)
        #expect(BrowserPolicy.url(fromTyped: "   ") == nil)
    }

    @Test func aTypedAddressStillHasToPassTheSchemeRule() {
        // The two halves compose: turning text into a URL does not make it allowed.
        let url = BrowserPolicy.url(fromTyped: "mailto:a@b.com")
        #expect(BrowserPolicy.decide(url).isAllowed == false)
    }
}
