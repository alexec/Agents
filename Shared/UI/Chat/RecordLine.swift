import AgentsKitCore
import SwiftUI

/// The one Line (#5036; `specs/session-cards/spec.md`, family 2): the record of what happened,
/// with no box. A glyph, a bold head, a quiet detail and at most one action link at the end.
/// When it has more to show, a click on the words opens it in place, under the words, and a
/// small chevron says so. Red only on a failure's glyph and words (#5016). Tool lines, thoughts,
/// the plan line, notes, notified, a report, the answered Ask's "You chose", and the sandbox and
/// policy records are all drawn with it. The window and the Remote both draw it; the web page's
/// is `Web/src/views/chat/RecordLine.tsx`.
struct RecordLine<More: View>: View {
    enum Tone { case plain, failure }

    /// An SF Symbol's name, drawn as its Lucide icon (`Image(icon:)`, #4976); nil leaves its place empty.
    let icon: String?
    /// Plain words before the head: "You chose".
    var lead: String?
    /// In bold. Nil for a line that is all detail: a tool line, a thought.
    var head: String?
    /// In the quiet colour, after the head.
    var detail: String?
    var tone: Tone = .plain
    /// One line, cut at the end: a tool line, a thought. Anything else wraps.
    var oneLine = false
    /// The one action link at the end of the line: See Policy, Try Again, Steps.
    var action: StripButton?
    /// What a click on the words does instead of opening: a folded run unfolds.
    var onClick: (() -> Void)?
    var clickHelp: String?
    /// What the click says it does, closed and open: "Show the whole thought", "Hide the thought".
    var openHelp: (show: String, hide: String) = ("Show more", "Show less")
    /// Gone to from elsewhere, so opened (#1315). Still closed by a click.
    var isFocused = false
    let more: More
    @State private var isExpanded = false
    @State private var isHovering = false

    init(icon: String?, lead: String? = nil, head: String? = nil, detail: String? = nil, tone: Tone = .plain,
         oneLine: Bool = false, action: StripButton? = nil, onClick: (() -> Void)? = nil, clickHelp: String? = nil,
         openHelp: (show: String, hide: String) = ("Show more", "Show less"), isFocused: Bool = false,
         @ViewBuilder more: () -> More) {
        self.icon = icon
        self.lead = lead
        self.head = head
        self.detail = detail
        self.tone = tone
        self.oneLine = oneLine
        self.action = action
        self.onClick = onClick
        self.clickHelp = clickHelp
        self.openHelp = openHelp
        self.isFocused = isFocused
        self.more = more()
    }

    /// The width of the glyph's place, and the gap after it: what opens is indented by both.
    static var glyphWidth: CGFloat { 16 }
    static var gap: CGFloat { 8 }

    private var opens: Bool { More.self != EmptyView.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
                glyph
                summary
                Spacer(minLength: 0)
                if let action {
                    Button(action.title, action: action.action)
                        .linkStyle()
                        .appText(.reading)
                        .help(action.help ?? "")
                        .disabled(action.disabled)
                        .fixedSize()
                }
            }
            if isExpanded, opens {
                more
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.glyphWidth + Self.gap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isFocused, initial: true) { _, now in if now, opens { isExpanded = true } }
    }

    private var glyph: some View {
        Group {
            if let icon {
                Image(icon: icon)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .appText(.reading)
        .foregroundStyle(tone == .failure ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(.secondary))
        .frame(width: Self.glyphWidth)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var summary: some View {
        if let onClick {
            Button(action: onClick) { words }
                .buttonStyle(.plain)
                .help(clickHelp ?? "")
                .accessibilityHint(clickHelp ?? "")
        } else if opens {
            Button {
                withAnimation(ResponseMotion.response) { isExpanded.toggle() }
            } label: {
                words
            }
            .buttonStyle(.plain)
            .help(isExpanded ? openHelp.hide : openHelp.show)
            .accessibilityHint(isExpanded ? openHelp.hide : openHelp.show)
        } else {
            words
        }
    }

    /// The words, and the chevron when the line opens: brighter under the pointer, as a turn's step is (069).
    private var words: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            text
                .appText(.reading)
                .lineLimit(oneLine ? 1 : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: !oneLine)
                .textSelection(.enabled)
            if opens || onClick != nil {
                Image(icon: "chevron.right")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .onHover { isHovering = (opens || onClick != nil) && $0 }
    }

    /// Lead, bold head, " · ", quiet detail, as one text so it wraps as one sentence. A failure
    /// is red on its main words: the head, or the detail of a line with no head.
    private var text: Text {
        let failure = tone == .failure
        let loud: AnyShapeStyle = failure ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.primary)
        let quiet: AnyShapeStyle = failure && head == nil && lead == nil ? loud
            : isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        var parts: [Text] = []
        if let lead { parts.append(Text(verbatim: lead).foregroundStyle(head == nil ? quiet : loud)) }
        if let head { parts.append(Text(verbatim: head).bold().foregroundStyle(loud)) }
        if let detail, !detail.isEmpty {
            let said = Text(verbatim: detail).foregroundStyle(quiet)
            parts.append(parts.isEmpty ? said : Text("\(Text(verbatim: "\u{00B7}").foregroundStyle(quiet)) \(said)"))
        }
        guard var out = parts.first else { return Text(verbatim: "") }
        for part in parts.dropFirst() { out = Text("\(out) \(part)") }
        return out
    }
}

extension RecordLine where More == EmptyView {
    init(icon: String?, lead: String? = nil, head: String? = nil, detail: String? = nil, tone: Tone = .plain,
         oneLine: Bool = false, action: StripButton? = nil, onClick: (() -> Void)? = nil, clickHelp: String? = nil) {
        self.init(icon: icon, lead: lead, head: head, detail: detail, tone: tone, oneLine: oneLine, action: action,
                  onClick: onClick, clickHelp: clickHelp) { EmptyView() }
    }
}

/// Each line's glyph, as an SF Symbol's name drawn as its Lucide icon (`design/icons.json`).
/// The web page's are `lineGlyph` in `RecordLine.tsx`, by the same Lucide names.
enum LineGlyph {
    /// A tool call by its ACP kind: what it did, not which tool did it.
    static func tool(_ kind: String?) -> String {
        switch kind?.lowercased() {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.right.square"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "fetch": return "globe"
        case "think": return "brain"
        default: return "hammer"
        }
    }

    static func report(_ outcome: WorkOutcome) -> String {
        switch outcome {
        case .done: return "checkmark.circle"
        case .nothingToDo: return "circle.dashed"
        case .needsAnswer: return "questionmark.circle"
        case .waiting: return "pause.circle"
        }
    }

    static func notice(_ notice: SessionNotice) -> String {
        notice.isError ? "exclamationmark.circle" : notice.isWarning ? "exclamationmark.triangle" : "info.circle"
    }

    static let thought = "brain"
    static let plan = "checkmark.square"
    static let notified = "bell"
    static let compaction = "scroll"
    static let asked = "questionmark.bubble"
    static let answered = "arrow.uturn.left"
    static let note = "info.circle"
    static let background = "person.crop.circle.badge.clock"
    static let failed = "xmark.circle"
    static let stopped = "stop.circle"
    static let loadFailure = "exclamationmark.triangle"
}
