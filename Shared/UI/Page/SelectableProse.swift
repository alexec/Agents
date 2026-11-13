import AgentsKitCore
import CodeText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension EnvironmentValues {
    /// Whether a message's words are drawn as one selectable text, so a drag goes across
    /// its paragraphs, headings, lists and quotes (#5155, the Remote #5181). The chat sets
    /// it; a document page, with its caret and zoom, keeps a `Text` for each block.
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
/// or a part of a reply, and ⌘A selects the message. A message's code is in it too
/// (#5182): its well is drawn behind its lines, its colours come from its language, its
/// long lines wrap, and Run is a view placed under it. Tables and pictures are not in it:
/// they keep their own views (`MarkdownBlock.segments`).
///
/// TextKit 1, as `PassageEditor` is: the height comes from the layout manager, and the
/// quote's bar and the code's well are drawn from the layout.
struct SelectableProse: View {
    let blocks: [MarkdownBlock]
    /// As wide as offered, or as wide as its words (the person's own message).
    let fillsWidth: Bool
    @Environment(\.textZoom) private var zoom
    @Environment(\.lineSpacing) private var lineSpacing
    @Environment(\.quietProse) private var quiet
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.codeRuns) private var codeRuns
    @Environment(\.chatActions) private var actions
    @State private var measure = ProseMeasure()
    @State private var colours = ProseCodeColours()

    var body: some View {
        let style = ProseStyle(zoom: zoom, lineSpacing: lineSpacing, quiet: quiet, dynamicType: dynamicType)
        let sources = ProseCodeSource.of(blocks)
        let commands = codeRuns && actions.runCommand != nil
            ? sources.map { ShellCommand.runnable(tag: $0.language, text: $0.text) } : sources.map { _ in nil }
        let code = ProseCode(spans: colours.spans(sources), commands: commands,
                             barHeight: ProseCode.barHeight(style))
        // Built here, once per change, so the text view and the bars' layout read one text.
        let version = measure.set(ProseMeasure.Key(blocks: blocks, style: style, code: code)) {
            ProseString.make(blocks, style: style, code: code)
        }
        ProseBarsLayout(measure: measure) {
            ProseTextRepresentable(measure: measure, version: version,
                                   fillsWidth: fillsWidth || !sources.isEmpty)
            ForEach(Array(commands.compactMap(\.self).enumerated()), id: \.offset) { _, command in
                RunCommandBar(command: command)
            }
        }
        .onChange(of: sources, initial: true) { colours.sync(sources) }
    }
}

/// The text view itself.
private struct ProseTextRepresentable: NSViewRepresentable {
    let measure: ProseMeasure
    /// Bumped when `measure` holds a new text.
    let version: Int
    let fillsWidth: Bool
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
        context.coordinator.openURL = openURL
        guard context.coordinator.version != version else { return }
        context.coordinator.version = version
        view.textStorage?.setAttributedString(measure.text)
        view.topInset = measure.insets.top
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        let used = measure.size(at: width)
        return CGSize(width: fillsWidth ? width : min(width, used.width), height: used.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var version: Int?
        var openURL: OpenURLAction?

        /// A link opens as the chat's other links do, through the window's openURL (058).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let openURL else { return false }
            openURL(url)
            return true
        }
    }
}

/// The text, and a layout of it apart from the view, so a proposal SwiftUI only asks
/// about does not change the width the view wraps at, and the Run bars can be placed by
/// the code's lines at the width the view is given.
@MainActor
final class ProseMeasure {
    struct Key: Equatable {
        let blocks: [MarkdownBlock]
        let style: ProseStyle
        let code: ProseCode
    }

    private(set) var text = NSAttributedString()
    private var key: Key?
    private var version = 0
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var sizes: [CGFloat: CGSize] = [:]

