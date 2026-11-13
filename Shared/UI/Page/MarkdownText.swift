import AgentsKitCore
import CodeText
import SwiftUI

/// Markdown, drawn, the same on the Mac and the phone (034).
///
/// Used twice: for what an agent said in the conversation, and for a document on a
/// live page. The blocks are split in AgentsKitCore, where tests can reach the
/// decision; what each one looks like is here. There were two of these, one per app,
/// and they had drifted: the phone's drew no pictures and no caret, the Mac's had never
/// been told a paragraph must not be cut off at a narrow width. This is both.
///
/// Inline marks arrive as attributes on the text, from the same parse that found the
/// blocks. Nothing here parses anything: the reading is remembered by its text.
extension EnvironmentValues {
    /// Whether text takes the width it is offered or only the width it needs. The
    /// person's own message hugs its words, at the right of the chat.
    @Entry var textFillsWidth = true
    /// Whether a shell's code block offers Run (#1533): set on an agent's reply only.
    @Entry var codeRuns = false
    /// Whether a table or a code block may reach past the text into the column's
    /// margins (#3895): set on an agent's reply only, whose margins are the chat's.
    @Entry var widensBlocks = false
    /// How far the chat's column leaves either side of it, inside the pane's padding
    /// (`ChatMetrics.surplus`): set by the transcript, for the pane it is in.
    @Entry var chatSurplus: Double = 0
}

