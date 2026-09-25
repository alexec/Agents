import AgentsKit
import SwiftUI

/// One file in the Changes pane: every edit the agent made to it, in order (035).
struct ChangeFileView: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    let agent: Agent
    let state: AgentPaneState
    let selection: ChangesSelection
    /// The file's row in the latest list, when it is in it. Watched so the detail is
    /// asked for again only when what the row says has changed.
    let listed: ChangedFile?
    /// Whether git can be asked about this agent's folder: what Whole file needs.
    let hasGit: Bool

    @State private var detail: ChangedFileDetail?
    @State private var problem: String?
    /// A file with a great deal changed is drawn when asked, not on the way in, so one
    /// generated file does not stall the pane (FR-015).
    @State private var drawAnyway = false
    /// The edit the pane was opened at, outlined for a moment once it is in view.
    @State private var outlined: String?
    /// The tool call whose arrival has been answered, so a refresh never pulls the
    /// reader back to it.
    @State private var answered: String?
    /// The whole file as it stands, asked for the first time Whole file is chosen.
    @State private var whole: [DiffLine]?
    @State private var wholeProblem: String?

    /// More changed lines than this and the edits wait to be asked for.
    static let drawLimit = 2_000

    private var file: ChangedFile? { detail?.file ?? listed }

    /// The two views settled at T021: what the agent reported, and the file as it
    /// stands. Only the ones there is something for.
    private var canShowEdits: Bool { (file?.editCount ?? 0) > 0 || file?.inProgress == true }
    private var canShowWhole: Bool {
        hasGit && file?.outsideFolder == false && file?.state != .binary
    }

    /// Edits unless there are none to show; then the file.
    private var view: ChangesSelection.View {
        if selection.view == .whole, canShowWhole { return .whole }
        return canShowEdits || !canShowWhole ? .edits : .whole
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if canShowEdits, canShowWhole {
                Picker("", selection: Binding(get: { view },
                                              set: { state.changesSelection?.view = $0 })) {
                    Text("Edits").tag(ChangesSelection.View.edits)
                    Text("Whole file").tag(ChangesSelection.View.whole)
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
        .task(id: Watch(path: selection.path, editCount: listed?.editCount,
                        added: listed?.added, removed: listed?.removed)) {
            await fetch()
        }
        .task(id: WholeAsk(watch: Watch(path: selection.path, editCount: listed?.editCount,
                                        added: listed?.added, removed: listed?.removed),
                           shown: view == .whole)) {
            guard view == .whole else { return }
            await fetchWhole()
        }
    }

    private struct WholeAsk: Equatable {
        var watch: Watch
        var shown: Bool
    }

    private func fetchWhole() async {
        do {
            whole = try await model.changeDetail(for: agent.id, path: selection.path, whole: true).whole
            wholeProblem = whole == nil ? "The whole file can't be shown." : nil
        } catch {
            if whole == nil { wholeProblem = "The whole file could not be read." }
        }
    }

    /// FR-007: the reported edits are not the whole story, and the file says so.
    private var beyondReported: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("This file has changed since the agent's last edit, in ways it didn't report.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if canShowWhole, view != .whole {
                Button("See the whole file") { state.changesSelection?.view = .whole }
                    .linkStyle()
                    .appText(.fine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// The file as it now stands against where the agent started: every line there,
    /// changed ones marked, removed ones where they were. Marks and weight, not colour.
    @ViewBuilder
    private var wholeFile: some View {
        if let whole {
            let changed = whole.count { $0.kind != .context }
            if !drawAnyway, changed > Self.drawLimit {
                VStack(spacing: 10) {
                    Text("\(changed) lines changed.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                    Button("Show changes") { drawAnyway = true }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(whole.enumerated()), id: \.offset) { _, line in
                            WholeLine(line: line)
                        }
                    }
                    .padding(.vertical, 8)
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

    private struct Watch: Equatable {
        var path: String
        var editCount: Int?
        var added: Int?
        var removed: Int?
    }

    private func fetch() async {
        do {
            detail = try await model.changeDetail(for: agent.id, path: selection.path)
            problem = nil
        } catch {
            if detail == nil { problem = "The changes to this file could not be read." }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                state.changesSelection = nil
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("All changed files")

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(URL(filePath: selection.path).lastPathComponent)
                        .appText(.supporting)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let file, let mark = ChangeMark.word(for: file) {
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
            if file?.state != .deleted {
                Button("Open in Files") { openInFiles() }
                    .buttonStyle(.borderless)
                    .appText(.fine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            if !drawAnyway, changedLines(detail) > Self.drawLimit {
                VStack(spacing: 10) {
                    Text("\(changedLines(detail)) lines changed in \(detail.edits.count) edits.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                    Button("Show changes") { drawAnyway = true }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                edits(detail.edits)
            }
        } else if let problem {
            Text(problem)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func edits(_ edits: [ReportedEdit]) -> some View {
        ScrollViewReader { reader in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if edits.isEmpty {
                    Text("An edit to this file is still being made.")
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
                    .padding(outlined == edit.id ? 6 : 0)
                    .overlay {
                        // By weight, not colour (FR-013): a frame, gone in a moment.
                        if outlined == edit.id {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.primary.opacity(0.45), lineWidth: 1.5)
                        }
                    }
                    .id(edit.id)
                }
            }
            .padding(12)
        }
        .task(id: Arrival(toolCallID: selection.toolCallID, count: edits.count)) {
            await bringIntoView(edits, with: reader)
        }
        }
    }

    private struct Arrival: Equatable {
        var toolCallID: String?
        var count: Int
    }

    /// Opened from an edit in the conversation (FR-014): that edit, in view, once. An
    /// edit the list does not have — still being made, or one that failed — leaves the
    /// reader at the first.
    private func bringIntoView(_ edits: [ReportedEdit], with reader: ScrollViewProxy) async {
        guard let wanted = selection.toolCallID, wanted != answered,
              let edit = edits.first(where: { $0.toolCallID == wanted }) else { return }
        answered = wanted
        reader.scrollTo(edit.id, anchor: .top)
        outlined = edit.id
        try? await Task.sleep(for: .seconds(1.6))
        withAnimation(.easeOut(duration: 0.3)) { outlined = nil }
    }

    private func changedLines(_ detail: ChangedFileDetail) -> Int {
        detail.edits.reduce(0) { $0 + $1.addedLines + $1.removedLines }
    }

    /// The files pane, at the first line the agent changed (FR-003).
    private func openInFiles() {
        state.openFile = URL(filePath: selection.path)
        state.openLine = file?.firstLine
        frame.pane = .files
    }
}

/// One line of Whole file: its number, its mark, its text.
private struct WholeLine: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // A space, not nothing, where a removed line has no number: an empty text
            // is shorter than a line and opened a gap under every removed one.
            Text(line.newLine.map(String.init) ?? " ")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.quaternary)
            Text(mark)
                .foregroundStyle(.tertiary)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .removed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .strikethrough(line.kind == .removed)
                .fontWeight(line.kind == .added ? .semibold : .regular)
        }
        .appText(.code)
        .fixedSize()
        .padding(.horizontal, 8)
    }

    private var mark: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }
}
