@testable import AgentsKitCore
import Foundation
import Testing

/// The line the Remote shows where a Mac + web feature was (#2798).
struct MacOrWebTests {
    @Test func theLinkOpensThePageOnTheControlPlanesDomain() throws {
        let json = #"{"name":"Team","version":"1","machineID":"m","publicWeb":"https://control.example.com/"}"#
        let status = try JSONDecoder().decode(DaemonAPI.ControlStatus.self, from: Data(json.utf8))
        #expect(MacOrWebWords.url(status, page: "settings")?.absoluteString == "https://control.example.com/#/settings")
        #expect(MacOrWebWords.url(status, page: "console/audit")?.absoluteString
            == "https://control.example.com/#/console/audit")
    }

    @Test func noWebPageMeansNoLink() throws {
        let json = #"{"name":"Team","version":"1","machineID":"m"}"#
        let status = try JSONDecoder().decode(DaemonAPI.ControlStatus.self, from: Data(json.utf8))
        #expect(MacOrWebWords.url(status, page: "settings") == nil)
        #expect(MacOrWebWords.url(nil, page: "settings") == nil)
    }
}
