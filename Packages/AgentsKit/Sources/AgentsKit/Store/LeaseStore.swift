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
        return StoreFile.load(LeaseBook.self, at: locations.leases, empty: LeaseBook(), meaning: "starting with no leases")
    }

    public func save(_ book: LeaseBook) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let data = try StoreCoding.encoder.encode(book)
        try StoreFile.write(data, to: locations.leases)
    }
}

/// The resources the person declared (#116), kept on the same pattern: one small file,
/// read and written whole. One that cannot be read is set aside, and nothing is
/// declared until the person declares it again.
public struct DeclaredResourceStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> [DeclaredResource] {
        return StoreFile.load([DeclaredResource].self, at: locations.declaredResources, empty: [], meaning: "nothing declared")
    }

    public func save(_ list: [DeclaredResource]) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let data = try StoreCoding.encoder.encode(list)
        try StoreFile.write(data, to: locations.declaredResources)
    }
}
