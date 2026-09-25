import AgentsKitCore
import Foundation

/// `hosts.json`: the servers the window knows about (037).
///
/// Written by the window only. The Mac's daemon never reads it: a server is somewhere the
/// window talks to, not something the Mac's daemon manages.
public struct HostStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public init(locations: StoreLocations) { self.file = locations.hosts }

    /// No file, or one that cannot be read, is no servers. The window then shows the
    /// list it showed before servers existed, which is the safe thing to lose to.
    public func load() -> HostList {
        guard let data = try? Data(contentsOf: file) else { return HostList() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(HostList.self, from: data)) ?? HostList()
    }

    public func save(_ hosts: HostList) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(hosts).write(to: file, options: .atomic)
    }
}
