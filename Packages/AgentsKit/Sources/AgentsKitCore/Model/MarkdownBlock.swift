import Foundation

/// A piece of a markdown document, once it has been read.
///
/// Splitting blocks is a decision and belongs here where it can be exhausted by tests.
/// What each one looks like is the view's business.
///
/// The reading is Foundation's. `AttributedString(markdown:interpretedSyntax: .full)`
/// is a complete CommonMark parser that ships with the platform, and it returns the
/// nesting ancestry, the list ordinals, the table alignments, the fence languages and
/// the image URLs that a line scanner cannot see. This type folds that into blocks and
/// corrects the three things it gets wrong for us: front matter, task checkboxes, and
/// raw HTML blocks.
///
/// Text payloads are `AttributedString` because the inline marks — emphasis, code
/// spans, link destinations — come out of the same parse. Asking the renderer to parse
/// each paragraph a second time is a second parse that can disagree with the first.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    /// A list, of any depth. Items hold blocks because that is what nesting is: this
    /// repository's own documents run nine levels deep.
    case list(ordered: Bool, start: Int, items: [Item])
    /// Quotes hold blocks too. A quote can contain a list, a heading, another quote.
    case quote([MarkdownBlock])
    case code(language: String?, text: String)
    case table(Table)
    case image(source: String, alt: String)
    case rule

    /// One entry in a list.
    ///
    /// `checked` is nil for an ordinary item. CommonMark has no task lists, so the
    /// checkbox arrives as the literal text `[ ]` and is lifted out here — there are
    /// 2,212 of them in this repository, and every `tasks.md` is made of them.
    public struct Item: Hashable, Sendable {
        public var blocks: [MarkdownBlock]
        public var checked: Bool?

        public init(blocks: [MarkdownBlock], checked: Bool? = nil) {
            self.blocks = blocks
            self.checked = checked
        }
    }

    /// A GitHub-flavoured table: a header row, how each column lines up, and the rows
    /// under it.
    public struct Table: Hashable, Sendable {
        public enum Column: String, Hashable, Sendable {
            case leading, centre, trailing
        }

        public var header: [AttributedString]
        public var columns: [Column]
        public var rows: [[AttributedString]]

        public init(header: [AttributedString], columns: [Column], rows: [[AttributedString]]) {
            self.header = header
            self.columns = columns
            self.rows = rows
        }
    }

    // MARK: Reading

    /// Read markdown into blocks.
    ///
    /// Total: it never throws and never drops a run. Anything Foundation hands back
    /// with no presentation intent is a raw HTML block, and it is shown verbatim rather
    /// than interpreted or discarded.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let source = FrontMatter.strip(markdown)
        guard !source.isEmpty else { return [] }
        guard let read = try? AttributedString(markdown: source, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)) else {
            // Nothing observed has ever reached here — the corpus run over 1,634 files
            // failed zero times — but the whole point of this type is that text does
            // not vanish.
            return [.paragraph(AttributedString(source))]
        }

        let pieces = read.runs.map { run -> Piece in
            let text = AttributedString(String(read[run.range].characters), attributes: marks(of: run))
            return Piece(
                // `components` runs innermost first. Everything below walks outward in,
                // so it is reversed once here rather than indexed backwards everywhere.
                path: (run.presentationIntent?.components ?? []).reversed(),
                text: text,
                image: run.imageURL.map { (source: $0.absoluteString, alt: String(text.characters)) })
        }
        return build(pieces[...], depth: 0)
    }

    /// The inline marks worth carrying, and nothing else.
    ///
    /// A whitelist rather than a few deletions, because the parser leaves working notes
    /// behind: the bullet character a list was written with, the source position of
    /// every run, a flag on the space a soft break turned into. None of them is a mark
    /// anyone should render, and all of them make two identical-looking payloads
    /// unequal, which is the sort of thing that turns a test into a puzzle.
    ///
    /// Soft and hard breaks are dropped because they have already been spent: the
    /// break is the space or the newline in the text, not a note attached to it.
    private static func marks(of run: AttributedString.Runs.Run) -> AttributeContainer {
        var marks = AttributeContainer()
        if var inline = run.inlinePresentationIntent {
            inline.remove(.softBreak)
            inline.remove(.lineBreak)
            if !inline.isEmpty { marks.inlinePresentationIntent = inline }
        }
        if let link = run.link { marks.link = link }
        return marks
    }
}