struct MarkdownText: View {
    @Environment(\.textFillsWidth) private var fillsWidth
    @Environment(\.codeRuns) private var codeRuns
    @Environment(\.widensBlocks) private var widensBlocks
    @Environment(\.chatSurplus) private var chatSurplus
    /// A page's zoom (#1419), which headings take as the steps do.
    @Environment(\.textZoom) private var zoom
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.selectsAcrossBlocks) private var selectsAcross
    let markdown: String
    /// The document's own location, when there is one, so a relative image can be
    /// found. Nil in the conversation, where there is no document to be relative to —
    /// and an image then shows its alternative text rather than being fetched (FR-013).
    var base: URL?
    /// Somebody's caret, drawn after the last character with their name above it. Only
    /// a live page passes one, for the passage an agent is typing into; everywhere else
    /// this is nil and the text is drawn as it always was.
    var caret: CursorFlag?
    /// Only these of its blocks: the chat draws a long reply as rows of a few blocks each,
    /// so only those near the screen are laid out (P20261022-18).
    var range: Range<Int>?
    /// Where an image on the network is read from, on a forge's page only (#4010): through
    /// the machine's `forge/image`, never by the app. Nil everywhere else, where a remote
    /// image stays its alternative text, so documents and the chat do not change.
    var remoteImage: RemoteImageLoader?
    /// The images this text opens large, which the viewer goes through (#4954).
    @State private var gallery = ImageGallery()

    var body: some View {
        Group {
            if caret != nil {
                content.textRenderer(CaretFlagRenderer())
            } else {
                content
            }
        }
        .environment(\.imageSequence, sequence)
    }

    /// A forge page's images, in their order, for the viewer; nil where no image opens large.
    private var sequence: ImageSequenceScope? {
        guard remoteImage != nil else { return nil }
        let order = ImageSequence.sources(in: MarkdownBlock.parsed(markdown)).compactMap(ForgeMarkdown.imageURL(of:))
        return ImageSequenceScope(gallery: gallery, order: order)
    }

    private var content: AnyView {
        // Read once per text, not once per redraw (#90).
        let parsed = MarkdownBlock.parsed(markdown)
        // A passage whose first characters have not arrived yet — nothing, or a `#` that
        // is not a heading until its text follows — is still somewhere the caret is.
        if parsed.isEmpty, let caret { return AnyView(caret.caret) }
        if let range {
            let shown = range.clamped(to: parsed.indices)
            return blocks(Array(parsed[shown]), caret: shown.upperBound == parsed.count ? caret : nil, top: true)
        }
        return blocks(parsed, caret: caret, top: true)
    }

    /// Erased on purpose, and this is the only place it is.
    ///
    /// Blocks nest — a list item holds blocks, a quote holds blocks — so this calls
    /// `view(for:)` and `view(for:)` calls it back. Two mutually recursive `some View`
    /// functions define their opaque types in terms of themselves and do not compile.
    /// One concrete type in the cycle breaks it. A document is tens of blocks, not
    /// thousands, so the cost is not worth a cleverer shape.
    /// `top` is the message's own blocks, not those inside a list item or a quote, which
    /// keep a `Text` each: their marker or bar is set by the first line's baseline.
    private func blocks(_ blocks: [MarkdownBlock], caret: CursorFlag? = nil, top: Bool = false) -> AnyView {
        AnyView(stack(blocks, caret: caret, top: top))
    }

    @ViewBuilder
    private func stack(_ blocks: [MarkdownBlock], caret: CursorFlag?, top: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if selectsAcross, top, caret == nil {
                // The words between code, tables and pictures as one text, so a drag
                // selects across paragraphs (#5155).
                ForEach(MarkdownBlock.segments(blocks, code: Self.codeInText), id: \.self) { segment in
                    switch segment {
                    case .prose(let range):
                        SelectableProse(blocks: Array(blocks[range]), fillsWidth: fillsWidth)
                    case .block(let index):
                        view(for: blocks[index], caret: nil)
                    }
                }
            } else {
                each(blocks, caret: caret)
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }

    private func each(_ blocks: [MarkdownBlock], caret: CursorFlag?) -> some View {
        // Indexed, not keyed by content. Two identical paragraphs are two
        // paragraphs, and a document with two horizontal rules used to hand
        // `ForEach` the same id twice.
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            // The caret is at the end of the text, so it goes to the last block and
            // down into whatever that block holds last.
            view(for: block, caret: index == blocks.count - 1 ? caret : nil)
        }
    }

    /// A fenced or indented block of code, coloured by its tag.
    private func codeBlock(language: String?, text: String, caret: CursorFlag?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language).appText(.fine).foregroundStyle(.tertiary)
            }
            // Code keeps its own shape, so it scrolls rather than wraps.
            Sideways {
                // Coloured by its tag, in the same inks as files and diffs (041 US4).
                CodeBlockText(text: text, language: CodeLanguage.fence(tag: language),
                              caret: caret)
                    .appText(.code)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .paperWell(in: RoundedRectangle(cornerRadius: 8))
            if codeRuns, caret == nil, let command = ShellCommand.runnable(tag: language, text: text) {
                RunCommandBar(command: command)
            }
        }
        .modifier(Overhang(surplus: overhang))
    }

    /// How far a wide block may reach past the text either side (#3895).
    private var overhang: Double { widensBlocks ? chatSurplus : 0 }

    @ViewBuilder
    private func view(for block: MarkdownBlock, caret: CursorFlag?) -> some View {
        switch block {
        case .paragraph(let text):
            self.text(text, caret: caret).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .linkPointer(text)

        case .heading(let level, let text):
            // Not a step of the scale: `TextStep.heading` says why, and resolves the
            // ladder once for both apps. The consistency check allows it by name.
            self.text(text, caret: caret)
                .font(TextStep.heading(level: level, zoom: zoom, dynamicType: dynamicType))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .linkPointer(text)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + index, checked: item.checked)
                        // An item holds blocks, because that is what nesting is.
                        blocks(item.blocks, caret: index == items.count - 1 ? caret : nil)
                    }
                }
            }
            .textSelection(.enabled)

        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().frame(width: 2).foregroundStyle(.quaternary)
                blocks(inner, caret: caret).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)

        case .code(let language, let text) where MermaidDiagram.isFence(language) && caret == nil:
            // A Mermaid fence is its diagram (#853). While an agent types into it, it is
            // its code, with the caret, until the fence is finished.
            MermaidFence(text: text) { codeBlock(language: language, text: text, caret: caret) }

        case .code(let language, let text):
            codeBlock(language: language, text: text, caret: caret)

        case .image(let source, let alt):
            trailed(image(source: source, alt: alt), by: caret)

        case .table(let table):
            // A short column keeps its width and a column of sentences wraps, so the
            // table fits the room; only one too wide at its least scrolls (#3943).
            trailed(MarkdownTable(table: table, surplus: overhang)
                .textSelection(.enabled), by: caret)

        case .rule:
            trailed(Divider(), by: caret)
        }
    }

    /// A block's text, with the caret after its last character when there is one.
    private func text(_ text: AttributedString, caret: CursorFlag?) -> Text {
        let drawn = Text.markingLinks(text)
        guard let caret else { return drawn }
        return Text("\(drawn)\(caret.caret)")
    }

    /// A block that is not text — a picture, a table, a rule — with the caret on the
    /// line after it, which is where the next character typed would go.
    @ViewBuilder
    private func trailed<Content: View>(_ content: Content, by caret: CursorFlag?) -> some View {
        if let caret {
            VStack(alignment: .leading, spacing: 4) {
                content
                caret.caret
            }
        } else {
            content
        }
    }

    /// What goes in front of a list item: a number, a box, or a bullet.
    ///
    /// The box is drawn and never tapped. The pane is read-only, and a checkbox that
    /// looks pressable but is not would be a worse lie than one that plainly is not.
    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(icon: checked ? "checkmark.square" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if ordered {
            Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
        } else {
            Text("•").foregroundStyle(.secondary)
        }
    }

    /// An image in a document, found beside the document.
    ///
    /// A file beside the document, inside its folder tree, and nothing else: no
    /// address on the network and no path that climbs out (022 FR-019). Nothing here
    /// makes a network request on a document's behalf (FR-011), so a remote image is
    /// its alternative text — which is what alternative text is for. How the file is
    /// read is the app's: the Mac's disk, or the phone asking the Mac.
    ///
    /// A forge's page is the one exception (#4010): its `remoteImage` asks the machine that
    /// read the page for an https image, and a click opens it in the image viewer. An image that
    /// is a link is never here: it is the link's words, whose click follows the link (#4954).
    @ViewBuilder
    private func image(source: String, alt: String) -> some View {
        if let base, let url = ImageStamps.url(of: source, base: base) {
            PagePicture(url: url, source: source, alt: alt)
        } else if let remoteImage, let url = ForgeMarkdown.imageURL(of: source) {
            PagePicture(url: url, source: source, alt: alt, remote: remoteImage)
        } else {
            PictureAlternative(source: source, alt: alt)
        }
    }

    /// Whether a message's code goes in its one text too, so a drag goes from a paragraph
    /// into the code (#5182). The Mac's text view draws the code's well, colours and Run;
    /// the Remote's keeps each code block apart.
    #if os(macOS)
    private static let codeInText = true
    #else
    private static let codeInText = false
    #endif

    /// Lists sit a little looser on a touch screen, where a line is a target.
    #if os(macOS)
    private static let itemSpacing: CGFloat = 4
    #else
    private static let itemSpacing: CGFloat = 6
    #endif
}

