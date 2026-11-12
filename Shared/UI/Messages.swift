import AgentsKitCore
import SwiftUI

// The message kinds of docs/reference/design-system.md, "Messages" (#4737), for the window and
// the Remote: a field note, a sheet note, a banner and a toast. An alert is the platform's, and
// a notice or a transcript row is not on the page. A message never pushes the content that
// the person reads or types into: a note keeps its line, a banner moves the pane only when its
// condition starts or ends, and a toast floats.
//
// The tint is on the icon, a banner's 3px bar and its line (Paper v2, #4977). The words are
// `ink`, on `raised` paper; a message never fills its ground with a tint.

extension MessageTone {
    /// The state tint of the icon. Neutral has none.
    var tint: StateTint {
        switch self {
        case .neutral: .none
        case .attention: .attention
        case .failure: .failure
        case .success: .vouched
        }
    }

    /// A banner's line round it: the tone's pale line, or the rule for neutral.
    var line: Color {
        switch self {
        case .neutral: Paper.rule
        case .attention: Paper.lineAttention
        case .failure: Paper.lineFailure
        case .success: Paper.lineVouched
        }
    }
}

/// A message's icon: the tone's symbol (or the one given), in the tone's tint, or secondary
/// for neutral. Hidden from VoiceOver, which reads the words.
struct MessageIcon: View {
    let tone: MessageTone
    var symbol: String?

    var body: some View {
        Image(icon: symbol ?? tone.symbol)
            .foregroundStyle(tone.tint.style(or: Paper.secondary))
            .accessibilityHidden(true)
    }
}

// MARK: Banner

/// A condition of a pane or a page (offline, stale, a read that failed, a limit that is
/// reached, a folder that has gone), across the top of the pane it is about, inset, under the
/// toolbar. Never over the content. The person cannot close it: it goes when the condition
/// ends. At most two actions, as buttons.
struct PaneBanner<Words: View, Actions: View>: View {
    let tone: MessageTone
    var symbol: String?
    /// Work under way (a machine starting): a spinner where the icon is.
    var busy = false
    /// What VoiceOver says when the banner appears.
    let announcement: String
    @ViewBuilder let words: () -> Words
    @ViewBuilder let actions: () -> Actions

    /// The banner's width, which picks one row or two.
    @State var width: CGFloat = .infinity
    /// Under this, the buttons go under the words.
    private static var oneRowWidth: CGFloat { 480 }