    init() {
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    /// Takes the text for `key`, made only when the key changed, and says its version.
    func set(_ key: Key, make: () -> NSAttributedString) -> Int {
        guard self.key != key else { return version }
        self.key = key
        text = make()
        storage.setAttributedString(text)
        sizes = [:]
        version += 1
        return version
    }

    /// The room above the first line and below the last one, when the text starts or
    /// ends with code: a paragraph's spacing is not laid before the first line nor after
    /// the last, so the well's padding there is the view's.
    var insets: (top: CGFloat, bottom: CGFloat) {
        guard text.length > 0 else { return (0, 0) }
        let first = text.attribute(.proseCode, at: 0, effectiveRange: nil) as? ProseCodeMark
        let last = text.attribute(.proseCode, at: text.length - 1, effectiveRange: nil) as? ProseCodeMark
        return (first?.top ?? 0, last?.bottom ?? 0)
    }

    func size(at width: CGFloat) -> CGSize {
        if let known = sizes[width] { return known }
        lay(at: width)
        let used = manager.usedRect(for: container)
        let insets = insets
        // Rounded up, and a point more across, so the words wrap at the width they
        // were measured at when the view is given it.
        let size = CGSize(width: ceil(used.width) + 1, height: ceil(used.height + insets.top + insets.bottom))
        sizes[width] = size
        return size
    }

    /// Where each Run bar goes, from the top of the text, in the order of the code.
    func bars(at width: CGFloat) -> [CGFloat] {
        lay(at: width)
        let top = insets.top
        return ProseWells.find(storage, manager, container).compactMap { well in
            well.mark.barHeight > 0 ? top + well.rect.maxY + ProseCodeMark.barGap : nil
        }
    }

    private func lay(at width: CGFloat) {
        if container.size.width != width {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
    }
}

/// The text view first, then the Run bars, each under its code's well.
private struct ProseBarsLayout: Layout {
    let measure: ProseMeasure

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        guard let text = subviews.first else { return }
        text.place(at: bounds.origin, anchor: .topLeading,
                   proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        let ys = MainActor.assumeIsolated { measure.bars(at: bounds.width) }
        for (index, bar) in subviews.dropFirst().enumerated() {
            guard index < ys.count else {
                bar.place(at: bounds.origin, proposal: .zero)
                continue
            }
            bar.place(at: CGPoint(x: bounds.minX, y: bounds.minY + ys[index]), anchor: .topLeading,
                      proposal: .unspecified)
        }
    }
}

/// The read-only text view, which hands its right click to the message's own menu.
final class ProseTextView: NSTextView {
    private var findingMenu = false

    /// The well's padding above code that starts the text (`ProseMeasure.insets`).
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { needsDisplay = true } }
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: 0, y: topInset) }

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

    /// A quote's bar, at the left of its lines, and a code block's well and language,
    /// as the separate views drew them.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer,
              storage.length > 0 else { return }
        let origin = textContainerOrigin
        NSColor.quaternaryLabelColor.setFill()
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
        for well in ProseWells.find(storage, manager, container) {
            let drawn = well.rect.offsetBy(dx: origin.x, dy: origin.y)
            NSColor(Paper.well).setFill()
            NSBezierPath(roundedRect: drawn, xRadius: 8, yRadius: 8).fill()
            if let label = well.mark.label {
                label.draw(at: NSPoint(x: drawn.minX, y: drawn.minY - ProseCodeMark.labelGap - label.size().height))
            }
        }
    }
}

/// Where a code block's well is in a laid-out text: from the top of its first line to
/// the foot of its last, its padding around them, across the whole width.
enum ProseWells {
    struct Well {
        let rect: NSRect
        let mark: ProseCodeMark
    }

    static func find(_ storage: NSTextStorage, _ manager: NSLayoutManager,
                     _ container: NSTextContainer) -> [Well] {
        var wells: [Well] = []
        guard storage.length > 0 else { return wells }
        storage.enumerateAttribute(.proseCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let mark = value as? ProseCodeMark else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var top = CGFloat.infinity
            var bottom = -CGFloat.infinity
            // A line's rect holds the spacing after its paragraph; its used rect does not.
            manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
                top = min(top, rect.minY)
                bottom = max(bottom, used.maxY)
            }
            guard top < bottom else { return }
            let pad = ProseCodeMark.padding
            wells.append(Well(rect: NSRect(x: 0, y: top - pad, width: container.size.width,
                                           height: bottom - top + pad * 2),
                              mark: mark))
        }
        return wells
    }
}

/// One code block in the text, and what is drawn around it. A class, so two code blocks
/// next to each other stay two.
final class ProseCodeMark: NSObject {
    static let padding: CGFloat = 10
    static let labelGap: CGFloat = 4
    static let barGap: CGFloat = 4

    let label: NSAttributedString?
    let labelHeight: CGFloat
    let barHeight: CGFloat

