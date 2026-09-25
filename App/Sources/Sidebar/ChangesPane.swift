import AgentsKit
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
    /// How far into the window's transcript this pane has looked for finished edits.
    @State private var seenEntries = 0
    /// Tool calls seen carrying a diff, so their ending can be told from any other.
    @State private var diffCalls: Set<String> = []

    private var isShown: Bool { frame.pane == .changes }

    var body: some View {
        Group {
            if let selection = state.changesSelection {
                ChangeFileView(agent: agent, state: state, selection: selection,
                               listed: list?.files.first { $0.path == selection.path },
                               hasGit: list?.git.isAvailable ?? false)
            } else if let list {
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
        // Hidden panes are kept alive beside the shown one, so this one only asks
        // while it is shown, and asks again as soon as it is.
        .task(id: Ask(shown: isShown, revision: revision)) {
            guard isShown else { return }
            await fetch()
        }
        .onChange(of: model.entries.count) { _, _ in noticeFinishedEdits() }
        .onChange(of: agent.state) { _, _ in revision += 1 }
        .onAppear { seenEntries = model.entries.count }
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
        let entries = model.entries
        if entries.count < seenEntries { seenEntries = 0 }
        var finished = false
        for entry in entries[seenEntries...] {
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
        seenEntries = entries.count
        if finished { revision += 1 }
    }

    /// Grouped by folder, settled with Alex at 035's T021: a change is read as "what
    /// happened in this part of the project", and the folder said once reads more
    /// quietly than the same folder under every row.
    private func files(_ list: ChangesList) -> some View {
        List {
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
            ForEach(Self.folders(of: list.files), id: \.name) { folder in
                Section {
                    ForEach(folder.files) { file in
                        Button {
                            state.changesSelection = ChangesSelection(path: file.path)
                        } label: {
                            ChangeRow(file: file)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(folder.name)
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    /// Folders in the order of the first file changed in each; files keep their own
    /// order inside.
    static func folders(of files: [ChangedFile]) -> [(name: String, files: [ChangedFile])] {
        var order: [String] = []
        var grouped: [String: [ChangedFile]] = [:]
        for file in files {
            let name = folderName(of: file)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(file)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// The folder it is in, relative where there is something to be relative to.
    static func folderName(of file: ChangedFile) -> String {
        let shown = file.relativePath ?? file.path
        let parent = (shown as NSString).deletingLastPathComponent
        return parent.isEmpty ? "Top folder" : parent
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

/// One file in the list: its name and folder, what kind of change, and how much.
struct ChangeRow: View {
    let file: ChangedFile

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(file.fileName)
                        .appText(.supporting)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let mark = ChangeMark.word(for: file) {
                        Text(mark)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                    if file.inProgress {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                ChangeCounts(added: file.added, removed: file.removed)
                if let note {
                    Text(note)
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// Where the knowledge came from, when it is not simply the agent's edits.
    private var note: String? {
        let edits = file.editCount == 1 ? "1 edit" : "\(file.editCount) edits"
        switch file.source {
        case .seen: return "in the folder"
        case .reportedAndSeen where file.beyondReported: return "\(edits) · changed since"
        default: return file.editCount > 0 ? edits : nil
        }
    }
}

/// `+14 −3`, by weight rather than by colour: what came in primary, what went quieter.
struct ChangeCounts: View {
    let added: Int?
    let removed: Int?

    var body: some View {
        if let added, let removed {
            HStack(spacing: 4) {
                Text("+\(added)").foregroundStyle(.primary)
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
