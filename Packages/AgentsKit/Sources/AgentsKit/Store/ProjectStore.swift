import Foundation

/// Where the two facts about a project that cannot be derived are kept.
///
/// One file, read whole and written whole. The list is tens of entries for one person,
/// it changes when somebody archives something, and one file that `cat` will show you
/// matches how agents are stored.
///
/// A missing or unreadable file is an empty list rather than an error. Losing this file
/// loses archived state and nothing else: every live project is still derived from its
/// agents, which is the right thing to lose.
public struct ProjectStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> [Project] {
        guard let data = try? Data(contentsOf: locations.projects) else { return [] }
        guard let projects = try? StoreCoding.decoder.decode([Project].self, from: data) else {
            return []
        }
        // One folder is one project. A file that somehow holds two records for one
        // folder keeps the first and drops the rest rather than showing both.
        var seen: Set<URL> = []
        return projects.filter { seen.insert($0.folder).inserted }
    }

    public func save(_ projects: [Project]) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let ordered = projects.sorted { $0.folder.path < $1.folder.path }
        let data = try StoreCoding.encoder.encode(ordered)
        try data.write(to: locations.projects, options: .atomic)
    }
}