    init(label: NSAttributedString?, barHeight: CGFloat) {
        self.label = label
        labelHeight = label.map { ceil($0.size().height) } ?? 0
        self.barHeight = barHeight
    }

    /// The room above the code's first line: its language, then the well's padding.
    var top: CGFloat { Self.padding + (labelHeight > 0 ? labelHeight + Self.labelGap : 0) }
    /// The room below its last line: the well's padding, then Run.
    var bottom: CGFloat { Self.padding + (barHeight > 0 ? barHeight + Self.barGap : 0) }
}

extension NSAttributedString.Key {
    /// A code block's lines, marked with its `ProseCodeMark`.
    static let proseCode = NSAttributedString.Key("agents.proseCode")
}

/// A code block of the run, by its place among the run's code blocks.
struct ProseCodeSource: Hashable {
    let language: String?
    let text: String

    static func of(_ blocks: [MarkdownBlock]) -> [ProseCodeSource] {
        blocks.compactMap { block in
            guard block.isTextCode, case .code(let language, let text) = block else { return nil }
            return ProseCodeSource(language: language, text: text)
        }
    }
}

/// What the text needs to draw the run's code: the colours found so far, and the
/// command each block runs, in the order of the code blocks.
struct ProseCode: Equatable {
    /// Each code block's spans, line by line; nil while plain.
    var spans: [[[CodeSpan]]?] = []
    var commands: [String?] = []
    var barHeight: CGFloat = 0

    /// The room a Run bar takes: a line of the supporting step, and its button's edges.
    static func barHeight(_ style: ProseStyle) -> CGFloat {
        let font = TextStep.supporting.nsFont(zoom: style.zoom)
        return ceil(font.ascender - font.descender + font.leading) + 6
    }
}

/// The run's code blocks, coloured by their language as `CodeBlockText` colours one: a
/// document each, whose colour arrives a window at a time.
@MainActor @Observable
final class ProseCodeColours {
    private var documents: [CodeDocument?] = []
    @ObservationIgnored private var sources: [ProseCodeSource] = []

    func sync(_ new: [ProseCodeSource]) {
        var next: [CodeDocument?] = []
        for (index, source) in new.enumerated() {
            guard let language = CodeLanguage.fence(tag: source.language) else {
                next.append(nil)
                continue
            }
            let document: CodeDocument
            if index < sources.count, sources[index].language == source.language,
               let known = documents[safe: index] ?? nil {
                // A message still arriving: the block grows as it streams.
                known.update(text: source.text)
                document = known
            } else {
                document = CodeDocument(text: source.text, language: language)
            }
            // A block is short: ask for all of it.
            for line in stride(from: 0, to: document.lines.count, by: Limits.window) {
                document.appear(line: line)
            }
            next.append(document)
        }
        sources = new
        documents = next
    }

