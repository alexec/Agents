import AgentsKitCore
import SwiftUI

/// A file a tool call touched: what is in it, and what the agent changed.
///
/// Read only, and read only structurally: there is no save, no share and no editor
/// here, because FR-020a asks for the reading half of the Mac's files pane and
/// SC-014 asks that the absence be a fact about the screens rather than a flag
/// somebody could flip.
///
/// **Where the content comes from, and why it is not the file.** The Mac's pane reads
/// the disk. An iPad has no such disk, and the protocol has no method that hands a
/// client a file's bytes — `ShownFile` carries a path and a line and nothing else.
/// What it does carry, on every edit, is `ToolCallContent.diff`, whose `newText` is
/// what the agent wrote and whose `oldText` is what was there before. So this is the
/// file as the conversation knows it: accurate about what the agent did, and honest
/// that it is not a live read. A path the transcript has never seen says so rather
/// than showing an empty page (research §6 assumed the content came for free; it
/// does not, and this is the half that needs no new protocol).
struct FileView: View {
    @Environment(RemoteModel.self) private var model
    let path: String

    private var name: String { URL(filePath: path).lastPathComponent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if touches.isEmpty {
                    Unseen(name: name)
                } else {
                    Provenance(count: touches.count)
                    ForEach(Array(touches.enumerated()), id: \.offset) { index, touch in
                        Touch(touch: touch, isLatest: index == 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableWidth()
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
    }

    /// Every change to this file in the transcript, newest first. Newest first because
    /// the newest is the file as it now stands, and that is what somebody opening a
    /// file wants first; the ones below it are how it got there.
    private var touches: [ToolCallContent.Diff] {
        let wanted = URL(filePath: path).standardizedFileURL.path
        var found: [ToolCallContent.Diff] = []
        for entry in model.entries {
            let call: ToolCall
            switch entry.kind {
            case .toolCall(let c), .toolCallUpdate(let c): call = c
            default: continue
            }
            for piece in call.content {
                guard case .diff(let diff) = piece,
                      URL(filePath: diff.path).standardizedFileURL.path == wanted else { continue }
                found.append(diff)
            }
        }
        return found.reversed()
    }
}

/// What this page is, said once at the top. Without it a reader has no way to tell a
/// file the agent rewrote wholesale from one it changed a line of.
private struct Provenance: View {
    let count: Int

    var body: some View {
        Text(count == 1
             ? "As the agent left it. One change, in this conversation."
             : "As the agent left it. \(count) changes, newest first.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// One change: what the file said afterwards, and the change itself under it.
private struct Touch: View {
    let touch: ToolCallContent.Diff
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLatest {
                FileLines(text: touch.newText)
            }
            DiffView(diff: touch)
        }
    }
}

/// The file's text, numbered, in the manner of the Mac's `FileLines`.
///
/// Truncated, and said so when it is. A file the agent rewrote can be thousands of
/// lines and an iPad asked to lay every one of them out in a `LazyVStack` inside a
/// `ScrollView` will do it, slowly, for a reader who wanted the top.
private struct FileLines: View {
    let text: String

    private static let limit = 600

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(Self.limit)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(line.isEmpty ? " " : String(line))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
            if lines.count > Self.limit {
                Text("\(lines.count - Self.limit) more lines, on your Mac")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A file nothing in this conversation touched — an agent's `show_file` for something
/// it only read, most often. Named, and not pretended at.
private struct Unseen: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing in this conversation changed \(name).")
                .font(.callout)
            Text("The iPad shows a file as the agent's own changes describe it. "
                 + "A file it only read is on your Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
