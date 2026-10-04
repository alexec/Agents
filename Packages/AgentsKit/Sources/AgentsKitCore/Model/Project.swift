import Foundation
import Synchronization

/// A directory the user works in.
///
/// A project is its folder, which is why the folder is the identity and there is no id
/// of our own to keep in step. Almost everything about a project is derived from the
/// agents in it — the name, the activity, the counts — so the only things kept here are
/// the ones that cannot be: that it is archived, that somebody added the folder before
/// anything had run in it, and that it has been given the dotagents layout.
public struct Project: Codable, Hashable, Sendable, Identifiable {
    /// Resolved and standardised, so one folder is one project however it was typed.
    public var folder: URL
    /// When the user archived it. `nil` means live: nothing archives itself.
    public var archivedAt: Date?
    /// When this record was made. Orders a project that has no agents to order it by.
    public var addedAt: Date
    /// When it was given the dotagents layout. Once: after that the files are the
    /// person's, and one they deleted is not put back.
    public var laidOutAt: Date?
    /// Which layout it was given (`DotAgents.version`). Nil with `laidOutAt` set is the
    /// first, from before the layout had a version (09-25). Kept past the #58 cut-off on
    /// purpose: reading it as anything else would either lay out step 1 again, putting
    /// back what the person deleted, or fail `projects.json`, which holds every project.
    public var layoutVersion: Int?
    /// The person's own helper limits (#64). Nil is the defaults. In a summary, what the
    /// project's own `.agents/project.json` says (#126); in `projects.json`, only a record
    /// from before then, moved into that file once. Set only by
    /// `projects/setHelperLimits`, which agents cannot call.
    public var helperLimits: HelperLimits?
    /// The person's disk space lines (#195), from the project's own
    /// `.agents/project.json`. Nil is the defaults. Only ever in a summary; never kept in
    /// `projects.json`. Set only by `projects/setDiskSpace`, which agents cannot call.
    public var diskSpace: DiskThresholds?

    /// Keys a newer version wrote that this one does not know. Kept so that opening a
    /// record in an older build and saving it does not quietly delete them.
    public var unknownFields: [String: JSONValue]

    public var id: URL { folder }
    public var isArchived: Bool { archivedAt != nil }

    /// The folder, in the one form everything compares against.
    ///
    /// Resolved for symlinks and standardised, because `~/work/api`, `~/work/api/` and a
    /// symlink to it are one directory and must be one project. This is the only place
    /// that decides it, and everything that looks a project up goes through it.
    ///
    /// Rebuilt from the plain path at the end rather than returned as it came: a URL
    /// made from a string with a trailing slash keeps it, and `file:///work/api/` and
    /// `file:///work/api` are not equal however standardised they are.
    public static func standardize(_ folder: URL) -> URL {
        let key = folder.absoluteString
        if let known = standardized.withLock({ $0[key] }) { return known }
        let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
        // `path` is the one accessor that drops the trailing slash for a directory.
        let path = resolved.path
        let answer = path.isEmpty ? resolved : URL(filePath: path, directoryHint: .notDirectory)
        standardized.withLock { known in
            // Bounded, and simply emptied when it fills: this is a memo, not a record.
            if known.count >= 4096 { known.removeAll(keepingCapacity: true) }
            known[key] = answer
        }
        return answer
    }

    /// Every folder this process has standardised, by how it was written.
    ///
    /// Resolving symlinks asks the file system about every component of the path,
    /// and this is asked for every agent by every project row on every redraw, and
    /// by the daemon for every agent each time any agent changes. A folder resolves
    /// the same way for as long as the process runs — a symlink re-pointed under a
    /// running app is not a case this app serves — so the answer is kept.
    private static let standardized = Mutex<[String: URL]>([:])

    public init(folder: URL, archivedAt: Date? = nil, addedAt: Date = Date(),
                laidOutAt: Date? = nil, layoutVersion: Int? = nil, helperLimits: HelperLimits? = nil,
                diskSpace: DiskThresholds? = nil, unknownFields: [String: JSONValue] = [:]) {
        self.folder = Self.standardize(folder)
        self.archivedAt = archivedAt
        self.addedAt = addedAt
        self.laidOutAt = laidOutAt
        self.layoutVersion = layoutVersion
        self.helperLimits = helperLimits
        self.diskSpace = diskSpace
        self.unknownFields = unknownFields
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = Self.standardize(try c.decode(URL.self, forKey: .folder))
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        laidOutAt = try c.decodeIfPresent(Date.self, forKey: .laidOutAt)
        layoutVersion = try c.decodeIfPresent(Int.self, forKey: .layoutVersion)
        // A setting this build cannot read is the defaults, not a project that fails to load.
        helperLimits = (try? c.decodeIfPresent(HelperLimits.self, forKey: .helperLimits)) ?? nil
        diskSpace = (try? c.decodeIfPresent(DiskThresholds.self, forKey: .diskSpace)) ?? nil
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        unknownFields = [:]
        if let extra = try? decoder.container(keyedBy: AnyKey.self) {
            for key in extra.allKeys where !known.contains(key.stringValue) {
                unknownFields[key.stringValue] = (try? extra.decode(JSONValue.self, forKey: key)) ?? .null
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folder, forKey: .folder)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(laidOutAt, forKey: .laidOutAt)
        try c.encodeIfPresent(layoutVersion, forKey: .layoutVersion)
        try c.encodeIfPresent(helperLimits, forKey: .helperLimits)
        try c.encodeIfPresent(diskSpace, forKey: .diskSpace)
        if !unknownFields.isEmpty {
            var extra = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in unknownFields {
                try extra.encode(value, forKey: AnyKey(stringValue: key))
            }
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case folder, archivedAt, addedAt, laidOutAt, layoutVersion, helperLimits, diskSpace
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
