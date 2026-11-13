import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension EnvironmentValues {
    /// Whether a message's words are drawn as one selectable text, so a drag goes across
    /// its paragraphs, headings, lists and quotes (#5155). The Mac only, for now: the
    /// Remote keeps a `Text` for each block. The chat sets it; a document
    /// page, with its caret and zoom, keeps a `Text` for each block.
    @Entry var selectsAcrossBlocks = false
    /// The message is the app's, not the person's or the agent's, and its words are drawn
    /// in the secondary ink (`.foregroundStyle(.secondary)` around it), which an AppKit
    /// text view cannot read from SwiftUI.
    @Entry var quietProse = false
}

#if os(macOS)

/// Blocks that are only words, drawn as one read-only `NSTextView` (#5155).
///
/// SwiftUI's selectable `Text` selects inside one `Text` only, so a drag stopped at the
/// end of each paragraph. One text view for the run lets a person select a whole prompt
/// or a part of a reply, and ⌘A selects the message. Code, tables and pictures are not in
/// it: they keep their own views (`MarkdownBlock.segments`).
///
/// TextKit 1, as `PassageEditor` is: the height comes from the layout manager, and the
/// quote's bar is drawn from its line fragments.
struct SelectableProse: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    /// As wide as offered, or as wide as its words (the person's own message).
    let fillsWidth: Bool
    @Environment(\.textZoom) private var zoom
    @Environment(\.lineSpacing) private var lineSpacing
    @Environment(\.quietProse) private var quiet
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProseTextView {
        let view = ProseTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Paper.accent),
            .cursor: NSCursor.pointingHand,
        ]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        update(view, context: context)
        return view
    }

    func updateNSView(_ view: ProseTextView, context: Context) {
        update(view, context: context)
    }

    private func update(_ view: ProseTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.openURL = openURL
        let style = ProseStyle(zoom: zoom, lineSpacing: lineSpacing, quiet: quiet)
        let key = Coordinator.Key(blocks: blocks, style: style)
        guard coordinator.key != key else { return }
        coordinator.key = key
        let text = ProseString.make(blocks, style: style)
        view.textStorage?.setAttributedString(text)
        coordinator.measure(text)
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        let used = context.coordinator.size(at: width)
        return CGSize(width: fillsWidth ? width : min(width, used.width), height: used.height)
    }

    /// Holds what the view was last given, and measures it apart from the view, so a
    /// proposal SwiftUI only asks about does not change the width the view wraps at.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        struct Key: Equatable {
            let blocks: [MarkdownBlock]
            let style: ProseStyle
        }

        var key: Key?
        var openURL: OpenURLAction?
        private let storage = NSTextStorage()
        private let manager = NSLayoutManager()
        private let container = NSTextContainer(size: .zero)
        private var sizes: [CGFloat: CGSize] = [:]

        override init() {
            super.init()
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        func measure(_ text: NSAttributedString) {
            storage.setAttributedString(text)
            sizes = [:]
        }

        func size(at width: CGFloat) -> CGSize {
            if let known = sizes[width] { return known }
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            // Rounded up, and a point more across, so the words wrap at the width they
            // were measured at when the view is given it.
            let size = CGSize(width: ceil(used.width) + 1, height: ceil(used.height))
            sizes[width] = size
            return size
        }

        /// A link opens as the chat's other links do, through the window's openURL (058).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let openURL else { return false }
            openURL(url)
            return true
        }
    }
}

/// What the words are drawn with, from the environment around them.
struct ProseStyle: Equatable {
    var zoom: CGFloat
    var lineSpacing: CGFloat
    var quiet: Bool
}

/// The read-only text view, which hands its right click to the message's own menu.
final class ProseTextView: NSTextView {
    private var findingMenu = false

