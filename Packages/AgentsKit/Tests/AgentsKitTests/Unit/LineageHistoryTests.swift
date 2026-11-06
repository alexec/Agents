import Foundation
import Testing
@testable import AgentsKitCore

/// Work's and Docs' Back and Forward (#3119, #3321).
@Suite("Lineage history")
struct LineageHistoryTests {
    @Test func thePlacesGoBackAndForwardAsABrowsers() {
        var h = LineageHistory<String>()
        #expect(h.current == nil)
        h.go("a"); h.go("b"); h.go("b")
        #expect(h.places == ["a", "b"] && h.at == 1)
        h.back()
        #expect(h.current == "a" && !h.canGoBack)
        h.go("c")
        #expect(h.places == ["a", "c"] && !h.canGoForward)
        for i in 0..<60 { h.go("n\(i)") }
        #expect(h.places.count == LineageHistory<String>.most)
        #expect(h.current == "n59")
    }
}