    /// Each block's spans, line by line, read so a colour that arrives draws again.
    func spans(_ wanted: [ProseCodeSource]) -> [[[CodeSpan]]?] {
        wanted.indices.map { index in
            guard let document = documents[safe: index] ?? nil, document.plainBecause == nil else { return nil }
            return document.lines.indices.map { document.spans(line: $0) }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

#endif

/// What the words are drawn with, from the environment around them.
struct ProseStyle: Equatable {
    var zoom: CGFloat
    var lineSpacing: CGFloat
    var quiet: Bool
    /// The phone's text size; the Mac's fonts follow its own setting.
    var dynamicType: DynamicTypeSize = .large
}

#if os(macOS)
typealias ProseFont = NSFont
typealias ProseFontDescriptor = NSFontDescriptor
typealias ProseColor = NSColor
typealias ProseUnderline = NSUnderlineStyle
private enum ProseInk {
    static var primary: NSColor { .labelColor }
    static var secondary: NSColor { .secondaryLabelColor }
}
#else
typealias ProseFont = UIFont
typealias ProseFontDescriptor = UIFontDescriptor
typealias ProseColor = UIColor
typealias ProseUnderline = NSUnderlineStyle
private enum ProseInk {
    static var primary: UIColor { .label }
    static var secondary: UIColor { .secondaryLabel }
}
#endif

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
        #if os(macOS)
        /// A code line: the code block it is laid in, and the font of its line end, so
        /// an empty line is as tall as the code's.
        var code: ProseCodeMark?
        var font: ProseFont?
        #endif
    }

    private struct Context {
        var indent: CGFloat = 0
        var bars: [CGFloat] = []
        var secondary = false
    }

    #if os(macOS)
    /// The blocks as one text. A message's own code blocks are in it on the Mac (#5182),
    /// with `code` saying their colours and Run, in the order of the code blocks.
    static func make(_ blocks: [MarkdownBlock], style: ProseStyle, code: ProseCode = ProseCode()) -> NSAttributedString {
        var pieces: [Piece] = []
        var codeIndex = 0
        for block in blocks {
            if block.isTextCode, case .code(let language, let text) = block {
                codeLines(language: language, text: text, spans: code.spans[safe: codeIndex] ?? nil,
                          barHeight: (code.commands[safe: codeIndex] ?? nil) == nil ? 0 : code.barHeight,
                          style, into: &pieces)
                codeIndex += 1
            } else {
                emit([block], Context(secondary: style.quiet), style, into: &pieces)
            }
        }
        return join(pieces, style)
    }
    #else
    static func make(_ blocks: [MarkdownBlock], style: ProseStyle) -> NSAttributedString {
        var pieces: [Piece] = []
        emit(blocks, Context(secondary: style.quiet), style, into: &pieces)
        return join(pieces, style)
    }
    #endif

    private static func join(_ pieces: [Piece], _ style: ProseStyle) -> NSAttributedString {
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
            #if os(macOS)
            if piece.code != nil {
                paragraph.tailIndent = -ProseCodeMark.padding
                paragraph.lineSpacing = 0
            }
            let end: [NSAttributedString.Key: Any] = piece.font.map { [.font: $0] } ?? [:]
            #else
            let end: [NSAttributedString.Key: Any] = [:]
            #endif
            if index < pieces.count - 1 { text.append(NSAttributedString(string: "\n", attributes: end)) }
            let whole = NSRange(location: 0, length: text.length)
            text.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            if !piece.bars.isEmpty { text.addAttribute(.proseQuoteBars, value: piece.bars, range: whole) }
            #if os(macOS)
            if let code = piece.code { text.addAttribute(.proseCode, value: code, range: whole) }
            #endif
            result.append(text)
        }
        return result
    }

    #if os(macOS)
    /// A code block as its lines, each a paragraph in the block's well, coloured by its
    /// spans as `CodeBlockText` colours them: keywords semibold, comments italic.
    private static func codeLines(language: String?, text: String, spans: [[CodeSpan]]?, barHeight: CGFloat,
                                  _ style: ProseStyle, into pieces: inout [Piece]) {
        let font = regular(.code, style)
        let label = language.flatMap { $0.isEmpty ? nil : $0 }.map {
            NSAttributedString(string: $0, attributes: [
                .font: regular(.fine, style), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }
        let mark = ProseCodeMark(label: label, barHeight: barHeight)
        // The well's top: after the block before it, as its spacing.
        if !pieces.isEmpty { pieces[pieces.count - 1].after += mark.top }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let drawn = NSMutableAttributedString(string: String(line), attributes: [
                .font: font, .foregroundColor: ProseInk.primary,
            ])
            let length = drawn.length
            for span in spans?[safe: index] ?? [] {
                let lower = min(max(span.range.lowerBound, 0), length)
                let upper = min(max(span.range.upperBound, 0), length)
                guard lower < upper else { continue }
                drawn.addAttributes(codeAttributes(span.role, font), range: NSRange(location: lower, length: upper - lower))
            }
            var piece = Piece(text: drawn, indent: ProseCodeMark.padding, firstIndent: ProseCodeMark.padding)
            piece.code = mark
            piece.font = font
            pieces.append(piece)
        }
        pieces[pieces.count - 1].after = mark.bottom + blockSpacing
    }

    private static func codeAttributes(_ role: CodeRole, _ font: NSFont) -> [NSAttributedString.Key: Any] {
        guard let ink = codeInks[role] else { return [:] }
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink]
        switch role {
        case .keyword: attributes[.font] = weighted(font, .semibold)
        case .comment: attributes[.font] = italic(font)
        default: break
        }
        return attributes
    }

