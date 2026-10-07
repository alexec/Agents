import AgentsKitCore
import SwiftUI

/// One line of a file tree, drawn the same in Files and Changes so the two read as one
/// pane with two filters (#63): the chevron, the icon, 14 points a level, the name, and
/// what changed at the end.
///
/// A changed file's icon is a square that says what happened to it (`ChangeTint`). The
/// shape, the words a row is read out with and its hover text carry the status as well,
/// so colour is never the only sign.
///
/// Shared since #345: the iPad's Files tree draws the window's rows.
struct FileTreeRow: View {
    enum Kind: Equatable {
        case folder(open: Bool)
        /// A file, and what happened to it since the agent started, if anything.
        case file(ChangeState?)
    }

    let name: String
    let kind: Kind
    let depth: Int
    /// The whole row in words, for VoiceOver.
    let label: String
    var added: Int?
    var removed: Int?
    /// A folded path (`App/Sources`) is cut at the front, so the part that tells it
    /// apart stays.
    var isPath = false
    var inProgress = false
    var help: String?
    let action: () -> Void

    static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 14 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // The same width for a file as a folder's chevron, so names line up.
                Image(systemName: "chevron.right")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .opacity(isFolder ? 1 : 0)
                    .frame(width: 10)
                icon
                Text(name)
                    .lineLimit(1)
                    .truncationMode(isPath ? .head : .middle)
                    // Gone: struck through and quieter, beside its red minus.
                    .strikethrough(kind == .file(.deleted))
                    .foregroundStyle(kind == .file(.deleted) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if inProgress {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 8)
                // A folder's total is quieter than a file's own counts.
                ChangeCounts(added: added, removed: removed, quiet: isFolder)
            }
            .padding(.leading, Self.indent(depth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        // A button is already one element: `children: .ignore` would swap it for one
        // that cannot be pressed. No Text inside carries a label of its own (memory).
        .accessibilityLabel(label)
        .accessibilityValue(isFolder ? (isOpen ? "Expanded" : "Collapsed") : "")
    }

    private var isFolder: Bool { if case .folder = kind { true } else { false } }
    private var isOpen: Bool { kind == .folder(open: true) }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .folder(let open):
            Image(systemName: open ? "folder.fill" : "folder")
                .foregroundStyle(.tint)
        case .file(let state?):
            Image(systemName: ChangeTint.symbol(state))
                .foregroundStyle(ChangeTint.color(state))
        case .file(nil):
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
        }
    }
}

extension FileTreeRow {
    /// A changed file, as both panes draw it.
    init(changed file: ChangedFile, name: String? = nil, depth: Int, action: @escaping () -> Void) {
        self.init(name: name ?? file.fileName, kind: .file(file.state), depth: depth,
                  label: ChangeWords.label(file), added: file.added, removed: file.removed,
                  inProgress: file.inProgress, help: ChangeWords.help(file), action: action)
    }

    /// A row of the Files tree, with what the agent did there (#63). A folder holding
    /// changes says how much changed under it, closed or open, so the agent's work deep
    /// in the tree can still be found. A changed file has the square and counts the
    /// Changes pane gives it. One touched in the conversation, before the list has
    /// caught up with it, is marked as changed.
    init(entry: DirectoryEntry, depth: Int, isOpen: Bool, changed: ChangedFile?,
         folderTotals: ChangeTree.Totals?, touched: Bool, action: @escaping () -> Void) {
        if entry.isDirectory {
            self.init(name: entry.name, kind: .folder(open: isOpen), depth: depth,
                      label: folderTotals.map { "\(entry.name), folder, \(ChangeWords.label($0))" }
                          ?? "\(entry.name), folder",
                      added: folderTotals?.added, removed: folderTotals?.removed, action: action)
        } else if let changed {
            self.init(changed: changed, name: entry.name, depth: depth, action: action)
        } else if touched {
            self.init(name: entry.name, kind: .file(.modified), depth: depth,
                      label: "\(entry.name), changed", help: "The agent changed this", action: action)
        } else {
            self.init(name: entry.name, kind: .file(nil), depth: depth, label: entry.name, action: action)
        }
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
