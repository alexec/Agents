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

    /// No file is no servers. One that cannot be read is set aside beside itself
    /// (`hosts.json.unreadable-<time>`) rather than read as none and then written over
    /// by the next save: the servers in it are the person's, and a build that can read
    /// it may still want them.
    public func load() -> HostList {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return StoreFile.load(HostList.self, at: file, empty: HostList(), decoder: decoder,
                              meaning: "starting with no servers")
    }

    public func save(_ hosts: HostList) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StoreFile.write(encoder.encode(hosts), to: file)
    }
}
