import Foundation

/// One entry in the files pane.
///
/// Here rather than beside `DirectoryReader` so a phone can hold one: `files/list`
/// answers with these (034). The reader, which touches the disk, stays on the Mac.
public struct DirectoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    /// Nil for a directory. A directory's size is the sum of a tree, and this pane
    /// never walks one.
    public var size: Int?
    public var modifiedAt: Date?
    /// Whether the agent touched this path since it started (FR-013). Set by the pane
    /// from the transcript, not read off the disk.
    public var touchedByAgent: Bool = false

    public var id: URL { url }

    /// `touchedByAgent` is not sent. Each client marks from its own transcript, so the
    /// mark means the same thing on every screen (034 research §5).
    private enum CodingKeys: String, CodingKey {
        case url, name, isDirectory, size, modifiedAt
    }

    public init(url: URL, name: String, isDirectory: Bool,
                size: Int? = nil, modifiedAt: Date? = nil, touchedByAgent: Bool = false) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.touchedByAgent = touchedByAgent
    }
}

/// What one directory holds, and whether that is all of it.
public struct DirectoryListing: Codable, Sendable, Equatable {
    public var url: URL
    public var entries: [DirectoryEntry]
    /// How many were left out by the cap. Zero when the listing is the whole directory.
    public var omitted: Int

    public var isTruncated: Bool { omitted > 0 }

    public init(url: URL, entries: [DirectoryEntry], omitted: Int = 0) {
        self.url = url
        self.entries = entries
        self.omitted = omitted
    }
}