/// A link's words, marked so the laid-out text can say where they are (#515).
private struct LinkRun: TextAttribute {}

private extension Text {
    /// The text, with each link's words marked. Text with no link is drawn as it was.
    static func markingLinks(_ text: AttributedString) -> Text {
        let runs = text.runs[\.link]
        guard runs.contains(where: { $0.0 != nil }) else { return Text(text) }
        return runs.reduce(Text(verbatim: "")) { drawn, run in
            let part = Text(AttributedString(text[run.1]))
            return Text("\(drawn)\(run.0 == nil ? part : part.customAttribute(LinkRun()))")
        }
    }
}

private extension View {
    /// The hand over a link, on the Mac (#515). Selectable text shows the I-beam
    /// everywhere, links included, so a link did not look like one until clicked.
    /// Only text holding a link pays for the hover.
    @ViewBuilder
    func linkPointer(_ text: AttributedString) -> some View {
        #if os(macOS)
        if text.runs[\.link].contains(where: { $0.0 != nil }) {
            modifier(LinkPointer())
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Where the links are in a laid-out text, and the hand while the pointer is on one.
private struct LinkPointer: ViewModifier {
    @State private var links: [CGRect] = []
    @State private var overLink = false

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    let found = Self.links(in: layouts, proxy)
                    Color.clear.onChange(of: found, initial: true) { links = found }
                }
            }
            .onContinuousHover { phase in
                // Set on every move, not asked for with `.pointerStyle`: the selectable
                // text's own view puts its I-beam back over a pointer style (#757).
                switch phase {
                case .active(let point):
                    let over = links.contains { $0.contains(point) }
                    if over {
                        NSCursor.pointingHand.set()
                    } else if overLink {
                        NSCursor.iBeam.set()
                    }
                    overLink = over
                case .ended:
                    overLink = false
                }
            }
    }

