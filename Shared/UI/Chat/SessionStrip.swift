import AgentsKitCore
import SwiftUI

/// The Strip family of session cards (#5034, `specs/session-cards/spec.md`, family 1): what is
/// wrong with the session's place, at the top of its chat: the host, the folder, the account,
/// the allowance or the limit. One shows at a time, in that order; "+N more" opens the others
/// under it.
///
/// A strip is on the well, as the Now card is: a glyph, one line and a quiet detail, at most
/// two buttons (the primary on the right) and ⋯ for the rest. The glyph is the warning's orange
/// when something is wrong, never yellow, which is for an Ask (#5016); a state the app works
/// through by itself (a host that is away) has a grey glyph. No colour fills it (Paper v2).
///
/// The web page draws the same in `Web/src/views/Strip.tsx`, with the same words.
enum StripWords {
    static let showLess = "Show less"
    static let moreActions = "More"

    /// "+2 more", the link to the strips under the first.
    static func more(_ count: Int) -> String { "+\(count) more" }
}

/// A strip's glyph: grey for a state the app works through itself, orange for a warning.
enum StripTone {
    case neutral
    case warning

    var tint: StateTint { self == .warning ? .warning : .none }
    var symbol: String { self == .warning ? "exclamationmark.triangle" : MessageTone.neutral.symbol }
}

/// One of a strip's buttons, or a line of its ⋯ menu.
struct StripButton {
    let title: String
    var icon: String?
    var help: String?
    var disabled = false
    let action: () -> Void
}

/// The "+N more" of the first strip in a stack, and the way to open the rest.
struct StripMore {
    let count: Int
    let isOpen: Bool
    let toggle: () -> Void
}

extension EnvironmentValues {
    /// Set on the first strip of a stack that has more than one.
    @Entry var stripMore: StripMore? = nil
}

/// One strip: glyph, line · quiet detail, an accessory (a count of seconds), the second and
/// the primary button, ⋯, and "+N more" on the first of a stack.
struct Strip<Accessory: View>: View {
    let tone: StripTone
    var symbol: String?
    /// Work under way (a machine starting): a spinner where the glyph is.
    var busy = false
    let line: String
    var detail: String?
    var primary: StripButton?
    var second: StripButton?
    var more: [StripButton] = []
    @ViewBuilder let accessory: () -> Accessory

    @Environment(\.stripMore) private var stripMore
    /// The strip's width, which picks one row or two.
    @State private var width: CGFloat = .infinity
    /// Under this, the buttons go under the words (rule 5).
    private static var oneRowWidth: CGFloat { 480 }

    private var words: String { [line, detail].compactMap { $0 }.joined(separator: " · ") }

    var body: some View {
        Group {
            if width >= Self.oneRowWidth {
                HStack(alignment: .center, spacing: 10) {
                    glyph
                    text(lines: 1)
                    controls
                    moreLink
                }
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        glyph
                        text(lines: 3)
                        moreLink
                    }
                    if hasControls {
                        HStack(spacing: 8) { controls }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .buttonStyle(.paper)
        .appText(.supporting)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperWell(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(words).post() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var hasControls: Bool {
        primary != nil || second != nil || !more.isEmpty || Accessory.self != EmptyView.self
    }

    @ViewBuilder private var glyph: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            Image(icon: symbol ?? tone.symbol)
                .foregroundStyle(tone.tint.style(or: Paper.secondary))
                .frame(width: 16)
                .accessibilityHidden(true)
        }
    }

    private func text(lines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line)
                .foregroundStyle(Paper.ink)
                .layoutPriority(1)
            if let detail, !detail.isEmpty {
                Text(" · " + detail)
                    .foregroundStyle(Paper.secondary)
                    .truncationMode(.middle)
            }
        }
        .lineLimit(lines)
        .fixedSize(horizontal: false, vertical: lines > 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(words)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(words)
    }

    @ViewBuilder private var controls: some View {
        accessory()
        if let second {
            button(second).buttonStyle(.paper)
        }
        if let primary {
            button(primary).buttonStyle(.paperProminent)
        }
        if !more.isEmpty {
            Menu {
                ForEach(more.indices, id: \.self) { index in
                    let item = more[index]
                    Button(item.title, action: item.action).disabled(item.disabled)
                }
            } label: {
                Image(icon: "ellipsis")
                    .foregroundStyle(Paper.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(StripWords.moreActions)
        }
    }

    private func button(_ item: StripButton) -> some View {
        Button(item.title, action: item.action)
            .disabled(item.disabled)
            .help(item.help ?? "")
            .fixedSize()
    }

    @ViewBuilder private var moreLink: some View {
        if let stripMore {
            Button(stripMore.isOpen ? StripWords.showLess : StripWords.more(stripMore.count)) {
                withAnimation(ResponseMotion.response) { stripMore.toggle() }
            }
            .buttonStyle(.plain)
            .appText(.fine)
            .foregroundStyle(Paper.accent)
            .fixedSize()
        }
    }
}

extension Strip where Accessory == EmptyView {
    init(tone: StripTone, symbol: String? = nil, busy: Bool = false, line: String, detail: String? = nil,
         primary: StripButton? = nil, second: StripButton? = nil, more: [StripButton] = []) {
        self.init(tone: tone, symbol: symbol, busy: busy, line: line, detail: detail,
                  primary: primary, second: second, more: more) { EmptyView() }
    }
}

/// What can be wrong with a session's place, in the order its strips show (#5034).
enum SessionStripKind: Hashable, CaseIterable {
    case host
    case folder
    case account
    case allowance
    case limit
}

/// A session's strips, one at a time: the first of `kinds`, with "+N more" on it, and the others
/// under it once that is pressed. Nothing when there are none.
struct StripStack<Content: View>: View {
    let kinds: [SessionStripKind]
    @ViewBuilder let strip: (SessionStripKind) -> Content

    @State private var isOpen = false

    var body: some View {
        if let first = kinds.first {
            VStack(spacing: 6) {
                strip(first)
                    .environment(\.stripMore, kinds.count > 1
                        ? StripMore(count: kinds.count - 1, isOpen: isOpen, toggle: { isOpen.toggle() })
                        : nil)
                if isOpen {
                    ForEach(kinds.dropFirst(), id: \.self) { kind in
                        strip(kind)
                    }
                }
            }
            .onChange(of: kinds.count) { _, count in
                if count < 2 { isOpen = false }
            }
        }
    }
}