    /// The message's menu (Copy Message, Quote in Prompt, Branch from Here) is SwiftUI's,
    /// on the views around this one, so it is asked for there. Copy goes first while
    /// some words are selected.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !findingMenu else { return nil }
        findingMenu = true
        defer { findingMenu = false }
        var view = superview
        var found: NSMenu?
        while let next = view, found == nil {
            found = next.menu(for: event)
            view = next.superview
        }
        guard let menu = found ?? super.menu(for: event) else { return nil }
        if selectedRange().length > 0, found != nil,
           !menu.items.contains(where: { $0.action == #selector(copy(_:)) }) {
            let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(copy, at: 0)
        }
        return menu
    }

    /// The text whose words were selected last.
    private static weak var selecting: ProseTextView?

    /// One selection in the chat at a time: a press in another message lets go of the
    /// words selected in this one, also in a window that is not in front.
    override func mouseDown(with event: NSEvent) {
        if let last = Self.selecting, last !== self {
            last.setSelectedRange(NSRange(location: 0, length: 0))
        }
        Self.selecting = self
        super.mouseDown(with: event)
    }

    /// And so does a press anywhere else that takes the focus, such as the prompt.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }

    /// Drawn as SwiftUI's `Text` is, with no font smoothing: smoothed on the dark page,
    /// the same face looked a weight heavier than the words around it.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }

    /// A quote's bar, at the left of its lines, as the `Text` blocks drew it.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let manager = layoutManager, storage.length > 0 else { return }
        NSColor.quaternaryLabelColor.setFill()
        let origin = textContainerOrigin
        storage.enumerateAttribute(.proseQuoteBars, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let bars = value as? [CGFloat], !bars.isEmpty else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var span = NSRect.null
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                span = span.union(used)
            }
            guard !span.isNull else { return }
            for x in bars {
                NSRect(x: origin.x + x, y: origin.y + span.minY, width: 2, height: span.height).fill()
            }
        }
    }
}

extension NSAttributedString.Key {
    /// Where a quote's bars go, as distances from the text's left edge.
    static let proseQuoteBars = NSAttributedString.Key("agents.proseQuoteBars")
}

/// Blocks of words as one attributed string, drawn as `MarkdownText` draws them as
/// separate `Text`s: the same fonts, the same 10 points between blocks and 4 between
/// list items, the list's markers hanging at the left, a quote indented by its bar.
enum ProseString {
    private static let blockSpacing: CGFloat = 10
    private static let itemSpacing: CGFloat = 4
    private static let markerGap: CGFloat = 8
    private static let quoteIndent: CGFloat = 12

    /// One paragraph of the result, before they are joined.
    private struct Piece {
        var text: NSMutableAttributedString
        var indent: CGFloat = 0
        var firstIndent: CGFloat = 0
        var tab: CGFloat?
        var after: CGFloat = 0
        var bars: [CGFloat] = []
    }

    private struct Context {
        var indent: CGFloat = 0
        var bars: [CGFloat] = []
        var secondary = false
    }

