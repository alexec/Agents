import Foundation

/// Whether a file's reported edits account for what is on disk (035 research R5).
///
/// A runtime reports passages, not files, so the only way to know whether anything else
/// has touched a file — a formatter, another agent, the person's editor — is to play the
/// agent's edits over the file as it was when the agent started and compare. It does not
/// matter which of those it was: any of them means the reported edits are not the whole
/// story, and the pane says so and offers git's view.
enum EditReplay {
    static func accounts(for edits: [ReportedEdit], start: String, now: String) -> Bool {
        var text = edits.first?.oldText == nil ? "" : start
        for edit in edits {
            guard let replayed = apply(edit, to: text) else { return false }
            text = replayed
        }
        return text == now
    }

    /// One edit over a text, or nil when its passage is not there to replace.
    static func apply(_ edit: ReportedEdit, to text: String) -> String? {
        guard let old = edit.oldText, !old.isEmpty else {
            // A new file, or a Write over an empty one: the new text is the file.
            return edit.newText
        }
        // A Write over an existing file reports the whole file it replaced.
        if old == text { return edit.newText }
        guard text.contains(old) else { return nil }
        if edit.replaceAll { return text.replacingOccurrences(of: old, with: edit.newText) }
        guard let range = text.range(of: old) else { return nil }
        return text.replacingCharacters(in: range, with: edit.newText)
    }
}
