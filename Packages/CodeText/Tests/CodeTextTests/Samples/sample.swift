import Foundation

/// A small shop's till, for the colour samples (041).
///
/// Comments, strings, numbers, types and functions all appear at least once.
struct Till {
    enum Error: Swift.Error { case empty, overdrawn(by: Decimal) }

    private(set) var float: Decimal = 150.00
    var receipts: [Receipt] = []
    let opened = Date()

    /* A block comment
       across two lines. */
    mutating func sell(_ item: String, for price: Decimal, count: Int = 1) throws -> Receipt {
        guard count > 0 else { throw Error.empty }
        let total = price * Decimal(count)
        float += total
        let receipt = Receipt(item: item, total: total, at: .now)
        receipts.append(receipt)
        print("Sold \(count) × \(item) for \(total)")
        return receipt
    }

    mutating func refund(_ receipt: Receipt) throws {
        guard float >= receipt.total else {
            throw Error.overdrawn(by: receipt.total - float)
        }
        float -= receipt.total
        receipts.removeAll { $0.id == receipt.id }
    }

    var takings: Decimal {
        receipts.reduce(0) { $0 + $1.total }
    }
}

struct Receipt: Identifiable, Hashable {
    let id = UUID()
    let item: String
    let total: Decimal
    let at: Date
}

@MainActor
final class TillModel: ObservableObject {
    @Published private(set) var till = Till()
    private let hexMask = 0xFF_FF
    private let ratio = 0.125

    func sellCoffee() {
        do {
            _ = try till.sell("coffee", for: 3.20)
        } catch {
            print("Could not sell: \(error)")
        }
    }

    nonisolated static let greeting = """
        Welcome.
        Mind the step.
        """
}

let emoji = "Café ☕️ — naïve 👩‍👩‍👧 test"