    private static func links(in layouts: Text.LayoutKey.Value, _ proxy: GeometryProxy) -> [CGRect] {
        layouts.flatMap { anchored in
            let origin = proxy[anchored.origin]
            return anchored.layout.flatMap { line in
                line.filter { $0[LinkRun.self] != nil }
                    .map { $0.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y) }
            }
        }
    }
}
#endif

/// A block that may be wider than the column it is in (#3895): as wide as it needs,
/// up to the column and the margin either side of it. It starts where the text starts
/// and grows to the right; only when the right margin runs out does it slide left into
/// the other. The column still reports its own width, so the rows around it do not
/// move. With no surplus, it is the block as it was.
private struct Overhang: ViewModifier {
    let surplus: Double

    func body(content: Content) -> some View {
        if surplus > 0 {
            OverhangLayout(surplus: surplus) { content }
        } else {
            content
        }
    }
}

private struct OverhangLayout: Layout {
    let surplus: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let block = subviews.first else { return .zero }
        guard let column = proposal.width, column.isFinite else {
            return block.sizeThatFits(proposal)
        }
        let wide = width(block.sizeThatFits(.unspecified).width, column)
        let height = block.sizeThatFits(ProposedViewSize(width: wide, height: proposal.height)).height
        return CGSize(width: column, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        guard let block = subviews.first else { return }
        let column = bounds.width
        let wide = width(block.sizeThatFits(.unspecified).width, column)
        let slide = max(0, wide - column - surplus)
        block.place(at: CGPoint(x: bounds.minX - slide, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: wide, height: bounds.height))
    }

    /// At least the column, so a narrow block draws as it did; at most the column and
    /// both margins, past which it scrolls.
    private func width(_ natural: Double, _ column: Double) -> Double {
        min(max(natural, column), column + surplus * 2)
    }
}

/// A Markdown table (#3943): each column as wide as its widest cell while the table
/// fits, and a column of sentences wrapped when it does not (`TableColumns`). In an
/// agent's reply the room is the column and the margins either side of it (#3895).
/// Only a table too wide at its least scrolls, as every wide table did before.
private struct MarkdownTable: View {
    let table: MarkdownBlock.Table
    let surplus: Double

    var body: some View {
        // The first fits when its columns at their least fit; its width with no
        // proposal is that least, so the test is the right one.
        ViewThatFits(in: .horizontal) {
            TableLayout(columns: count, surplus: surplus, scrolls: false) { cells }
            ScrollView(.horizontal, showsIndicators: false) {
                TableLayout(columns: count, surplus: 0, scrolls: true) { cells }
            }
        }
        .padding(2)
    }

    /// Every row has a cell for each column, so a short row is drawn with blanks.
    private var count: Int { max(table.header.count, table.rows.map(\.count).max() ?? 0) }

