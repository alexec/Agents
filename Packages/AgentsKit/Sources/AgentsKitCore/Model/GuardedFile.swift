import Foundation

/// A file in a project's `.agents` that only the app is meant to write (#502).
///
/// An agent can edit one by a shell command as easily as by an edit tool, and both of
/// these took effect at once: helper limits and disk lines from `project.json`, pins
/// from `pins.json`. So each is held as workflows are: the app keeps the last approved
/// copy outside the project, a file that differs from it is not used, and the person
/// keeps the change or undoes it. The app's own writes are approved as they are made.
public enum GuardedFile: String, Codable, CaseIterable, Sendable {
    case projectConfig = ".agents/project.json"
    case pins = ".agents/pins.json"

    /// Relative to the project folder.
    public var path: String { rawValue }

    public func url(in project: URL) -> URL { project.appending(path: path) }

    /// What the file holds, in a person's words.
    public var holds: String {
        switch self {
        case .projectConfig: "the helper limits and disk space lines"
        case .pins: "the pins"
        }
    }
}

/// A change to a guarded file made outside the app, waiting for the person (#502).
public struct GuardedChange: Codable, Hashable, Sendable, Identifiable {
    /// The file, relative to the project folder.
    public var path: String
    /// SHA-256 of the file as it is now; nil when it was removed.
    public var digest: String?
    /// The agents whose turns were running in the project when the change was seen, by
    /// title. Empty when none was: then it came by git, or from somewhere the app cannot name.
    public var changedBy: [String]
    /// The same agents, by id, for a client that links to them.
    public var changedByIDs: [UUID]
    /// What was on disk is what the project's last commit holds: a merge, pull or branch
    /// switch brought it, which waits for an OK however it arrived.
    public var byGit: Bool
    /// When the change was first seen.
    public var since: Date

    public var id: String { path }

    public init(path: String, digest: String?, changedBy: [String], changedByIDs: [UUID],
                byGit: Bool, since: Date) {
        self.path = path
        self.digest = digest
        self.changedBy = changedBy
        self.changedByIDs = changedByIDs
        self.byGit = byGit
        self.since = since
    }

    /// Who changed what, as a sentence's start: "Lead changed .agents/project.json".
    public var headline: String {
        let what = digest == nil ? "removed \(path)" : "changed \(path)"
        if !changedBy.isEmpty { return "\(GuardedChange.names(changedBy)) \(what)" }
        if byGit { return "A merge or pull " + what }
        return "Something outside the app " + what
    }

    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

/// What a guarded file was and is, for the person deciding (#502).
public struct GuardedChangeReading: Codable, Hashable, Sendable {
    public var path: String
    /// The change as read: Keep and Undo send this back.
    public var digest: String?
    /// The copy the app is using; nil when the approved state is no file.
    public var approved: String?
    /// The file on disk; nil when it is not there.
    public var current: String?
    /// The two, line by line.
    public var lines: [GuardedDiffLine]

    public init(path: String, digest: String?, approved: String?, current: String?) {
        self.path = path
        self.digest = digest
        self.approved = approved
        self.current = current
        lines = GuardedDiffLine.lines(from: approved ?? "", to: current ?? "")
    }
}

/// One line of a guarded file's change.
public struct GuardedDiffLine: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case same, removed, added }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// At most this many lines are sent: these files are a few dozen lines, and one an
    /// agent filled is not drawn whole.
    public static let limit = 400

    /// Every line of `old` and `new` in order, each marked as kept, removed or added.
    public static func lines(from old: String, to new: String) -> [GuardedDiffLine] {
        func split(_ text: String) -> [String] {
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return lines
        }
        let before = split(old), after = split(new)
        let difference = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [GuardedDiffLine] = []
        var i = 0, j = 0
        while (i < before.count || j < after.count) && out.count < limit {
            if i < before.count, removed.contains(i) {
                out.append(GuardedDiffLine(kind: .removed, text: before[i]))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                out.append(GuardedDiffLine(kind: .added, text: after[j]))
                j += 1
            } else if i < before.count {
                out.append(GuardedDiffLine(kind: .same, text: before[i]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return out
    }
}