// MARK: - Folding runs into blocks

/// One run of the parsed string, with its ancestry the right way round.
private struct Piece {
    var path: [PresentationIntent.IntentType]
    var text: AttributedString
    var image: (source: String, alt: String)?
}

private extension MarkdownBlock {
    /// Consecutive pieces sharing an ancestor at this depth are one block. Identity,
    /// not kind: two sibling lists of the same kind are two lists.
    static func build(_ pieces: ArraySlice<Piece>, depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = pieces.startIndex
        while index < pieces.endIndex {
            guard depth < pieces[index].path.count else {
                blocks.append(contentsOf: verbatim(pieces[index]))
                index = pieces.index(after: index)
                continue
            }
            let component = pieces[index].path[depth]
            let end = runEnd(pieces, from: index, depth: depth, identity: component.identity)
            blocks.append(contentsOf: block(component, pieces[index..<end], depth: depth))
            index = end
        }
        return blocks
    }

    static func runEnd(_ pieces: ArraySlice<Piece>, from start: ArraySlice<Piece>.Index,
                       depth: Int, identity: Int) -> ArraySlice<Piece>.Index {
        var end = pieces.index(after: start)
        while end < pieces.endIndex,
              depth < pieces[end].path.count,
              pieces[end].path[depth].identity == identity {
            end = pieces.index(after: end)
        }
        return end
    }

    static func block(_ component: PresentationIntent.IntentType,
                      _ group: ArraySlice<Piece>, depth: Int) -> [MarkdownBlock] {
        switch component.kind {
        case .paragraph:
            return paragraph(group)

        case .header(let level):
            return [.heading(level: level, text: joined(group))]

        case .codeBlock(let languageHint):
            var text = String(joined(group).characters)
            // cmark closes every fence with a newline, including one the file never
            // closed itself. It is a terminator, not a blank last line.
            if text.hasSuffix("\n") { text.removeLast() }
            let language = languageHint?.trimmingCharacters(in: .whitespaces)
            return [.code(language: (language?.isEmpty ?? true) ? nil : language, text: text)]

        case .thematicBreak:
            return [.rule]

        case .blockQuote:
            return [.quote(build(group, depth: depth + 1))]

        case .unorderedList:
            return [.list(ordered: false, start: 1, items: items(group, depth: depth + 1))]

        case .orderedList:
            return [.list(ordered: true, start: firstOrdinal(group, depth: depth + 1),
                          items: items(group, depth: depth + 1))]

        case .table(let columns):
            return [.table(table(columns, group, depth: depth + 1))]

        // Reached only if a row, cell or item turns up without the parent that gives it
        // meaning. Its contents are still content.
        default:
            return build(group, depth: depth + 1)
        }
    }

    /// A paragraph, with any images in it lifted out as blocks of their own. SwiftUI's
    /// `Text` cannot draw an image inside a run, so an image that sits in a paragraph
    /// becomes a sibling of it rather than disappearing (FR-013).
    static func paragraph(_ pieces: ArraySlice<Piece>) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var text = AttributedString()

        func flush() {
            let trimmed = trimmed(text)
            if !trimmed.characters.isEmpty { blocks.append(.paragraph(trimmed)) }
            text = AttributedString()
        }