    static func make(_ blocks: [MarkdownBlock], style: ProseStyle) -> NSAttributedString {
        var pieces: [Piece] = []
        emit(blocks, Context(secondary: style.quiet), style, into: &pieces)
        let result = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = piece.indent
            paragraph.firstLineHeadIndent = piece.firstIndent
            paragraph.lineSpacing = style.lineSpacing
            paragraph.paragraphSpacing = index == pieces.count - 1 ? 0 : piece.after
            if let tab = piece.tab {
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: tab)]
            }
            let text = piece.text
            if index < pieces.count - 1 { text.append(NSAttributedString(string: "\n")) }
            let whole = NSRange(location: 0, length: text.length)
            text.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            if !piece.bars.isEmpty { text.addAttribute(.proseQuoteBars, value: piece.bars, range: whole) }
            result.append(text)
        }
        return result
    }

    private static func emit(_ blocks: [MarkdownBlock], _ context: Context, _ style: ProseStyle,
                             into pieces: inout [Piece]) {
        for block in blocks {
            switch block {
            case .paragraph(let text):
                pieces.append(piece(inline(text, font: regular(.reading, style), context, style), context))
            case .heading(let level, let text):
                pieces.append(piece(inline(text, font: heading(level, style), context, style), context))
            case .list(let ordered, let start, let items):
                list(ordered: ordered, start: start, items: items, context, style, into: &pieces)
            case .quote(let inner):
                var quoted = context
                quoted.bars.append(context.indent)
                quoted.indent += quoteIndent
                quoted.secondary = true
                emit(inner, quoted, style, into: &pieces)
            case .code, .table, .image, .rule:
                // Not prose: `MarkdownBlock.segments` keeps these out.
                continue
            }
            if !pieces.isEmpty { pieces[pieces.count - 1].after = blockSpacing }
        }
    }

    private static func list(ordered: Bool, start: Int, items: [MarkdownBlock.Item], _ context: Context,
                             _ style: ProseStyle, into pieces: inout [Piece]) {
        let font = regular(.reading, style)
        let markers = items.indices.map { index in marker(ordered: ordered, number: start + index, checked: items[index].checked) }
        let widest = markers.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 0
        let hang = ceil(widest) + markerGap
        for (index, item) in items.enumerated() {
            var inner = context
            inner.indent += hang
            let first = pieces.count
            emit(item.blocks, inner, style, into: &pieces)
            if first < pieces.count {
                let mark = NSMutableAttributedString(string: markers[index] + "\t", attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor,
                ])
                pieces[first].text.insert(mark, at: 0)
                pieces[first].firstIndent = context.indent
                pieces[first].tab = context.indent + hang
                pieces[pieces.count - 1].after = itemSpacing
            }
        }
    }

    private static func marker(ordered: Bool, number: Int, checked: Bool?) -> String {
        if let checked { return checked ? "☑" : "☐" }
        return ordered ? "\(number)." : "•"
    }

    private static func piece(_ text: NSMutableAttributedString, _ context: Context) -> Piece {
        Piece(text: text, indent: context.indent, firstIndent: context.indent, bars: context.bars)
    }

    /// A Markdown heading's font, from the same ladder as `TextStep.heading`.
    private static func heading(_ level: Int, _ style: ProseStyle) -> NSFont {
        let textStyle: NSFont.TextStyle = level <= 1 ? .title1 : level == 2 ? .title2 : .title3
        let font = NSFont.paper(textStyle)
        return weighted(font.withSize(font.pointSize * style.zoom), .semibold)
    }

    /// A block's words with their inline marks: emphasis, strong, code, struck and links.
    private static func inline(_ text: AttributedString, font: NSFont, _ context: Context,
                               _ style: ProseStyle) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let ink: NSColor = context.secondary ? .secondaryLabelColor : .labelColor
        let reading = regular(.reading, style).pointSize
        let kern = style.lineSpacing > 0 ? TextStep.readingTracking * font.pointSize : 0
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var drawn = font
            if intent.contains(.code) {
                let code = regular(.code, style)
                drawn = code.withSize(code.pointSize * font.pointSize / reading)
            }
            if intent.contains(.stronglyEmphasized) { drawn = weighted(drawn, .bold) }
            if intent.contains(.emphasized) { drawn = italic(drawn) }
            var attributes: [NSAttributedString.Key: Any] = [.font: drawn, .foregroundColor: ink]
            if kern > 0 { attributes[.kern] = kern }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// The font's family at a weight. By family, not by name, as `UIFont.paper` does: a
    /// variable font's default instance is not its regular one, and drew every word bold.
    private static func weighted(_ font: NSFont, _ weight: NSFont.Weight) -> NSFont {
        guard let family = font.familyName else { return font }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// A step's font at its regular weight.
    private static func regular(_ step: TextStep, _ style: ProseStyle) -> NSFont {
        weighted(step.nsFont(zoom: style.zoom), .regular)
    }
}
#endif
