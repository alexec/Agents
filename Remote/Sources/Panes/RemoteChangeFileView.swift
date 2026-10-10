import AgentsKitCore
import CodeText
import SwiftUI

/// One file in the Changes pane, as the Mac answers `changes/file` (#535): the agent's
/// edits, or the whole file as it stands with each change marked, as the window's
/// `ChangeFileView` and the page's have it.
///
/// A file only git knows about — another agent's edit, or the person's own — is the
/// Mac's to describe, so it is asked rather than rebuilt from the conversation. A Mac
/// that cannot answer gets the conversation's copy, `ChangesView`, as before.
struct RemoteChangeFileView: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    let path: String
    /// The file's row in the latest list, when it is in it. Watched so the detail is
    /// asked for again only when what the row says has changed.
    let listed: ChangedFile?
    /// Whether git can be asked about this agent's folder: what Whole file needs.
    let hasGit: Bool
    let back: () -> Void

    private enum Shown: Hashable { case edits, whole }

    @State private var detail: ChangedFileDetail?
    @State private var problem: String?
    @State private var chosen = Shown.edits
    /// A file with a great deal changed is drawn when asked, not on the way in.
    @State private var drawAnyway = false
    @State private var whole: [DiffLine]?
    @State private var wholeProblem: String?
    @State private var wholeRows: WholeRows?
    /// The change Next and Previous last went to, and where to scroll for it.
    @State private var stop: Int?
    @State private var scrollTarget: Int?

    /// More changed lines than this and the edits wait to be asked for, as on the Mac.
    static let drawLimit = 2_000

    private var paneState: PaneState { model.panes.state(for: agent.id) }
    private var file: ChangedFile? { detail?.file ?? listed }
    private var canShowEdits: Bool { (file?.editCount ?? 0) > 0 || file?.inProgress == true }
    private var canShowWhole: Bool {
        hasGit && file?.outsideFolder == false && file?.state != .binary
    }

    /// Edits unless there are none to show; then the file.
    private var view: Shown {
        if chosen == .whole, canShowWhole { return .whole }
        return canShowEdits || !canShowWhole ? .edits : .whole
    }

    private var watch: Watch {
        Watch(path: path, editCount: listed?.editCount, added: listed?.added, removed: listed?.removed)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if canShowEdits, canShowWhole {
                Picker("", selection: Binding(get: { view }, set: { chosen = $0 })) {
                    Text("Edits").tag(Shown.edits)
                    Text("Whole file").tag(Shown.whole)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            if file?.beyondReported == true {
                beyondReported
            }
            Divider()
            if view == .whole { wholeFile } else { content }
        }
        .task(id: watch) { await fetch() }
        .task(id: WholeAsk(watch: watch, shown: view == .whole)) {
            guard view == .whole else { return }
            await fetchWhole()
        }
    }

    private struct Watch: Hashable {
        var path: String
        var editCount: Int?
        var added: Int?
        var removed: Int?
    }

    private struct WholeAsk: Hashable {
        var watch: Watch
        var shown: Bool
    }

    private func fetch() async {
        do {
            detail = try await model.changeDetail(for: agent.id, path: path)
            problem = nil
        } catch {
            if detail == nil { problem = "The changes to this file could not be read." }
        }
    }

    private func fetchWhole() async {
        do {
            whole = try await model.changeDetail(for: agent.id, path: path, whole: true).whole
            wholeProblem = whole == nil ? "The whole file can't be shown." : nil
            wholeRows = whole.map { WholeRows($0, path: path) }
        } catch {
            if whole == nil { wholeProblem = "The whole file could not be read." }
        }
    }

    // MARK: The header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("All changed files")

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(URL(filePath: path).lastPathComponent)
                        .appText(.supporting)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let file, let mark = Self.mark(for: file) {
                        Text(mark)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                }
                if let file {
                    ChangeCounts(added: file.added, removed: file.removed)
                }
            }
            Spacer(minLength: 8)
            if view == .whole, let stops = wholeRows?.stops, !stops.isEmpty {
                stepButtons(stops)
            }
            if file?.state != .deleted {
                Button("Open in Files") {
                    paneState.open(file: URL(filePath: path), line: file?.firstLine)
                }
                .buttonStyle(.borderless)
                .appText(.fine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The word after the name, as the window's row has it.
    private static func mark(for file: ChangedFile) -> String? {
        switch file.state {
        case .added: "new"
        case .deleted: "deleted"
        case .binary: "binary"
        case .renamed: ChangeWords.oldPath(of: file).map { "renamed from \($0)" } ?? "renamed"
        case .untracked: "untracked"
        case .modified: nil
        }
    }

    /// Previous and Next change, in Whole file. Folds only ever hide unchanged lines,
    /// so a change is always there to go to.
    private func stepButtons(_ stops: [Int]) -> some View {
        let current = stop.flatMap { stops.firstIndex(of: $0) }
        return HStack(spacing: 4) {
            Button {
                go(to: current.map { stops[max($0 - 1, 0)] } ?? stops[0])
            } label: {
                Image(systemName: "chevron.up")
            }
            .accessibilityLabel("Previous change")
            .disabled(current == nil || current == 0)
            Button {
                go(to: current.map { stops[min($0 + 1, stops.count - 1)] } ?? stops[0])
            } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel("Next change")
            .disabled(current == stops.count - 1)
        }
        .buttonStyle(.borderless)
    }

    private func go(to row: Int) {
        stop = row
        // Set to nil first, so going to the same change twice still scrolls.
        scrollTarget = nil
        DispatchQueue.main.async { scrollTarget = row }
    }

    /// The reported edits are not the whole story, and the file says so.
    private var beyondReported: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This file has changed since the agent's last edit, in ways it didn't report.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if canShowWhole, view != .whole {
                Button("See the whole file") { chosen = .whole }
                    .buttonStyle(.borderless)
                    .appText(.fine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Edits

    @ViewBuilder
    private var content: some View {
        if let detail {
            let changed = detail.edits.reduce(0) { $0 + $1.addedLines + $1.removedLines }
            if !drawAnyway, changed > Self.drawLimit {
                tooMany("\(changed) lines changed in \(detail.edits.count) edits.")
            } else {
                edits(detail.edits)
            }
        } else if problem != nil {
            // A Mac that cannot answer: what the conversation carries, as before.
            ChangesView(path: path)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func edits(_ edits: [ReportedEdit]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if edits.isEmpty {
                    Text(file?.inProgress == true
                         ? "An edit to this file is still being made."
                         : "The agent reported no edits to this file. Whole file shows what changed.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(edits.enumerated()), id: \.element.id) { number, edit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(edits.count > 1 ? "Edit \(number + 1)" : "Edit")
                            Text(edit.at, style: .time)
                            if edit.oldText == nil { Text("· made the file") }
                        }
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                        DiffView(diff: edit.diff, maxHeight: nil, showsPath: false)
                    }
                }
            }
            .padding(12)
            .readableWidth()
        }
    }

    // MARK: Whole file

    @ViewBuilder
    private var wholeFile: some View {
        if let whole {
            let changed = whole.count { $0.kind != .context }
            if !drawAnyway, changed > Self.drawLimit {
                tooMany("\(changed) lines changed.")
            } else if let wholeRows {
                ScrollViewReader { reader in
                    ScrollView([.vertical, .horizontal]) {
                        CodeRows(rows: wholeRows.rows, language: wholeRows.language,
                                 oldText: wholeRows.oldText, newText: wholeRows.newText,
                                 numbered: true, lazy: true)
                            .padding(.vertical, 8)
                    }
                    .onChange(of: scrollTarget) {
                        guard let scrollTarget else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            reader.scrollTo(scrollTarget, anchor: .top)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        } else if let wholeProblem {
            Text(wholeProblem)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tooMany(_ said: String) -> some View {
        VStack(spacing: 10) {
            Text(said)
                .appText(.supporting)
                .foregroundStyle(.secondary)
            Button("Show changes") { drawAnyway = true }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Whole file as diff rows, with the two texts they are coloured from and where each
/// change starts, as the window works them out.
private struct WholeRows {
    let rows: [DiffRow]
    let oldText: String
    let newText: String
    let stops: [Int]
    let language: CodeLanguage?

    init(_ lines: [DiffLine], path: String) {
        rows = LineDiff.rows(whole: lines.map { line in
            let kind: DiffRow.Kind = switch line.kind {
            case .context: .context
            case .added: .added
            case .removed: .removed
            }
            return (kind: kind, text: line.text, newLine: line.newLine)
        })
        oldText = rows.filter { $0.kind != .added }.map(\.text).joined(separator: "\n")
        newText = rows.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n")
        stops = LineDiff.changeStops(rows)
        language = CodeLanguage.detect(path: path, firstLine: nil)
    }
}
