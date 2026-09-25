import Foundation
import AgentsKitCore

/// The lease book, kept where a restarted daemon finds it (036 FR-008).
///
/// One file, read whole and written whole after every change, on `LimitStore`'s
/// pattern. The book is tens of entries at most, so a whole write is cheaper than
/// anything cleverer would be to get right.
///
/// A file that cannot be read is set aside and the book starts empty. Losing the
/// leases is the lesser failure: they are an agreement between agents, and an empty
/// book frees everything, where a daemon refusing to start would hold everything.
public struct LeaseStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> LeaseBook {
        guard let data = try? Data(contentsOf: locations.leases) else { return LeaseBook() }
        guard let book = try? StoreCoding.decoder.decode(LeaseBook.self, from: data) else {
            StoreCoding.setAside(locations.leases)
            DaemonLog.shared.write("leases.json could not be read; set aside, starting with no leases")
            return LeaseBook()
        }
        return book
    }

    public func save(_ book: LeaseBook) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let data = try StoreCoding.encoder.encode(book)
        try data.write(to: locations.leases, options: .atomic)
    }
}
