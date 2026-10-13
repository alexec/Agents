import Foundation

/// What the page of transcript in hand says about files: every edit to each path, and
/// everything exchanged (#929).
///
/// Folded once as each entry lands, as `TranscriptDisplayBuilder` is, rather than
/// derived by a view on every redraw. The page changes several times a second while
/// an agent streams, and a view that walked every entry's tool calls and standardised
/// a URL per diff did the page's whole length of work again for every chunk.
struct TranscriptFileIndex {
    /// Each path's edits, oldest first, by its standardised path.
    private(set) var changes: [String: [ToolCallContent.Diff]] = [:]
    /// Everything exchanged, newest first, in the order `Artifact.all(in:)` gives.
    private(set) var artifacts: [Artifact] = []

    init() {}

    init(entries: some Sequence<TranscriptEntry>) {
        for entry in entries { add(entry) }
    }

    /// One entry, at the end of the page. Says which of the two it changed, so the
    /// model hands on only those, and a chunk of a reply redraws neither.
    @discardableResult
    mutating func add(_ entry: TranscriptEntry) -> (changes: Bool, artifacts: Bool) {
        var changed = (changes: false, artifacts: false)
        switch entry.kind {
        case .toolCall(let call), .toolCallUpdate(let call):
            for piece in call.content {
                guard case .diff(let diff) = piece else { continue }
                changes[Self.key(diff.path), default: []].append(diff)
                changed.changes = true
            }
        default:
            break
        }
        for artifact in Artifact.all(in: CollectionOfOne(entry)) {
            // After every one as new or newer, so ties keep the order they arrived in.
            let at = artifacts.firstIndex { $0.arrivedAt < artifact.arrivedAt } ?? artifacts.endIndex
            artifacts.insert(artifact, at: at)
            changed.artifacts = true
        }
        return changed
    }

    static func key(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.path
    }
}
