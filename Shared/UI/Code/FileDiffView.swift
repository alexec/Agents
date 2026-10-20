import CodeText
import SwiftUI

/// A file's change, read in full on a page (#1472): every line with its number in the old
/// file and the new, long unchanged runs folded behind "N unchanged lines", a break where
/// lines between two hunks are not shown, and the changed words washed. Unified, or the old
/// file beside the new on a wide page.
///
/// The one diff of a page: the Review page of a change waiting for an OK, and the pull
/// request page (#1341). Its input is rows (`LineDiff.rows(hunks:)`), not what they came
/// from. It does not scroll: the page does. Long lines wrap, so prose reads as prose.
/// Marks, strike and weight say what changed, as everywhere else (041 FR-011, FR-013).
struct FileDiffView: View {
    enum Layout: String, CaseIterable, Identifiable {
        case unified, sideBySide
        var id: Self { self }
        var title: String { self == .unified ? "Unified" : "Side by Side" }
    }

    let rows: [DiffRow]
    /// The file's path, for its language's colours.
    let path: String
    /// The two sides whole, for colour; nil leaves the code plain.
    var oldText: String?
    var newText: String?
    var layout: Layout = .unified

    @State private var opened: Set<Int> = []
    @State private var oldDocument: CodeDocument?
    @State private var newDocument: CodeDocument?

    var body: some View {
        let items = self.items
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.self) { item in
                switch item {
                case .row(let index):
                    DiffLineRow(row: rows[index], document: document(for: rows[index]), side: nil)
                case .pair(let old, let new):
                    HStack(alignment: .top, spacing: 0) {
                        half(old, side: .old)
                        Divider()
                        half(new, side: .new)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .fold(let fold):
                    FoldRow(count: fold.range.count) { opened.insert(fold.range.lowerBound) }
                case .gap:
                    Text("⋯")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3))
                        // One element of its own: a label on the selectable Text sent the
                        // first accessibility query round SwiftUI and AppKit until the
                        // stack ran out (#1724, as #71).
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Lines not in the change")
                }
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 6)
        .paperWell(in: RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: makeDocuments)
        .onChange(of: newText) { makeDocuments() }
    }

    @ViewBuilder
    private func half(_ index: Int?, side: DiffLineRow.Side) -> some View {
        if let index {
            DiffLineRow(row: rows[index], document: document(for: rows[index]), side: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.25))
                .accessibilityHidden(true)
        }
    }

    private func document(for row: DiffRow) -> CodeDocument? {
        row.kind == .removed ? oldDocument : newDocument
    }

    private enum Item: Hashable {
        case row(Int)
        case pair(old: Int?, new: Int?)
        case fold(Fold)
        /// Lines between two hunks, not shown, above the row.
        case gap(before: Int)
    }

    /// Rows, closed folds and breaks in order; rows paired side by side when asked.
    private var items: [Item] {
        let folds = Folds.of(rows).filter { !opened.contains($0.range.lowerBound) }
        let breaks = LineDiff.breaks(rows)
        var out: [Item] = []
        out.reserveCapacity(rows.count)
        var run: [Int] = []
        func flush() {
            guard !run.isEmpty else { return }
            if layout == .sideBySide {
                out += LineDiff.sideBySide(run, in: rows).map { .pair(old: $0.old, new: $0.new) }
            } else {
                out += run.map(Item.row)
            }
            run = []
        }
        var index = 0
        var next = folds.makeIterator()
        var fold = next.next()
        while index < rows.count {
            if breaks.contains(index) {
                flush()
                out.append(.gap(before: index))
            }
            if let open = fold, open.range.lowerBound == index {
                flush()
                out.append(.fold(open))
                index = open.range.upperBound
                fold = next.next()
            } else {
                run.append(index)
                index += 1
            }
        }
        flush()
        return out
    }

    private func makeDocuments() {
        let language = CodeLanguage.detect(path: path, firstLine: nil)
        guard let language else { return }
        if let newText {
            let new = CodeDocument(text: newText, language: language)
            new.appear(line: 0)
            newDocument = new
        }
        if let oldText, rows.contains(where: { $0.kind == .removed }) {
            let old = CodeDocument(text: oldText, language: language)
            old.appear(line: 0)
            oldDocument = old
        }
    }
}

/// One line of a `FileDiffView`: its old and new numbers (or one, on its side), its mark,
/// and the code, wrapped.
private struct DiffLineRow: View {
    enum Side { case old, new }

    let row: DiffRow
    let document: CodeDocument?
    /// Which half of a side-by-side row it is; nil in a unified one.
    let side: Side?

    private var index: Int? { row.kind == .removed ? row.oldIndex : row.newIndex }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if side != .new { number(row.oldLine) }
            if side != .old { number(row.newLine) }
            Text(mark)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            CodeLine(text: row.text, spans: index.flatMap { document?.spans(line: $0) } ?? [],
                     changed: row.changed)
                .strikethrough(row.kind == .removed)
                .opacity(row.kind == .removed ? 0.62 : 1)
                .fontWeight(row.kind == .added ? .semibold : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appText(.code)
        .padding(.trailing, 8)
        .padding(.vertical, 1)
        .background(wash)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isStaticText)
        .task(id: document.map(ObjectIdentifier.init)) {
            if let index { document?.appear(line: index) }
        }
    }

    private func number(_ line: Int?) -> some View {
        // A space, not nothing, where a side has no number: an empty text is shorter than a line.
        Text(line.map(String.init) ?? " ")
            .monospacedDigit()
            .foregroundStyle(.quaternary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var wash: AnyShapeStyle {
        switch row.kind {
        case .removed: AnyShapeStyle(CodeInk.removedWash)
        case .added: AnyShapeStyle(CodeInk.changedWash.opacity(0.35))
        case .context: AnyShapeStyle(.clear)
        }
    }

    private var mark: String {
        switch row.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    private var label: String {
        let at = [row.oldLine.map { "old line \($0)" }, row.newLine.map { "new line \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        switch row.kind {
        case .added: return "Added, \(at): \(row.text)"
        case .removed: return "Removed, \(at): \(row.text)"
        case .context: return "\(at): \(row.text)"
        }
    }
}