    @ViewBuilder
    private var cells: some View {
        ForEach(0..<count, id: \.self) { index in
            cell(table.header[safe: index]).fontWeight(.semibold)
                .multilineTextAlignment(alignment(index).text)
                .layoutValue(key: TableColumn.self, value: alignment(index).column)
        }
        // Drawn, not a `Divider`, which takes its direction from a stack and this is none.
        Rectangle().fill(.quaternary).frame(height: 1)
        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
            ForEach(0..<count, id: \.self) { index in
                cell(row[safe: index])
                    .multilineTextAlignment(alignment(index).text)
                    .layoutValue(key: TableColumn.self, value: alignment(index).column)
            }
        }
    }

    private func cell(_ text: AttributedString?) -> some View {
        Text.markingLinks(text ?? AttributedString()).appText(.supporting)
            .linkPointer(text ?? AttributedString())
    }

    /// What the dashes under the header said about this column.
    private func alignment(_ index: Int) -> (text: TextAlignment, column: HorizontalAlignment) {
        guard table.columns.indices.contains(index) else { return (.leading, .leading) }
        switch table.columns[index] {
        case .leading: return (.leading, .leading)
        case .centre: return (.center, .center)
        case .trailing: return (.trailing, .trailing)
        }
    }
}

/// Where a cell sits in its column.
private struct TableColumn: LayoutValueKey {
    static let defaultValue: HorizontalAlignment = .leading
}

/// The header's cells, a rule, then each row's cells, `columns` to a row.
///
/// Given a width, the columns share it and the margins either side (`surplus`), starting
/// where the text starts and sliding left only when the right margin runs out, as
/// `Overhang` does for code. With none, it is as narrow as it can be: that is what lets
/// `ViewThatFits` choose it, and, scrolled, it is drawn at that.
private struct TableLayout: Layout {
    let columns: Int
    let surplus: Double
    let scrolls: Bool

    private static let across: Double = 18
    private static let down: Double = 6

