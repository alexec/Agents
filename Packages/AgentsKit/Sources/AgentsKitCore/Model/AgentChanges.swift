import Foundation

/// Where git's view of an agent's changes is measured from (035).
///
/// A commit, not a branch: a branch moves as the agent commits, and "what changed since
/// the agent started" has to keep counting what it committed.
public struct StartingPoint: Codable, Hashable, Sendable {
    /// The repository's top folder when the agent started.
    public var repository: URL
    /// The full SHA its `HEAD` was on at that moment.
    public var commit: String

    public init(repository: URL, commit: String) {
        self.repository = repository
        self.commit = commit
    }
}

/// One edit a runtime reported over ACP: the passage that went and the one that came.
public struct ReportedEdit: Codable, Hashable, Sendable, Identifiable {
    /// Resolved absolute path.
    public var path: String
    /// Absent for a new file.
    public var oldText: String?
    public var newText: String
    /// The tool call it came from, and how the conversation finds it again.
    public var toolCallID: String
    /// Its place among that call's diffs; a call may carry several.
    public var index: Int
    /// Where in the transcript the copy that counts was written.
    public var entryIndex: Int
    /// The tool was told to replace every occurrence, not the first.
    public var replaceAll: Bool
    public var at: Date

    public var id: String { "\(toolCallID)#\(index)" }

    public init(path: String, oldText: String?, newText: String, toolCallID: String,
                index: Int, entryIndex: Int, replaceAll: Bool = false, at: Date) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.toolCallID = toolCallID
        self.index = index
        self.entryIndex = entryIndex
        self.replaceAll = replaceAll
        self.at = at
    }

    /// As the conversation draws it.
    public var diff: ToolCallContent.Diff {
        ToolCallContent.Diff(path: path, oldText: oldText, newText: newText)
    }

    /// DiffView's rule: every old line went, every new line came.
    public var removedLines: Int { oldText.map(Self.lineCount) ?? 0 }
    public var addedLines: Int { Self.lineCount(newText) }

    static func lineCount(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        var count = 0
        for byte in text.utf8 where byte == UInt8(ascii: "\n") { count += 1 }
        return text.utf8.last == UInt8(ascii: "\n") ? count : count + 1
    }
}

/// Who knows a file changed.
public enum ChangeSource: String, Codable, Hashable, Sendable {
    /// The runtime reported it, and git has nothing to add or there is no git.
    case reported
    /// Reported, and git sees it changed too.
    case reportedAndSeen
    /// Only git sees it.
    case seen
}

public enum ChangeState: String, Codable, Hashable, Sendable {
    case modified, added, deleted, binary
}

/// A file the Changes pane lists.
public struct ChangedFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    /// Relative to the agent's folder or repository, for display. Nil outside both.
    public var relativePath: String?
    public var source: ChangeSource
    public var state: ChangeState
    /// Reported edits; 0 for `seen`.
    public var editCount: Int
    /// Lines. Nil for binary.
    public var added: Int?
    public var removed: Int?
    /// The file on disk is not what its reported edits make it (035 R5).
    public var beyondReported: Bool
    /// A call touching it has not finished.
    public var inProgress: Bool
    /// Never given to git.
    public var outsideFolder: Bool
    /// First changed line in the current file, for "Open in Files".
    public var firstLine: Int?

    public var id: String { path }
    public var fileName: String { URL(filePath: path).lastPathComponent }

    public init(path: String, relativePath: String? = nil, source: ChangeSource,
                state: ChangeState, editCount: Int = 0, added: Int? = nil, removed: Int? = nil,
                beyondReported: Bool = false, inProgress: Bool = false,
                outsideFolder: Bool = false, firstLine: Int? = nil) {
        self.path = path
        self.relativePath = relativePath
        self.source = source
        self.state = state
        self.editCount = editCount
        self.added = added
        self.removed = removed
        self.beyondReported = beyondReported
        self.inProgress = inProgress
        self.outsideFolder = outsideFolder
        self.firstLine = firstLine
    }
}

/// Why git has nothing to say about an agent's folder.
public enum ChangesUnavailable: Codable, Hashable, Sendable {
    case notARepository
    case gitNotInstalled
    case folderGone
    /// git's own message.
    case failed(String)
}

/// What git's half of the list is, and how far it can be believed to be this agent's.
public enum GitView: Codable, Hashable, Sendable {
    /// The agent's own worktree, measured from where it started.
    case owned(since: String)
    /// A folder others work in too, measured from where it started.
    case shared(since: String)
    /// No starting point was recorded: uncommitted changes against `HEAD`.
    case sharedFromHead
    case unavailable(ChangesUnavailable)
}

public struct DiffLine: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case context, added, removed }
    public var kind: Kind
    public var text: String
    /// The line number in the current file, for context and added lines.
    public var newLine: Int?

    public init(kind: Kind, text: String, newLine: Int? = nil) {
        self.kind = kind
        self.text = text
        self.newLine = newLine
    }
}

public struct FolderHunk: Codable, Hashable, Sendable {
    public var oldStart: Int
    public var newStart: Int
    public var noNewlineAtEnd: Bool
    public var lines: [DiffLine]

    public init(oldStart: Int, newStart: Int, noNewlineAtEnd: Bool = false, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.noNewlineAtEnd = noNewlineAtEnd
        self.lines = lines
    }
}

/// `changes/list`.
public struct ChangesList: Codable, Hashable, Sendable {
    public var files: [ChangedFile]
    public var git: GitView
    /// Whether this runtime has reported any diff in this agent.
    public var reportsEdits: Bool

    public init(files: [ChangedFile], git: GitView, reportsEdits: Bool) {
        self.files = files
        self.git = git
        self.reportsEdits = reportsEdits
    }
}

/// `changes/file`.
public struct ChangedFileDetail: Codable, Hashable, Sendable {
    public var file: ChangedFile
    public var edits: [ReportedEdit]
    /// Nil without git, or for binary.
    public var hunks: [FolderHunk]?
    /// Only when asked for, and only with git.
    public var whole: [DiffLine]?

    public init(file: ChangedFile, edits: [ReportedEdit], hunks: [FolderHunk]? = nil,
                whole: [DiffLine]? = nil) {
        self.file = file
        self.edits = edits
        self.hunks = hunks
        self.whole = whole
    }
}
