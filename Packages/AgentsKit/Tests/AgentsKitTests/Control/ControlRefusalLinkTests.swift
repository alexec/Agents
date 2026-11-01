import Foundation
import Testing
@testable import AgentsKitCore

/// The account address in a refusal's words, offered as a link (#3153).
@Suite("A refusal's link")
struct ControlRefusalLinkTests {
    @Test func theAccountPageInASuspension() {
        let line = "This hosted account is suspended. See https://example.com/account."
        #expect(ControlRefusal.link(in: line) == URL(string: "https://example.com/account"))
    }

    @Test func noAddressNoLink() {
        #expect(ControlRefusal.link(in: "This account is over its plan's limit.") == nil)
    }

    @Test func onlyHTTPS() {
        #expect(ControlRefusal.link(in: "See http://example.com/account or ftp://example.com.") == nil)
    }
}