    struct Plan {
        var widths: [Double]
        var rows: [Double]
        var rule: Double
        var total: Double { widths.reduce(0, +) + TableLayout.across * Double(max(0, widths.count - 1)) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard columns > 0 else { return .zero }
        let plan = plan(proposal.width.map(Double.init), subviews)
        let height = plan.rows.reduce(0, +) + plan.rule + Self.down * Double(plan.rows.count)
        if let width = proposal.width, width.isFinite, !scrolls {
            return CGSize(width: width, height: height)
        }
        // Unproposed: the least it takes, less the margins it may reach into.
        return CGSize(width: max(0, plan.total - (scrolls ? 0 : surplus * 2)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        guard columns > 0 else { return }
        let plan = plan(scrolls ? nil : Double(bounds.width), subviews)
        let slide = scrolls ? 0 : min(surplus, max(0, plan.total - bounds.width - surplus))
        var y = bounds.minY
        for (row, height) in plan.rows.enumerated() {
            var x = bounds.minX - slide
            for column in 0..<columns {
                let cell = subviews[index(row: row, column: column)]
                let width = plan.widths[column]
                let (dx, anchor): (Double, UnitPoint) = switch cell[TableColumn.self] {
                case .center: (width / 2, .top)
                case .trailing: (width, .topTrailing)
                default: (0, .topLeading)
                }
                cell.place(at: CGPoint(x: x + dx, y: y), anchor: anchor,
                           proposal: ProposedViewSize(width: width, height: nil))
                x += width + Self.across
            }
            y += height + Self.down
            if row == 0 {
                subviews[columns].place(at: CGPoint(x: bounds.minX - slide, y: y), anchor: .topLeading,
                                        proposal: ProposedViewSize(width: plan.total, height: plan.rule))
                y += plan.rule + Self.down
            }
        }
    }

    /// The header is subviews `0..<columns`, the rule is `columns`, and row `n` (from
    /// 1) follows it.
    private func index(row: Int, column: Int) -> Int {
        row == 0 ? column : columns + 1 + (row - 1) * columns + column
    }

    private func plan(_ width: Double?, _ subviews: Subviews) -> Plan {
        let count = (subviews.count - 1) / columns
        var natural = [Double](repeating: 0, count: columns)
        for row in 0..<count {
            for column in 0..<columns {
                let size = subviews[index(row: row, column: column)].sizeThatFits(.unspecified)
                natural[column] = max(natural[column], Double(size.width))
            }
        }
        let gaps = Self.across * Double(max(0, columns - 1))
        let widths = if let width, width.isFinite {
            TableColumns.widths(natural: natural, room: width + surplus * 2 - gaps)
        } else {
            TableColumns.least(natural)
        }
        let rows = (0..<count).map { row in
            (0..<columns).map { column in
                subviews[index(row: row, column: column)]
                    .sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
            }.map(Double.init).max() ?? 0
        }
        let rule = Double(subviews[columns].sizeThatFits(ProposedViewSize(width: nil, height: nil)).height)
        return Plan(widths: widths, rows: rows, rule: rule)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Content that scrolls sideways when it is wider than the column, and is simply drawn
/// when it is not (#90).
///
/// The same to look at either way: a scroll view takes the whole width offered, so the
/// narrow case is held to it too. Most code and tables an agent writes fit, and a
/// scroll view each was a platform view every redraw of the chat had to visit.
private struct Sideways<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
    }
}

/// A picture on the page, read through the app (034).
///
/// Loaded once per identity. The page gives a passage a new identity when its
/// picture's file changes, which is what makes this read it again.
///
/// A forge page's picture (`remote`, #4010) is asked for once, shows its alternative text
/// while it loads and when it cannot be read, is never drawn larger than it is, and opens
/// in the image viewer when clicked, with the page's other images to go through (#4954). A
/// small one (a logo, a badge) does not open.
private struct PagePicture: View {
    @Environment(\.pageActions) private var actions
    @Environment(\.imageSequence) private var sequence
    let url: URL
    let source: String
    let alt: String
    var remote: RemoteImageLoader?

    @State private var loaded: PlatformImage?
    @State private var tried = false
    @State private var viewed: ViewedImage?

    var body: some View {
        Group {
            if let loaded, remote != nil, opensLarge(loaded) {
                Button { open(loaded) } label: {
                    drawn(loaded).frame(maxWidth: loaded.size.width)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint("Opens the image")
                #if os(macOS)
                .pointerStyle(.link)
                #endif
                .imageViewer($viewed)
            } else if let loaded, remote != nil {
                drawn(loaded).frame(maxWidth: loaded.size.width)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let loaded {
                drawn(loaded).frame(maxWidth: .infinity, alignment: .leading)
            } else if tried || remote != nil {
                PictureAlternative(source: source, alt: alt)
            } else {
                // Held open while it loads, so the words below do not jump twice.
                Color.clear.frame(height: 24)
            }
        }
        .task(id: url) {
            if let remote {
                loaded = await remote(url)
                tried = true
                if let loaded, opensLarge(loaded) {
                    sequence?.gallery.add(url, ViewedImage.Item(image: loaded, alt: alt))
                }
                return
            }
            // Asked more than once: on a phone a picture is drawn by WebKit, and a
            // drawing that failed the first time can come out the second (034). On the
            // Mac a missing file is simply missing, and asking again costs a stat.
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
                guard !Task.isCancelled else { return }
                loaded = await actions.image(url)
                if loaded != nil { break }
            }
            tried = true
        }
    }

    private func opensLarge(_ image: PlatformImage) -> Bool {
        ImageSequence.opensLarge(width: image.size.width, height: image.size.height)
    }

    /// The viewer, at this image, with the page's other images read so far.
    private func open(_ image: PlatformImage) {
        viewed = sequence?.gallery.viewed(at: url, order: sequence?.order ?? [url])
            ?? ViewedImage(images: [ViewedImage.Item(image: image, alt: alt)], start: 0)
    }

    private func drawn(_ image: PlatformImage) -> some View {
        Image(platformImage: image)
            .resizable()
            .scaledToFit()
            .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    }
}

/// Reads an image on the network for a page, through the machine (#4010); nil when it
/// cannot, and the page shows the image's alternative text.
typealias RemoteImageLoader = @MainActor (URL) async -> PlatformImage?

/// A picture that cannot be drawn: its alternative text, or its name.
private struct PictureAlternative: View {
    let source: String
    let alt: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(icon: "photo").foregroundStyle(.tertiary)
            Text(alt.isEmpty ? URL(string: source)?.lastPathComponent ?? source : alt)
                .foregroundStyle(.secondary)
        }
        .appText(.supporting)
    }
}
