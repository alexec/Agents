import AgentsKitCore
import SwiftUI

/// The agent's reported edits and the repository changes, together, as on the Mac (#245).
struct RemoteChangesPane: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    @State private var list: ChangesList?
    @State private var problem: String?
    @State private var selectedPath: String?
    @State private var collapsed: Set<String> = []
    @State private var revision = 0
    private var paneState: PaneState { model.panes.state(for: agent.id) }

    var body: some View {
        Group {
            if let selectedPath = selectedPath ?? paneState.changesPath {
                // Asked of the Mac, as the window and the page do (#535).
                RemoteChangeFileView(agent: agent, path: selectedPath,
                                     listed: list?.files.first { $0.path == selectedPath },
                                     hasGit: list?.git.isAvailable ?? false) {
                    self.selectedPath = nil
                    paneState.changesPath = nil
                }
                .id(selectedPath)
            } else if let list {
                if list.files.isEmpty, !list.reportsEdits, case .unavailable(let why) = list.git {
                    ContentUnavailableView("Changes unavailable", systemImage: "arrow.triangle.2.circlepath",
                                           description: Text(Self.unavailable(why)))
                } else if list.files.isEmpty {
                    ContentUnavailableView("No changes yet", systemImage: "checkmark.circle")
                } else {
                    files(list)
                }
            } else if let problem {
                ContentUnavailableView("Changes could not be read", systemImage: "exclamationmark.triangle",
                                       description: Text(problem))
            } else {
                ProgressView()
            }
        }
        .task(id: revision) {
            // A moment's pause, so the folder events of one save are one ask.
            if revision > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await fetch()
        }
        .task {
            // The folder is watched while the pane shows it, so `files/changed` brings
            // a change git sees outside the conversation (#535).
            await model.files.watch(agentID: agent.id, folder: agent.cwd)
            await untilCancelled()
            await model.files.unwatch(agentID: agent.id, folder: agent.cwd)
        }
        .onChange(of: model.files.anyChange[agent.id] ?? 0) { revision += 1 }
        .onChange(of: model.files.reconnections) { revision += 1 }
        .onChange(of: model.entries.count) { revision += 1 }
        .onChange(of: agent.state) { revision += 1 }
        .onChange(of: agent.cwd) { revision += 1 }
    }

    private func files(_ list: ChangesList) -> some View {
        let lines = ChangeTree.lines(ChangeTree.build(list.files), collapsed: collapsed)
        let added = list.files.reduce(0) { $0 + ($1.added ?? 0) }
        let removed = list.files.reduce(0) { $0 + ($1.removed ?? 0) }
        return List {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(list.files.count) \(list.files.count == 1 ? "file" : "files") · +\(added) −\(removed)")
                    .appText(.fine).foregroundStyle(.secondary)
                if let source = Self.source(list.git) {
                    Text(source).appText(.fine).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(lines) { line in
                // The window's rows (#345): the same squares, counts and words.
                switch line.node {
                case .folder(let name, let key, _, let totals):
                    let open = !collapsed.contains(key)
                    FileTreeRow(name: name, kind: .folder(open: open), depth: line.depth,
                                label: "\(name), folder, \(ChangeWords.label(totals))",
                                added: totals.added, removed: totals.removed,
                                isPath: name.contains("/")) {
                        if open { collapsed.insert(key) } else { collapsed.remove(key) }
                    }
                case .file(let file):
                    FileTreeRow(changed: file, depth: line.depth) { selectedPath = file.path }
                }
            }
            if let more = list.more, more > 0 {
                Text(more == 1 ? "and 1 more file" : "and \(more) more files")
                    .appText(.fine).foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func fetch() async {
        do {
            let answer = try await model.changes(for: agent.id)
            list = answer
            problem = nil
        } catch {
            if list == nil { problem = "What this agent changed could not be read." }
        }
    }

    private static func source(_ git: GitView) -> String? {
        switch git {
        case .shared:
            "Also includes changes by others in this folder."
        case .sharedFromHead:
            "Git shows uncommitted changes in this folder, which may include others' work."
        case .owned, .unavailable:
            nil
        }
    }

    private static func unavailable(_ why: ChangesUnavailable) -> String {
        switch why {
        case .notARepository: "This folder is not a Git repository."
        case .gitNotInstalled: "Git is not installed on the Mac."
        case .folderGone: "The agent's folder is gone."
        case .failed(let message): message
        }
    }
}
