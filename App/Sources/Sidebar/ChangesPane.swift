import AgentsKitCore
import SwiftUI

/// What the agent changed, all together: the files, and what changed in each (035).
///
/// The conversation shows each edit where it happened, which answers "what is it doing".
/// This answers the question at the end of a turn — what did it change, and is that
/// right — without a terminal and without scrolling back.
///
/// The list is the daemon's, not folded here: the window holds one page of the
/// transcript, and a list that stops at the page is wrong without saying so.
struct ChangesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    let agent: Agent
    let state: AgentPaneState

    @State private var list: ChangesList?
    @State private var problem: String?
    /// Bumped when something happened that could have changed the list: an edit
    /// finished, or the agent's turn moved on. Asking is keyed on it, so a burst of
    /// them while a request is out collapses into one more request, not many.
    @State private var revision = 0
    /// How far into the conversation, counted over the whole transcript, this pane has
    /// looked for finished edits.
    @State private var seenEntries = 0
    /// Tool calls seen carrying a diff, so their ending can be told from any other.
    @State private var diffCalls: Set<String> = []

    private var isShown: Bool { frame.pane == .changes }

    var body: some View {
        // The tree stays under an open file rather than going, so Back finds it as it was
        // left, scrolled where it was with the file marked, as Files does (#66).
        ZStack {
            listView
                .opacity(state.changesSelection == nil ? 1 : 0)
                .allowsHitTesting(state.changesSelection == nil)
                .accessibilityHidden(state.changesSelection != nil)
            if let selection = state.changesSelection {
                ChangeFileView(agent: agent, state: state, selection: selection,
                               listed: list?.files.first { $0.path == selection.path },
                               hasGit: list?.git.isAvailable ?? false)
            }
        }
        // Hidden panes are kept alive beside the shown one, so this one only asks
        // while it is shown, and asks again as soon as it is.
        .task(id: Ask(shown: isShown, revision: revision)) {
            guard isShown else { return }
            await fetch()
        }
        .onChange(of: model.entries.count) { _, _ in noticeFinishedEdits() }
        .onChange(of: agent.state) { _, _ in revision += 1 }
        // A move changes where git's view is taken, whether or not a turn went with it (053).
        .onChange(of: agent.cwd) { _, _ in revision += 1 }
        // However the file was opened, from a row or from an edit in the conversation.
        .onChange(of: state.changesSelection?.path) { _, path in
            if let path { state.changesMarked = path }
        }
        .onAppear { seenEntries = model.work.firstEntryIndex + model.entries.count }
    }

    @ViewBuilder
    private var listView: some View {
        Group {
            if let list {
                if list.files.isEmpty, !list.reportsEdits, case .unavailable(let why) = list.git {
                    NothingToShow(runtime: agent.runtimeID, why: why)
                } else if list.files.isEmpty {
                    NothingChanged()
                } else {
                    files(list)
                }
            } else if let problem {
                Text(problem)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
    }

    private struct Ask: Equatable {
        var shown: Bool
        var revision: Int
    }

    private func fetch() async {
        do {
            let answer = try await model.changes(for: agent.id)
            // Only replaced when it differs, so a refresh that found nothing new does
            // not redraw the rows under the reader.
            if answer != list { list = answer }
            problem = nil
        } catch {
            if list == nil { problem = "What this agent changed could not be read." }
        }
    }

    /// An edit counts once its tool call has ended; that is when the list can change.
    private func noticeFinishedEdits() {
        // Counted by position in the whole conversation rather than in the page, because
        // the page loses its oldest entries as a long one goes on, and an earlier page
        // going in front is nothing new either.
        let entries = model.entries
        let from = model.work.firstEntryIndex
        var start = seenEntries - from
        if start < 0 || start > entries.count { start = 0 }
        var finished = false
        for entry in entries[start...] {
            switch entry.kind {
            case .toolCall(let call), .toolCallUpdate(let call):
                guard let id = call.toolCallID else { continue }
                if call.content.contains(where: { if case .diff = $0 { true } else { false } }) {
                    diffCalls.insert(id)
                }
                if call.status == "completed" || call.status == "failed", diffCalls.contains(id) {
                    finished = true
                }
            default:
                continue
            }
        }
        seenEntries = from + entries.count
        if finished { revision += 1 }
    }

    /// A tree like the Files pane's, and like GitHub's "Files changed" (#63): folders
    /// nest and fold, each with its total, and each file's icon says what happened to it.
    /// It replaced 035's one section per folder, which never showed at a glance which
    /// files were new, gone or moved, and looked nothing like Files beside it.
    private func files(_ list: ChangesList) -> some View {
        let lines = ChangeTree.lines(ChangeTree.build(list.files), collapsed: state.changesCollapsed)
        return List {
            VStack(alignment: .leading, spacing: 4) {
                Text(total(list.files))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                if let source = Self.source(list.git) {
                    Text(source)
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(lines) { line in
                row(line)
                    .listRowBackground(Group {
                        if case .file(let file) = line.node, file.path == state.changesMarked {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Paper.accent.opacity(0.18))
                                .padding(.horizontal, 10)
                        }
                    })
            }
            // The daemon names at most 500 files and counts the rest (#210).
            if let more = list.more, more > 0 {
                Text(more == 1 ? "and 1 more file" : "and \(more) more files")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ line: ChangeTree.Line) -> some View {
        switch line.node {
        case .folder(let name, let key, _, let totals):
            let open = !state.changesCollapsed.contains(key)
            FileTreeRow(name: name, kind: .folder(open: open), depth: line.depth,
                        label: "\(name), folder, \(ChangeWords.label(totals))",
                        added: totals.added, removed: totals.removed,
                        isPath: name.contains("/"), help: name.contains("/") ? name : nil) {
                if open { state.changesCollapsed.insert(key) } else { state.changesCollapsed.remove(key) }
            }
        case .file(let file):
            FileTreeRow(changed: file, depth: line.depth) {
                state.changesSelection = ChangesSelection(path: file.path)
            }
            .accessibilityAddTraits(file.path == state.changesMarked ? .isSelected : [])
        }
    }

    /// Said once above the list, and only where git's half could be read as this
    /// agent's when it may not be (FR-008). An agent's own worktree needs no word.
    static func source(_ git: GitView) -> String? {
        switch git {
        case .shared:
            return "Also shows what git sees changed in this folder since the agent started. That may include other agents' work, and yours."
        case .sharedFromHead:
            return "This agent started before its starting point was recorded, so git's part is only what is uncommitted, and may include others' work."
        case .owned, .unavailable:
            return nil
        }
    }

    private func total(_ files: [ChangedFile]) -> String {
        let added = files.reduce(0) { $0 + ($1.added ?? 0) }
        let removed = files.reduce(0) { $0 + ($1.removed ?? 0) }
        let count = files.count == 1 ? "1 file" : "\(files.count) files"
        return "\(count) · +\(added) −\(removed)"
    }
}

/// `+14 −3`, by weight rather than by colour: what came in primary, what went quieter.
/// Quiet, both are: a folder's total, which should not outweigh its files.
struct ChangeCounts: View {
    let added: Int?
    let removed: Int?
    var quiet = false

    var body: some View {
        if let added, let removed {
            HStack(spacing: 4) {
                Text("+\(added)").foregroundStyle(quiet ? .tertiary : .primary)
                Text("−\(removed)").foregroundStyle(.tertiary)
            }
            .appText(.fine)
            .monospacedDigit()
        }
    }
}

/// The one word a change needs beyond its counts, if it needs one.
enum ChangeMark {
    static func word(for file: ChangedFile) -> String? {
        switch file.state {
        case .added: return "new"
        case .deleted: return "deleted"
        case .binary: return "binary"
        case .renamed: return "renamed"
        case .untracked: return "untracked"
        case .modified: return nil
        }
    }
}

/// The pane before the agent has changed anything. A statement, not an empty space.
private struct NothingChanged: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plusminus")
                .appText(.title)
                .foregroundStyle(.tertiary)
            Text("Nothing changed yet")
                .appText(.reading).fontWeight(.semibold)
            Text("Each file this agent edits appears here, with what changed in it, as soon as the edit is made.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Neither source can say anything (FR-010): which is missing, and why, rather than an
/// empty list that reads as "nothing changed".
private struct NothingToShow: View {
    let runtime: String
    let why: ChangesUnavailable

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plusminus")
                .appText(.title)
                .foregroundStyle(.tertiary)
            Text("Nothing to show")
                .appText(.reading).fontWeight(.semibold)
            // True of every runtime: some never report, and one that does may simply
            // not have edited yet. What cannot be seen is a change made another way.
            Text("\(runtime.capitalized) hasn't reported any edits, and \(reason), so a change made any other way, by a command say, can't be shown here.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reason: String {
        switch why {
        case .notARepository: return "this folder isn't tracked by git"
        case .gitNotInstalled: return "git isn't installed on this Mac"
        case .folderGone: return "its folder is no longer there"
        case .failed(let message): return "git couldn't be asked (\(message))"
        }
    }
}