    var body: some View {
        // One row; on a narrow pane (the sidebar, a phone) the buttons go under the words,
        // so a row of two sentences and two buttons is not a row of truncations.
        Group {
            if width >= Self.oneRowWidth {
                HStack(alignment: .center, spacing: 10) {
                    icon
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) { actions() }.fixedSize()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        icon
                        text.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 8) { actions() }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .buttonStyle(.paper)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .padding(.leading, tone.tint.color == nil ? 0 : 3)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay(alignment: .leading) {
            // The tone's 3px bar, inset from the corners as the sheet draws it.
            if let bar = tone.tint.color {
                RoundedRectangle(cornerRadius: 1.5).fill(bar).frame(width: 3).padding(.vertical, 8).padding(.leading, 6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(tone.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(announcement).post() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder private var icon: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            MessageIcon(tone: tone, symbol: symbol)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) { words() }
            .appText(.supporting)
            .foregroundStyle(Paper.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension PaneBanner where Words == PaneBannerWords {
    /// A banner of one line, and a second in secondary words when there is one.
    init(tone: MessageTone, symbol: String? = nil, _ line: String, detail: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(tone: tone, symbol: symbol,
                  announcement: [line, detail].compactMap { $0 }.joined(separator: " "),
                  words: { PaneBannerWords(line: line, detail: detail) }, actions: actions)
    }
}

extension PaneBanner where Words == PaneBannerWords, Actions == EmptyView {
    init(tone: MessageTone, symbol: String? = nil, _ line: String, detail: String? = nil) {
        self.init(tone: tone, symbol: symbol, line, detail: detail) { EmptyView() }
    }
}

/// A banner's words: its line, and a detail under it.
struct PaneBannerWords: View {
    let line: String
    let detail: String?

    var body: some View {
        Text(line)
        if let detail, !detail.isEmpty {
            Text(detail).appText(.fine).foregroundStyle(Paper.secondary)
        }
    }
}

extension View {
    /// A banner's inset at the top of its pane.
    func paneBannerInset() -> some View {
        padding(.horizontal, 12).padding(.top, 8)
    }
}

// MARK: Field note and sheet note

/// One field's note: a value that is not correct, or a hint for that field. Under the field,
/// on a line that is always kept, so it moves nothing when it comes or goes. No actions. Show
/// a failure after Submit, not while the person types. VoiceOver reads it as the field's hint:
/// put `.accessibilityHint(text ?? "")` on the field.
///
/// The kept line is one line; longer words (a phone is narrow) wrap to at most three.
struct FieldNote: View {
    var tone: MessageTone = .failure
    let text: String?

    var body: some View {
        Label {
            // A space when there are no words keeps the line.
            Text(text ?? " ")
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            MessageIcon(tone: tone)
        }
        .appText(.fine)
        .foregroundStyle(Paper.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(text == nil ? 0 : 1)
        .accessibilityHidden(text == nil)
    }
}

/// The note of a sheet's or a form's action: it failed, or it is in progress. Beside or above
/// the sheet's buttons, in two lines that are always kept. It goes when the action starts
/// again or the sheet closes.
///
/// `reservesSpace: false` is for a note that is shown only while it has words, where two
/// kept lines would cost more than they save (the phone's start bar, #4739).
struct SheetNote: View {
    var tone: MessageTone = .failure
    let text: String?
    var reservesSpace = true

    var body: some View {
        Label {
            Text(text ?? " ")
                .lineLimit(reservesSpace ? 2 : 4, reservesSpace: reservesSpace)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            if tone == .neutral, text != nil {
                ProgressView().controlSize(.small)
            } else {
                MessageIcon(tone: tone)
            }
        }
        .appText(.fine)
        .foregroundStyle(Paper.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(text == nil ? 0 : 1)
        .accessibilityHidden(text == nil)
        .onChange(of: text) { _, now in
            if let now { AccessibilityNotification.Announcement(now).post() }
        }
    }
}

// MARK: Toast

/// The result of an action the person did outside a sheet: archived, sent, or that it
/// failed. Floats at the bottom centre of the window, above the prompt bar; one at a time.
/// A success goes after 4 seconds, a toast with Undo after 8, and a failure stays until it is
/// closed. The seconds wait while the pointer, the focus or VoiceOver is on it (#1676).
struct Toast<Actions: View>: View {
    let tone: MessageTone
    let text: String
    /// Each toast its own, so a second one starts its seconds again.
    let id: AnyHashable
    /// Whether an action is Undo, which keeps the toast for longer.
    var undo = false
    /// What VoiceOver says when it comes, when that is more than its words.
    var announcement: String?
    let dismiss: () -> Void
    @ViewBuilder let actions: () -> Actions

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AccessibilityFocusState private var focused: Bool
    @State private var hovering = false

    private var held: Bool { voiceOver || focused || hovering }
    private var seconds: Double? { ToastTime.seconds(tone: tone, undo: undo) }

    var body: some View {
        HStack(spacing: 10) {
            MessageIcon(tone: tone)
            Text(text)
                .appText(.supporting)
                .foregroundStyle(Paper.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
                .appText(.supporting)
                .buttonStyle(.borderless)
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
            if seconds == nil {
                Button(action: dismiss) {
                    Image(icon: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close")
                .accessibilityLabel("Close")
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                #endif
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .paperRaised(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityFocused($focused)
        .onHover { hovering = $0 }
        .task(id: id) {
            AccessibilityNotification.Announcement(announcement ?? text).post()
        }
        // The seconds start again when nothing holds the toast.
        .task(id: ToastHold(id: id, held: held)) {
            guard let seconds, !held else { return }
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { dismiss() }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension Toast where Actions == EmptyView {
    init(tone: MessageTone, text: String, id: AnyHashable, dismiss: @escaping () -> Void) {
        self.init(tone: tone, text: text, id: id, dismiss: dismiss) { EmptyView() }
    }
}

private struct ToastHold: Hashable {
    let id: AnyHashable
    let held: Bool
}

/// How far a toast floats above the foot of its pane: the prompt bar's height, so a toast is
/// above it and never over what is typed. The prompt bar says it with `liftsToasts()`.
struct ToastLiftKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// This view is at the foot of the pane, under where a toast floats.
    func liftsToasts() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ToastLiftKey.self, value: proxy.size.height)
        })
    }
}
