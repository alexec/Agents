import CodeText
import SwiftUI

/// A diff drawn as code: unchanged lines once, removed and added lines marked, the words
/// that changed washed, long unchanged runs folded, and all of it coloured by language
/// (041 FR-008 to FR-011).
///
/// Used wherever a change is shown: an edit in the conversation, in the Changes pane and
/// on the phone (through `DiffView`), and a file's Whole file view.
struct CodeRows: View {
    let rows: [DiffRow]
    let language: CodeLanguage?
    /// The two sides' text, parsed for colour: removed lines take theirs from the old text
    /// and everything else from the new, so each is coloured as the code it was part of.
    let oldText: String?
    let newText: String
    /// Line numbers in the file as it stands (Whole file). Edits carry none (FR-013).
    var numbered = false
    /// A lazy stack, for Whole file's thousands of rows. An edit is short, and a plain
    /// stack keeps it measurable inside the conversation's capped block.
    var lazy = false
    /// Which folds are open, by the row each starts at. Held by the caller when it needs
    /// to open one itself (stepping to a change inside it); otherwise here.
    var opened: Binding<Set<Int>>? = nil

    @State private var ownOpened: Set<Int> = []
    @State private var oldDocument: CodeDocument?
    @State private var newDocument: CodeDocument?

    private var openFolds: Set<Int> { opened?.wrappedValue ?? ownOpened }

    var body: some View {
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) { items }
            } else {
                VStack(alignment: .leading, spacing: 0) { items }
            }
        }
        .onAppear {
            if newDocument == nil { makeDocuments() }
        }
        .onChange(of: newText) { newDocument?.update(text: newText) }
        .onChange(of: oldText) {
            if let oldText { oldDocument?.update(text: oldText) }
        }
    }

    @ViewBuilder
    private var items: some View {
        ForEach(visible, id: \.self) { item in
            switch item {
            case .row(let index):
                DiffRowView(row: rows[index], numbered: numbered,
                            document: rows[index].kind == .removed ? oldDocument : newDocument)
                    .id(index)
            case .fold(let fold):
                FoldRow(count: fold.range.count) { open(fold) }
                    .id(fold.range.lowerBound)
            }
        }
    }

    private enum Item: Hashable {
        case row(Int)
        case fold(Fold)
    }

    /// Rows and closed folds, in order.
    private var visible: [Item] {
        let closed = Folds.of(rows).filter { !openFolds.contains($0.range.lowerBound) }
        var items: [Item] = []
        items.reserveCapacity(rows.count)
        var index = 0
        var folds = closed.makeIterator()
        var next = folds.next()
        while index < rows.count {
            if let fold = next, fold.range.lowerBound == index {
                items.append(.fold(fold))
                index = fold.range.upperBound
                next = folds.next()
            } else {
                items.append(.row(index))
                index += 1
            }
        }
        return items
    }

    private func open(_ fold: Fold) {
        if let opened {
            opened.wrappedValue.insert(fold.range.lowerBound)
        } else {
            ownOpened.insert(fold.range.lowerBound)
        }
    }

    private func makeDocuments() {
        guard let language else { return }
        let new = CodeDocument(text: newText, language: language)
        new.appear(line: 0)
        newDocument = new
        if let oldText, rows.contains(where: { $0.kind == .removed }) {
            let old = CodeDocument(text: oldText, language: language)
            old.appear(line: 0)
            oldDocument = old
        }
    }
}

/// One diff line: its mark, its number if it has one, and the code.
private struct DiffRowView: View {
    let row: DiffRow
    let numbered: Bool
    let document: CodeDocument?

    private var index: Int? { row.kind == .removed ? row.oldIndex : row.newIndex }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if numbered {
                // A space, not nothing, where a removed line has no number: an empty text
                // is shorter than a line and opened a gap under every removed one (035).
                Text(row.newLine.map(String.init) ?? " ")
                    .frame(width: 40, alignment: .trailing)
                    .foregroundStyle(.quaternary)
            }
            Text(mark)
                .foregroundStyle(.tertiary)
            CodeLine(text: row.text, spans: index.flatMap { document?.spans(line: $0) } ?? [],
                     changed: row.changed)
                // By mark, strike and weight, never by red and green (035 FR-013).
                .strikethrough(row.kind == .removed)
                .opacity(row.kind == .removed ? 0.62 : 1)
                .fontWeight(row.kind == .added ? .semibold : nil)
        }
        // One element per line, read as "Added: …" or "Removed: …". A second label laid
        // over `CodeLine`'s own sent AppKit's accessibility into a stack overflow when the
        // row was queried (walked 2026-09-25), so the row speaks for its children.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isStaticText)
        .appText(.code)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(row.kind == .removed ? AnyShapeStyle(CodeInk.removedWash) : AnyShapeStyle(.clear))
        .onAppear {
            if let index { document?.appear(line: index) }
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
        switch row.kind {
        case .added: "Added: \(row.text)"
        case .removed: "Removed: \(row.text)"
        case .context: String(row.text)
        }
    }
}