    /// The code's inks, light and dark, the same as `CodeInk`'s.
    private static let codeInks: [CodeRole: NSColor] = Dictionary(uniqueKeysWithValues:
        CodeRole.allCases.compactMap { role in
            guard let light = InkValues.light[role], let dark = InkValues.dark[role] else { return nil }
            return (role, NSColor(Color(light: light, dark: dark)))
        })
    #endif

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
                    .font: font, .foregroundColor: ProseInk.secondary,
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
    private static func heading(_ level: Int, _ style: ProseStyle) -> ProseFont {
        #if os(macOS)
        let textStyle: NSFont.TextStyle = level <= 1 ? .title1 : level == 2 ? .title2 : .title3
        let font = NSFont.paper(textStyle)
        #else
        let textStyle: UIFont.TextStyle = level <= 1 ? .title1 : level == 2 ? .title2 : .body
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(style.dynamicType))
        let font = UIFont.paper(size: UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits).pointSize)
        #endif
        return weighted(font.withSize(font.pointSize * style.zoom), .semibold)
    }

    /// A block's words with their inline marks: emphasis, strong, code, struck and links.
    private static func inline(_ text: AttributedString, font: ProseFont, _ context: Context,
                               _ style: ProseStyle) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let ink: ProseColor = context.secondary ? ProseInk.secondary : ProseInk.primary
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
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = ProseUnderline.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// The font's family at a weight. By family, not by name, as `UIFont.paper` does: a
    /// variable font's default instance is not its regular one, and drew every word bold.
    private static func weighted(_ font: ProseFont, _ weight: ProseFont.Weight) -> ProseFont {
        guard let family = font.familyName as String? else { return font }
        let descriptor = ProseFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [ProseFontDescriptor.TraitKey.weight: weight],
        ])
        #if os(macOS)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private static func italic(_ font: ProseFont) -> ProseFont {
        #if os(macOS)
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic))
        else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    /// A step's font at its regular weight.
    private static func regular(_ step: TextStep, _ style: ProseStyle) -> ProseFont {
        #if os(macOS)
        weighted(step.nsFont(zoom: style.zoom), .regular)
        #else
        // The phone's step at the text size SwiftUI's environment says, times the zoom.
        let font = step.uiFont(dynamicType: style.dynamicType)
        return style.zoom == 1 ? font : font.withSize(font.pointSize * style.zoom)
        #endif
    }
}

#if os(iOS)

/// Blocks that are only words, drawn as one read-only `UITextView` (#5181), as the Mac
/// draws them as one `NSTextView` (#5155).
///
/// On the phone a selectable `Text` gives only a long press that copies one whole `Text`,
/// one paragraph. In one text view, a long press and the handles select a part of a
/// message across its paragraphs. A long press is then the text view's, not the
/// message's menu, so the message's actions (`MessageMenu`) are in the text view's edit
/// menu, beside Copy.
///
/// TextKit 2. The height is measured apart from the view, at the width SwiftUI offers.
struct SelectableProse: UIViewRepresentable {
    let blocks: [MarkdownBlock]
    /// As wide as offered, or as wide as its words (the person's own message).
    let fillsWidth: Bool
    @Environment(\.textZoom) private var zoom
    @Environment(\.lineSpacing) private var lineSpacing
    @Environment(\.quietProse) private var quiet
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.messageMenu) private var messageMenu

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProseUITextView {
        // The designated init, which runs this class's own: `init(usingTextLayoutManager:)`
        // does not, and left its bars unset. A text view with no container is TextKit 2.
        let view = ProseUITextView(frame: .zero, textContainer: nil)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.delegate = context.coordinator
        view.tintColor = UIColor(Paper.accent)
        view.linkTextAttributes = [.foregroundColor: UIColor(Paper.accent)]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        update(view, context: context)
        return view
    }

    func updateUIView(_ view: ProseUITextView, context: Context) {
        update(view, context: context)
    }

    private func update(_ view: ProseUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.openURL = openURL
        coordinator.menu = messageMenu
        let style = ProseStyle(zoom: zoom, lineSpacing: lineSpacing, quiet: quiet, dynamicType: dynamicType)
        let key = Coordinator.Key(blocks: blocks, style: style)
        guard coordinator.key != key else { return }
        coordinator.key = key
        let text = ProseString.make(blocks, style: style)
        view.attributedText = text
        coordinator.measure(text)
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ProseUITextView,
                      context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        let used = context.coordinator.size(at: width)
        return CGSize(width: fillsWidth ? width : min(width, used.width), height: used.height)
    }

    /// Holds what the view was last given, and measures it apart from the view, so a
    /// proposal SwiftUI only asks about does not change the width the view wraps at.
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        struct Key: Equatable {
            let blocks: [MarkdownBlock]
            let style: ProseStyle
        }

        var key: Key?
        var openURL: OpenURLAction?
        var menu: MessageMenu?
        private let content = NSTextContentStorage()
        private let manager = NSTextLayoutManager()
        private let container = NSTextContainer(size: .zero)
        private var sizes: [CGFloat: CGSize] = [:]

        override init() {
            super.init()
            container.lineFragmentPadding = 0
            manager.textContainer = container
            content.addTextLayoutManager(manager)
        }

        func measure(_ text: NSAttributedString) {
            content.attributedString = text
            sizes = [:]
        }

        func size(at width: CGFloat) -> CGSize {
            if let known = sizes[width] { return known }
            container.size = CGSize(width: width, height: 0)
            manager.ensureLayout(for: manager.documentRange)
            let used = manager.usageBoundsForTextContainer
            // Rounded up, and a point more across, so the words wrap at the width they
            // were measured at when the view is given it.
            let size = CGSize(width: ceil(used.width) + 1, height: ceil(used.height))
            sizes[width] = size
            return size
        }

        /// A link opens as the chat's other links do, through the scene's openURL (058).
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }

        /// The edit menu, with the message's own actions after Copy and Select All.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            ProseEditMenu.make(suggested: suggestedActions, menu: menu,
                               selected: (textView.text as NSString?)?.substring(with: range))
        }
    }
}

