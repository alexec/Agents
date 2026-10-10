import Foundation

/// A project's own settings, kept in the project as `.agents/project.json` (#126), so
/// they travel with it to every clone and host and show in its history.
///
///     {
///       "diskSpace" : {
///         "lowGB" : 50
///       },
///       "helperLimits" : {
///         "notArchived" : 8,
///         "running" : 4
///       }
///     }
///
/// Only what differs from the defaults is written, and a project with nothing to say has
/// no file. Keys this version does not know are kept as they are, so a later version's
/// setting survives this one writing the file.
///
/// Whatever the file says is clamped to the hard maximums where it is enforced
/// (`HelperLimits.effective`), so editing the file by hand cannot raise a ceiling past
/// them. The app's tools give agents no way to write it, and a change made outside the
/// app waits for the person's Keep or Undo before it is used (#502).
public enum ProjectConfig {
    public static let fileName = "project.json"

    /// The file is there but is not a JSON object, so nothing was written over it.
    public struct Unreadable: Error, Sendable {
        public var message: String { "\(DotAgents.folder)/\(fileName) is not a JSON object, so it was left as it is. Fix it or remove it, then try again." }
    }
    static let helperLimitsKey = "helperLimits"
    static let diskSpaceKey = "diskSpace"

    public static func url(in project: URL) -> URL {
        project.appendingPathComponent(DotAgents.folder, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The file's keys, or none when it is not there or is not a JSON object.
    static func read(in project: URL) -> [String: JSONValue] {
        keys(from: try? Data(contentsOf: url(in: project)))
    }

    /// The keys of the file's bytes, or none: the daemon reads the copy the person last
    /// approved (#502), which may not be what is on disk.
    static func keys(from data: Data?) -> [String: JSONValue] {
        guard let data, case .object(let keys)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return keys
    }

    /// The helper limits the file sets, or nil when it sets none. A value that is not a
    /// whole number is no setting, and so the default.
    public static func helperLimits(in project: URL) -> HelperLimits? {
        helperLimits(from: try? Data(contentsOf: url(in: project)))
    }

    public static func helperLimits(from data: Data?) -> HelperLimits? {
        guard let limits = try? keys(from: data)[helperLimitsKey]?.decode(HelperLimits.self) else { return nil }
        return limits.orNilIfDefault
    }

    /// Write the helper limits, or take them out when `limits` is nil, leaving every
    /// other key as it was. No write when the bytes would be the same, and no file when
    /// nothing is left in it. Returns whether the file changed.
    @discardableResult
    public static func setHelperLimits(_ limits: HelperLimits?, in project: URL) throws -> Bool {
        try set(helperLimitsKey, to: limits?.orNilIfDefault, in: project)
    }

    /// The disk space lines the file sets (#195), or nil when it sets none.
    public static func diskSpace(in project: URL) -> DiskThresholds? {
        diskSpace(from: try? Data(contentsOf: url(in: project)))
    }

    public static func diskSpace(from data: Data?) -> DiskThresholds? {
        guard let lines = try? keys(from: data)[diskSpaceKey]?.decode(DiskThresholds.self) else { return nil }
        return lines.orNilIfDefault
    }

    /// Write the disk space lines, or take them out when nil, as `setHelperLimits` does.
    @discardableResult
    public static func setDiskSpace(_ lines: DiskThresholds?, in project: URL) throws -> Bool {
        try set(diskSpaceKey, to: lines?.orNilIfDefault, in: project)
    }

    /// One key written, or taken out when `value` is nil, leaving every other key as it was.
    private static func set(_ key: String, to value: (some Encodable)?, in project: URL) throws -> Bool {
        // A file somebody broke by hand is theirs to fix, not ours to replace.
        if let data = try? Data(contentsOf: url(in: project)),
           case .object? = try? JSONDecoder().decode(JSONValue.self, from: data) {} else if
           FileManager.default.fileExists(atPath: url(in: project).path) {
            throw Unreadable()
        }
        var keys = read(in: project)
        if let value {
            keys[key] = try JSONValue.encoding(value)
        } else {
            keys[key] = nil
        }
        let file = url(in: project)
        let old = try? Data(contentsOf: file)
        guard !keys.isEmpty else {
            guard old != nil else { return false }
            try FileManager.default.removeItem(at: file)
            return true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(keys))
        data.append(0x0A)
        if old == data { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return true
    }
}
