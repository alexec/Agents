import Foundation

/// Which files the agent touched since it started.
///
/// This comes from the agent's own transcript, not from the disk. Every tool call
/// carries `locations`, and every edit carries a `diff` with a path, so the record of
/// what the agent did is already written down. Reading it back needs no baseline
/// snapshot and no crawl.
///
/// It is also the truthful answer to FR-013. A file the user changed in their own
/// editor is not marked, because the agent did not change it, and the mark claims the
/// agent did.
public struct TouchedPaths: Sendable, Equatable {
    private var paths: Set<String> = []

    public init() {}

    public init(entries: some Sequence<TranscriptEntry>) {
        for entry in entries { absorb(entry) }
    }

    public var isEmpty: Bool { paths.isEmpty }
    public var count: Int { paths.count }

    /// Paths are compared as resolved file-system paths, so `/tmp/x` and
    /// `/private/tmp/x` are the same file and a trailing slash changes nothing.
    public func contains(_ url: URL) -> Bool {
        paths.contains(Self.key(url))
    }

    public mutating func absorb(_ entry: TranscriptEntry) {
        switch entry.kind {
        case .toolCall(let call), .toolCallUpdate(let call):
            for location in call.locations {
                paths.insert(Self.key(URL(filePath: location.path)))
            }
            for content in call.content {
                if case .diff(let diff) = content {
                    paths.insert(Self.key(URL(filePath: diff.path)))
                }
            }
        default:
            break
        }
    }

    static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
