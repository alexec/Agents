import Testing
@testable import AgentsKitCore

/// The Console's admin pages the Mac links to (#4939, tier Web + Mac link, #4937).
struct ConsoleLinksTests {
    private let served = DaemonAPI.WebRemoteStatus(port: 8792, served: true)

    @Test func eachLinkOpensItsOwnPage() {
        #expect(ConsoleLinks.links.map(\.place) == [
            "/settings/reportPolicy", "/settings/catalogue", "/settings/readApi", "/requests/requests",
        ])
        #expect(Set(ConsoleLinks.links.map(\.id)).count == ConsoleLinks.links.count)
        #expect(ConsoleLinks.links.allSatisfy { $0.title.hasSuffix(" in Console") })
    }

    @Test func onlyAnAdminWithAPageGetsThem() {
        var status = DaemonAPI.ControlStatus(name: "c", version: "0.19", homeHost: nil, machineID: "m1")
        #expect(ConsoleLinks.shown(admin: true, status: nil, onThisMac: true).isEmpty)
        // No web page: no link and no feature.
        #expect(ConsoleLinks.shown(admin: true, status: status, onThisMac: true).isEmpty)
        status.web = served
        #expect(ConsoleLinks.shown(admin: true, status: status, onThisMac: true) == ConsoleLinks.links)
        #expect(ConsoleLinks.shown(admin: false, status: status, onThisMac: true).isEmpty)
        // Another Mac's own page is not this Mac's to open; the control plane's domain is.
        #expect(ConsoleLinks.shown(admin: true, status: status, onThisMac: false).isEmpty)
        status.publicWeb = "https://control.example.dev"
        #expect(ConsoleLinks.shown(admin: true, status: status, onThisMac: false) == ConsoleLinks.links)
    }

    @Test func aPairingLinkCarriesThePlace() throws {
        let link = try #require(ConsoleLinks.links.first)
        let url = try #require(BrowserOpening.pairingURL(served, code: "c0de", place: link.place))
        #expect(url.absoluteString == "http://localhost:8792/#code=c0de&to=%2Fsettings%2FreportPolicy")
        #expect(BrowserOpening.pageURL(served.address, place: link.place)?.absoluteString
            == "http://localhost:8792/#/settings/reportPolicy")
    }
}
