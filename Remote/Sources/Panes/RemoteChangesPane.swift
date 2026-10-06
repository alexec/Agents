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
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            self.selectedPath = nil
                            paneState.changesPath = nil
                        } label: {
                            Label("All changed files", systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                    .padding(12)
                    Divider()
                    ChangesView(path: selectedPath)
                }
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
        .task(id: revision) { await fetch() }
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
                switch line.node {
                case .folder(let name, let key, _, let totals):
                    let open = !collapsed.contains(key)
                    Button {
                        if open { collapsed.insert(key) } else { collapsed.remove(key) }
                    } label: {
                        treeRow(name, icon: open ? "folder.fill" : "folder", depth: line.depth,
                                detail: "\(totals.files) files · +\(totals.added) −\(totals.removed)")
                    }
                    .accessibilityLabel("\(name), folder, \(ChangeWords.label(totals))")
                    .buttonStyle(.plain)
                case .file(let file):
                    Button { selectedPath = file.path } label: {
                        treeRow(file.fileName, icon: ChangeTint.symbol(file.state),
                                color: ChangeTint.color(file.state), depth: line.depth,
                                detail: file.added.map { "+\($0) −\(file.removed ?? 0)" } ?? "")
                    }
                    .accessibilityLabel(ChangeWords.label(file))
                    .buttonStyle(.plain)
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

    private func treeRow(_ name: String, icon: String, color: Color = Paper.accent,
                         depth: Int, detail: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if !detail.isEmpty { Text(detail).appText(.fine).monospacedDigit().foregroundStyle(.secondary) }
        }
        .padding(.leading, CGFloat(depth * 14))
        .contentShape(Rectangle())
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
