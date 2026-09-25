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

    @State private var detail: ChangedFileDetail?
    @State private var problem: String?
    /// A file with a great deal changed is drawn when asked, not on the way in, so one
    /// generated file does not stall the pane (FR-015).
    @State private var drawAnyway = false

    /// More changed lines than this and the edits wait to be asked for.
    static let drawLimit = 2_000

    private var file: ChangedFile? { detail?.file ?? listed }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: Watch(path: selection.path, editCount: listed?.editCount,
                        added: listed?.added, removed: listed?.removed)) {
            await fetch()
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
                    .id(edit.id)
                }
            }
            .padding(12)
        }
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
