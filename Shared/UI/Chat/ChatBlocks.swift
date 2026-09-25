import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A message, drawn block by block, the same on every screen (033).
///
/// Text goes through the markdown renderer, because agents write markdown whether or
/// not anybody asked. A picture is drawn as a picture: 001 turned one into an empty
/// line, which is what happens when a message is flattened to its text.
///
/// `MarkdownText` stays each app's own. The Mac's draws a document's caret and a
/// relative image; the phone's scrolls code sideways at a width where wrapping it would
/// make it unreadable.
struct BlocksView: View {
    let blocks: [ContentBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: ContentBlock) -> some View {
        switch block {
        case .text(let text):
            MarkdownText(markdown: text)

        case .image(let data, _, _):
            if let image = Self.image(data) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label("A picture that cannot be drawn here", systemImage: "photo")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
            }

        case .audio:
            Label("Audio", systemImage: "waveform")
                .appText(.supporting)
                .foregroundStyle(.secondary)

        case .resourceLink(let uri, let name, _, _, _):
            #if os(macOS)
            Button {
                if let url = URL(string: uri) { NSWorkspace.shared.open(url) }
            } label: {
                Label(name, systemImage: "doc")
                    .appText(.supporting)
            }
            .buttonStyle(.link)
            #else
            // A file on the Mac. The phone names it and cannot open it.
            let _ = uri
            Label(name, systemImage: "doc")
                .appText(.supporting)
                .foregroundStyle(.secondary)
            #endif

        case .resource(let uri, let text, _, _, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(string: uri)?.lastPathComponent ?? uri)
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                if let text { MarkdownText(markdown: text) }
            }

        case .unknown(let raw):
            // Kept rather than dropped, and shown as what it is.
            Text(raw["type"]?.stringValue.map { "Something this app does not draw yet: \($0)" }
                 ?? "Something this app does not draw yet")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
    }

    private static func image(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

/// What changed in a file: the old lines against the new ones.
///
/// Red and green would be the obvious thing and this app has one rule about colour,
/// which is that it means something went wrong. So a change is shown by its marks and
/// its weight instead, and the only colour here is the one for a line that was removed.
struct DiffView: View {
    let diff: ToolCallContent.Diff
    /// The conversation caps an edit so one big one does not take the page; the
    /// Changes pane, where the edit is the thing being read, does not (035).
    var maxHeight: CGFloat? = 280
    var showsPath = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsPath {
                Text(diff.path)
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(line.mark)
                                .appText(.code)
                                .foregroundStyle(.tertiary)
                            Text(line.text.isEmpty ? " " : line.text)
                                .appText(.code)
                                .foregroundStyle(line.isRemoved ? AnyShapeStyle(.tertiary)
                                                                : AnyShapeStyle(.primary))
                                .strikethrough(line.isRemoved)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: maxHeight)
            .paperWell(in: RoundedRectangle(cornerRadius: 8))
        }
        .textSelection(.enabled)
    }

    private struct Line {
        var mark: String
        var text: String
        var isRemoved: Bool
    }

    /// Old lines then new lines. Not a real diff algorithm: the runtimes send the two
    /// sides and what the reader wants is to see both, not to be told which words moved.
    private var lines: [Line] {
        let old = (diff.oldText ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        let new = diff.newText.split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [Line] = []
        if diff.oldText != nil, !(old.count == 1 && old[0].isEmpty) {
            lines += old.map { Line(mark: "-", text: String($0), isRemoved: true) }
        }
        if !(new.count == 1 && new[0].isEmpty) {
            lines += new.map { Line(mark: "+", text: String($0), isRemoved: false) }
        }
        return lines
    }
}

/// What a command the app is running for an agent has printed so far.
///
/// On a phone this is what reached the phone while it was listening. A command that ran
/// before it connected says so rather than showing an empty box as though it had printed
/// nothing.
struct TerminalOutputView: View {
    let text: String

    var body: some View {
        if text.isEmpty {
            Text("Ran a command. Its output did not reach this screen.")
                .appText(.fine)
                .foregroundStyle(.tertiary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .appText(.code)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 240)
            .paperWell(in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// What the agent said it was going to do.
///
/// The clearest statement an agent makes of its intentions, which is the moment to stop
/// it if it is wrong. 001 drew "Made a plan". In the transcript this is the plan as it
/// was at that point; the phone's `CurrentPlanStrip` draws it as it is now.
struct PlanView: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(mark(for: entry.status))
                        .appText(.code)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(entry.content)
                        .appText(.supporting)
                        .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                        .strikethrough(plan.state == .withdrawn)
                }
                // The mark is a glyph; the status is said in words instead (FR-037).
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(spoken(entry.status)): \(entry.content)")
            }
            if plan.state == .withdrawn {
                Text("The agent dropped this plan")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }

    private func mark(for status: PlanEntry.Status) -> String {
        switch status {
        case .pending: return "○"
        case .inProgress: return "◐"
        case .completed: return "●"
        }
    }

    private func spoken(_ status: PlanEntry.Status) -> String {
        if plan.state == .withdrawn { return "Dropped" }
        switch status {
        case .completed: return "Done"
        case .inProgress: return "Doing now"
        case .pending: return "To do"
        }
    }
}

/// Something the agent asked the app to do. Reads are quiet; a write says what it did.
struct ServedRequestLine: View {
    let request: ServedRequest

    var body: some View {
        HStack(spacing: 6) {
            Text(request.summary)
            if case .refused(let reason) = request.outcome {
                Text(reason).tinted(.failure)
            }
            if case .failed(let message) = request.outcome {
                Text(message).tinted(.failure)
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
    }
}
