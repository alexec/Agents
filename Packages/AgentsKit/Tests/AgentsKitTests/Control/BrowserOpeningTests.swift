import Foundation
import Testing
@testable import AgentsKitCore

/// Open in Browser (#109): says why rather than opening a page that isn't served, opens a
/// paired browser's page directly, and otherwise pairs with a code in the fragment.
@Suite("Open in Browser")
struct BrowserOpeningTests {
    let served = DaemonAPI.WebRemoteStatus(port: 8792, served: true)

    @Test func aPageNotServedIsExplainedNotOpened() {
        let taken = DaemonAPI.WebRemoteStatus(port: 8792, served: false, reason: DaemonAPI.WebRemoteStatus.portInUse)
        #expect(BrowserOpening.step(web: taken, browsers: [], family: "Chrome")
            == .notServed("Not serving: port 8792 is in use by another app."))
        #expect(BrowserOpening.step(web: nil, browsers: ["Chrome on Mac"], family: "Chrome")
            == .notServed(BrowserOpening.offWords))
    }

    @Test func aPairedBrowserOfTheDefaultFamilyOpensThePage() {
        #expect(BrowserOpening.step(web: served, browsers: ["Safari on Mac", "Chrome on Mac"], family: "Chrome")
            == .open(URL(string: "http://localhost:8792")!))
    }

    @Test func anotherFamilyOrAnUnknownBrowserPairs() {
        #expect(BrowserOpening.step(web: served, browsers: ["Safari on Mac"], family: "Chrome") == .pair)
        #expect(BrowserOpening.step(web: served, browsers: ["Chrome on Mac"], family: nil) == .pair)
        #expect(BrowserOpening.step(web: served, browsers: [], family: "Safari") == .pair)
    }

    @Test func theCodeRidesInTheFragmentAndComesBackWhole() throws {
        let code = "agents-control:2:c:operator:AAAA:BBBB:http%3A%2F%2Flocalhost%3A8792:-:Alex%27s%20control%20plane"
        let url = try #require(BrowserOpening.pairingURL(served, code: code))
        #expect(url.absoluteString.hasPrefix("http://localhost:8792/#code="))
        // Nothing of the code in the path or the query, which a server or its log would see.
        #expect(url.query == nil)
        #expect(url.path == "/")
        let fragment = try #require(url.fragment(percentEncoded: true))
        #expect(!fragment.contains(":"))
        #expect(String(fragment.dropFirst("code=".count)).removingPercentEncoding == code)
    }

    @Test func familiesAreThePagesNames() {
        #expect(BrowserOpening.family(bundleID: "com.apple.Safari") == "Safari")
        #expect(BrowserOpening.family(bundleID: "com.google.Chrome.canary") == "Chrome")
        #expect(BrowserOpening.family(bundleID: "company.thebrowser.Browser") == nil)
        #expect(BrowserOpening.family(bundleID: nil) == nil)
    }
}
