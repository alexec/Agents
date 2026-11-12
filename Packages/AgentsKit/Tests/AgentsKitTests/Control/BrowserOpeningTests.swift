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

    // MARK: Links of the Web + Mac link tier (#4937, #4938)

    @Test func aPlaceRidesAfterTheCodeAndComesBackWhole() throws {
        let url = try #require(BrowserOpening.pairingURL(served, code: "a:b", place: "/reports/spend?range=week"))
        #expect(url.query == nil)
        #expect(url.path == "/")
        let fragment = try #require(url.fragment(percentEncoded: true))
        #expect(fragment.hasPrefix("code=a%3Ab&to="))
        #expect(!fragment.dropFirst("code=a%3Ab&to=".count).contains("/"))
        #expect(String(fragment.dropFirst("code=a%3Ab&to=".count)).removingPercentEncoding == "/reports/spend?range=week")
    }

    @Test func aPairedBrowserOpensThePlace() {
        #expect(BrowserOpening.pageURL("http://localhost:8792", place: "/reports/spend?range=month")?.absoluteString
            == "http://localhost:8792/#/reports/spend?range=month")
        #expect(BrowserOpening.pageURL("https://control.example.dev/", place: "/reports/spend?range=day")?.absoluteString
            == "https://control.example.dev/#/reports/spend?range=day")
        #expect(BrowserOpening.pageURL("http://localhost:8792", place: nil)?.absoluteString == "http://localhost:8792")
    }

    @Test func theLinkShowsOnlyWhereThisMacCanOpenThePage() {
        var status = DaemonAPI.ControlStatus(name: "c", version: "0.19", homeHost: nil, machineID: "m1")
        #expect(BrowserOpening.linkPage(nil, onThisMac: true) == nil)
        #expect(BrowserOpening.linkPage(status, onThisMac: true) == nil)
        status.web = DaemonAPI.WebRemoteStatus(port: 8792, served: false, reason: DaemonAPI.WebRemoteStatus.portInUse)
        #expect(BrowserOpening.linkPage(status, onThisMac: true) == nil)
        status.web = served
        #expect(BrowserOpening.linkPage(status, onThisMac: true) == "http://localhost:8792")
        // Another Mac's loopback page is not this Mac's to open.
        #expect(BrowserOpening.linkPage(status, onThisMac: false) == nil)
        status.publicWeb = "https://control.example.dev"
        #expect(BrowserOpening.linkPage(status, onThisMac: false) == "https://control.example.dev")
        #expect(BrowserOpening.linkPage(status, onThisMac: true) == "http://localhost:8792")
    }

    @Test func reportsOpensSpendInTheCostPagesRange() {
        #expect(ReportsLink.place(range: .day) == "/reports/spend?range=day")
        #expect(ReportsLink.place(range: .week) == "/reports/spend?range=week")
        #expect(ReportsLink.place(range: .month) == "/reports/spend?range=month")
        #expect(ReportsLink.place(range: .threeMonths) == "/reports/spend?range=threeMonths")
    }
}