        for piece in pieces {
            if let image = piece.image {
                flush()
                blocks.append(.image(source: image.source, alt: image.alt))
            } else {
                text.append(piece.text)
            }
        }
        flush()
        return blocks
    }

    static func items(_ pieces: ArraySlice<Piece>, depth: Int) -> [Item] {
        var items: [Item] = []
        var index = pieces.startIndex
        while index < pieces.endIndex {
            guard depth < pieces[index].path.count else {
                index = pieces.index(after: index)
                continue
            }
            let end = runEnd(pieces, from: index, depth: depth,
                             identity: pieces[index].path[depth].identity)
            var blocks = build(pieces[index..<end], depth: depth + 1)
            let checked = takeCheckbox(&blocks)
            items.append(Item(blocks: blocks, checked: checked))
            index = end
        }
        return items
    }

    /// The number the author started an ordered list at. `3.` means three, and
    /// renumbering from one loses what they were counting.
    static func firstOrdinal(_ pieces: ArraySlice<Piece>, depth: Int) -> Int {
        for piece in pieces where depth < piece.path.count {
            if case .listItem(let ordinal) = piece.path[depth].kind { return ordinal }
        }
        return 1
    }

    /// `- [ ] thing` is a list item whose text begins with a checkbox. CommonMark does
    /// not know that, so the brackets arrive as prose and are taken back off here.
    static func takeCheckbox(_ blocks: inout [MarkdownBlock]) -> Bool? {
        guard case .paragraph(var text) = blocks.first else { return nil }
        let markers: [(String, Bool)] = [("[ ]", false), ("[x]", true), ("[X]", true)]
        for (marker, checked) in markers where String(text.characters).hasPrefix(marker) {
            var count = marker.count
            // The space after the box belongs to the box.
            if String(text.characters).dropFirst(count).first == " " { count += 1 }
            let start = text.characters.startIndex
            let end = text.characters.index(start, offsetBy: count)
            text.removeSubrange(start..<end)
            blocks[0] = .paragraph(text)
            return checked
        }
        return nil
    }

    static func table(_ columns: [PresentationIntent.TableColumn],
                      _ pieces: ArraySlice<Piece>, depth: Int) -> Table {
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        var index = pieces.startIndex
        while index < pieces.endIndex {
            guard depth < pieces[index].path.count else {
                index = pieces.index(after: index)
                continue
            }
            let component = pieces[index].path[depth]
            let end = runEnd(pieces, from: index, depth: depth, identity: component.identity)
            let row = cells(pieces[index..<end], depth: depth + 1)
            if case .tableHeaderRow = component.kind { header = row } else { rows.append(row) }
            index = end
        }
        let width = header.count
        return Table(
            header: header,
            columns: columns.map {
                switch $0.alignment {
                case .left: return .leading
                case .center: return .centre
                case .right: return .trailing
                @unknown default: return .leading
                }
            },
            // A ragged row still draws as a rectangle, the way GitHub draws it.
            rows: rows.map { $0.fitted(to: width) })
    }

    static func cells(_ pieces: ArraySlice<Piece>, depth: Int) -> [AttributedString] {
        var cells: [AttributedString] = []
        var index = pieces.startIndex
        while index < pieces.endIndex {
            guard depth < pieces[index].path.count else {
                index = pieces.index(after: index)
                continue
            }
            let end = runEnd(pieces, from: index, depth: depth,
                             identity: pieces[index].path[depth].identity)
            cells.append(trimmed(joined(pieces[index..<end])))
            index = end
        }
        return cells
    }

    /// A block Foundation gave no intent to. That is how raw HTML inside markdown
    /// arrives, and it is shown as it was written — the promise `nothingIsLost` makes.
    static func verbatim(_ piece: Piece) -> [MarkdownBlock] {
        var text = String(piece.text.characters)
        while text.hasSuffix("\n") { text.removeLast() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [.code(language: nil, text: text)]
    }

    static func joined(_ pieces: ArraySlice<Piece>) -> AttributedString {
        var text = AttributedString()
        for piece in pieces { text.append(piece.text) }
        return text
    }

    static func trimmed(_ text: AttributedString) -> AttributedString {
        var text = text
        while let first = text.characters.first, first.isWhitespace {
            text.removeSubrange(text.characters.startIndex..<text.characters.index(after: text.characters.startIndex))
        }
        while let last = text.characters.last, last.isWhitespace {
            text.removeSubrange(text.characters.index(before: text.characters.endIndex)..<text.characters.endIndex)
        }
        return text
    }
}

private extension Array where Element == AttributedString {
    /// GitHub pads a short row and throws away a long one's extra cells.
    func fitted(to count: Int) -> [AttributedString] {
        if self.count == count { return self }
        if self.count > count { return Array(prefix(count)) }
        return self + Array(repeating: AttributedString(), count: count - self.count)
    }
}
