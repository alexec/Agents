import Foundation

/// Every edit an agent's runtime reported, folded from its transcript (035).
///
/// Not every diff in the transcript is an edit. A Claude tool call sends its diff two or
/// three times as it goes: once built from the tool's input — a Write over an existing
/// file has no old text yet, and reads as a new file — and again after it ran, with the
/// real old text. And a call that failed, or was refused, still carried the diff it would
/// have made. So a call's edits are the diffs of the last entry for it that carried any,
/// and they count once it has `completed` and not before (research R1).
public struct ReportedChanges: Sendable, Equatable {
    private struct Call: Sendable, Equatable {
        var order: Int
        var toolCallID: String
        var diffs: [ToolCallContent.Diff] = []
        var status: String?
        var entryIndex = 0
        var at = Date.distantPast
        var replaceAll = false
    }

    private var calls: [String: Call] = [:]
    private var nextOrder = 0

    /// Whether this runtime has reported any diff at all, finished or not.
    public private(set) var reportsEdits = false

    public init() {}

    public init(entries: some Sequence<TranscriptEntry>, startIndex: Int = 0) {
        for (offset, entry) in entries.enumerated() { absorb(entry, at: startIndex + offset) }
    }

    public mutating func absorb(_ entry: TranscriptEntry, at index: Int) {
        let call: ToolCall
        switch entry.kind {
        case .toolCall(let c), .toolCallUpdate(let c): call = c
        default: return
        }
        let key = call.toolCallID ?? entry.id.uuidString
        var record = calls[key] ?? Call(order: -1, toolCallID: key)
        if let status = call.status { record.status = status }
        if call.rawInput?["replace_all"]?.boolValue == true { record.replaceAll = true }
        let diffs = call.content.compactMap { content -> ToolCallContent.Diff? in
            // Resolved once, here, rather than every time the list is read.
            if case .diff(var diff) = content { diff.path = Self.key(diff.path); return diff }
            return nil
        }
        if !diffs.isEmpty {
            reportsEdits = true
            if record.order < 0 {
                record.order = nextOrder
                nextOrder += 1
            }
            record.diffs = diffs
            record.entryIndex = index
            record.at = entry.at
        }
        calls[key] = record
    }

    private var ordered: [Call] {
        calls.values.filter { $0.order >= 0 }.sorted { $0.order < $1.order }
    }

    /// The edits of every call that completed, in the order each call first carried one.
    public var edits: [ReportedEdit] {
        ordered.filter { $0.status == "completed" }.flatMap { call in
            call.diffs.enumerated().map { index, diff in
                ReportedEdit(path: diff.path, oldText: diff.oldText,
                             newText: diff.newText, toolCallID: call.toolCallID, index: index,
                             entryIndex: call.entryIndex, replaceAll: call.replaceAll,
                             at: call.at)
            }
        }
    }

    /// Paths a call is still working on: it carried a diff and has not ended.
    public var inProgress: Set<String> {
        Set(ordered.filter { $0.status != "completed" && $0.status != "failed" }
            .flatMap { $0.diffs.map(\.path) })
    }

    /// Edits grouped by file, files in the order of their first edit.
    public var byFile: [(path: String, edits: [ReportedEdit])] {
        var order: [String] = []
        var grouped: [String: [ReportedEdit]] = [:]
        for edit in edits {
            if grouped[edit.path] == nil { order.append(edit.path) }
            grouped[edit.path, default: []].append(edit)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// Resolved the way `TouchedPaths` resolves them, so `/tmp/x` and `/private/tmp/x`
    /// are one file.
    public static func key(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