/// The edit menu of a message's words: the system's, with the message's actions after its
/// standard edit items (#5181).
@MainActor
enum ProseEditMenu {
    static func make(suggested: [UIMenuElement], menu: MessageMenu?, selected: String?) -> UIMenu {
        guard let menu else { return UIMenu(children: suggested) }
        var own: [UIMenuElement] = [UIAction(title: "Copy Message") { _ in menu.copy() }]
        if let quote = menu.quote {
            // The words selected, as the Mac quotes them (#1553); the message when none are.
            let words = selected.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            own.append(UIAction(title: "Quote in Prompt") { _ in quote(words ?? menu.text) })
        }
        if let branch = menu.branch {
            own.append(UIAction(title: "Branch from Here") { _ in branch() })
        } else if menu.branchGreyed {
            own.append(UIAction(title: "Branch from Here", attributes: .disabled) { _ in })
        }
        let mine = UIMenu(options: .displayInline, children: own)
        var children = suggested
        let edit = children.firstIndex { ($0 as? UIMenu)?.identifier == .standardEdit }
        children.insert(mine, at: edit.map { $0 + 1 } ?? min(1, children.count))
        return UIMenu(children: children)
    }
}

/// The read-only text view. One selection in the chat at a time: a text view that lets go
/// of the focus (a press in another message, the prompt) lets go of its words too.
final class ProseUITextView: UITextView {
    private var bars: [CALayer] = []

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // The bars' ink is resolved for light or dark, so it is set again on a change.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProseUITextView, _) in
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a coder") }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { selectedRange = NSRange(location: 0, length: 0) }
        return resigned
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeQuoteBars()
    }

    /// A quote's bar, at the left of its lines, as the `Text` blocks drew it.
    private func placeQuoteBars() {
        var frames: [CGRect] = []
        if let manager = textLayoutManager, let content = manager.textContentManager, textStorage.length > 0 {
            let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
            textStorage.enumerateAttribute(.proseQuoteBars, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
                guard let xs = value as? [CGFloat], !xs.isEmpty,
                      let start = content.location(content.documentRange.location, offsetBy: range.location),
                      let end = content.location(start, offsetBy: range.length),
                      let textRange = NSTextRange(location: start, end: end) else { return }
                manager.ensureLayout(for: textRange)
                var span = CGRect.null
                manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                    if frame.width > 0 { span = span.union(frame) }
                    return true
                }
                guard !span.isNull else { return }
                for x in xs {
                    frames.append(CGRect(x: origin.x + x, y: origin.y + span.minY, width: 2, height: span.height))
                }
            }
        }
        while bars.count < frames.count {
            let bar = CALayer()
            layer.insertSublayer(bar, at: 0)
            bars.append(bar)
        }
        let ink = UIColor.quaternaryLabel.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.isHidden = index >= frames.count
            if index < frames.count {
                bar.frame = frames[index]
                bar.backgroundColor = ink
            }
        }
        CATransaction.commit()
    }
}
#endif
