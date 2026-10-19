import AgentsKitCore
import CodeText
import SwiftUI

/// A view's `agents/open-diff` (#1341): a pull request's files, drawn with the Review page's
/// diff (`FileDiffView`, #1472), not in the view. Every file's hunks under its path and
/// counts; between hunks a break, long unchanged runs folded. Unified, or the old file beside
/// the new on a wide page. Shown over the view, on the Mac, the iPad and the iPhone alike.
struct AppViewDiffPage: View {
    let diff: AppViewDiff
    var openLink: (URL) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("reviewDiffLayout", store: WindowDefaults.store) private var layout = FileDiffView.Layout.unified
    @State private var rows: [String: [DiffRow]] = [:]
    @State private var width: CGFloat = 0

    /// Wide enough for the old file beside the new, as on the Review page.
    private var wide: Bool { width >= 820 }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        summary
                        ForEach(diff.files) { file in
                            section(file).id(file.path)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .task {
                    rows = Dictionary(diff.files.map { ($0.path, Self.rows($0)) }, uniquingKeysWith: { a, _ in a })
                    if let path = diff.path {
                        try? await Task.sleep(for: .milliseconds(100))
                        proxy.scrollTo(path, anchor: .top)
                    }
                }
            }
            .navigationTitle(diff.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if wide {
                    ToolbarItem(placement: .automatic) {
                        Picker("Show", selection: $layout) {
                            ForEach(FileDiffView.Layout.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 1000, minHeight: 560, idealHeight: 760)
        #endif
    }

    private var summary: some View {
        let added = diff.files.reduce(0) { $0 + $1.additions }, removed = diff.files.reduce(0) { $0 + $1.deletions }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files") changed")
                    .appText(.supporting)
                Text("+\(added) −\(removed)")
                    .appText(.fine)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(added) lines added, \(removed) removed")
                Spacer(minLength: 0)
                if let url = diff.url {
                    Button("Open on GitHub") { openLink(url) }.buttonStyle(.paper).appText(.fine)
                }
            }
            if diff.cut {
                Text("The diff is too long to show every file here. A file with no lines below is on GitHub.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(_ file: AppViewDiff.File) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .appText(.fine)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .truncationMode(.head)
                if file.change != "modified" {
                    Text(file.change).appText(.fine).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("+\(file.additions) −\(file.deletions)")
                    .appText(.fine)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(file.additions) lines added, \(file.deletions) removed")
            }
            if let rows = rows[file.path], !rows.isEmpty {
                FileDiffView(rows: rows, path: file.path, layout: wide ? layout : .unified)
                    .clipShape(RoundedRectangle(cornerRadius: Paper.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule, lineWidth: 1))
            } else {
                Text(file.note ?? "No lines to show.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The file's hunks as the diff's rows.
    static func rows(_ file: AppViewDiff.File) -> [DiffRow] {
        LineDiff.rows(hunks: file.hunks.map { hunk in
            LineDiff.Hunk(oldStart: hunk.oldStart, newStart: hunk.newStart, lines: hunk.lines.map { line in
                let kind: DiffRow.Kind = switch line.kind {
                case .added: .added
                case .removed: .removed
                case .context: .context
                }
                return (kind: kind, text: line.text)
            })
        })
    }
}
