import Foundation

/// What a window asks of a host instead of doing it itself, once it is sandboxed (058,
/// research R12): Finder, other apps and Terminal on a Mac host, and text files anywhere
/// its person may browse. Operator only, as `files/browse` is.
public extension DaemonAPI.Method {
    static let macReveal = "mac/reveal"
    static let macOpen = "mac/open"
    static let macTerminal = "mac/terminal"
    static let filesReadText = "files/readText"
    static let filesSaveText = "files/saveText"
}

public extension DaemonAPI {
    /// `mac/reveal`, `mac/open`: a path on the host; `app` names the app to open it with.
    struct MacPathRequest: Codable, Sendable, Hashable {
        public var path: String
        public var app: String?
        public init(path: String, app: String? = nil) {
            self.path = path
            self.app = app
        }
    }

    /// `mac/terminal`: Terminal, in `path` if given.
    struct MacTerminalRequest: Codable, Sendable, Hashable {
        public var path: String?
        public init(path: String? = nil) { self.path = path }
    }

    /// `files/readText`: a text file by its full path.
    struct FilesTextRequest: Codable, Sendable, Hashable {
        public var path: String
        public init(path: String) { self.path = path }
    }

    /// Its answer: nil text when there is no such file.
    struct FilesText: Codable, Sendable, Hashable {
        public var text: String?
        public init(text: String?) { self.text = text }
    }

    /// `files/saveText`: writes a text file, making its folder; with `onlyIfAbsent`, a file
    /// already there is left alone.
    struct FilesSaveTextRequest: Codable, Sendable, Hashable {
        public var path: String
        public var text: String
        public var onlyIfAbsent: Bool?
        public init(path: String, text: String, onlyIfAbsent: Bool? = nil) {
            self.path = path
            self.text = text
            self.onlyIfAbsent = onlyIfAbsent
        }
    }

    /// The most `files/readText` and `files/saveText` carry.
    static let textFileLimit = 1024 * 1024
}
