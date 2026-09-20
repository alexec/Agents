import Foundation
import Testing
@testable import AgentsKitCore

/// A cost is shown to the nearest whole unit. Compared with the formatter's own output
/// for the whole number rather than with a literal, so the test does not care which
/// locale it runs in — only that the rounding happened.
@Suite("Money for the eye")
struct MoneyTests {
    private func usd(_ text: String) -> String { Decimal(string: text)!.money(in: "USD") }

    @Test func aCostIsShownToTheNearestWholeUnit() {
        #expect(usd("2.84") == usd("3"))
        #expect(usd("2.49") == usd("2"))
        #expect(usd("2.50") == usd("3"))
        #expect(usd("0.28") == usd("0"))
        #expect(usd("3") != usd("4"))
        #expect(!usd("2.84").contains("."))
    }

    @Test func aRunningTotalUsesTheSameFigure() {
        #expect(Cost.total(of: ["USD": Decimal(string: "2.84")!]) == usd("3"))
    }
}
