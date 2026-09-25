import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One passage of a live page, open for typing.
///
/// A plain text editor over that passage's Markdown source, in the page's own face and
/// at its own width, so that opening it moves nothing: the words stay where they were
/// and a caret appears among them. Only one passage is ever open, and it holds only
/// its own source — which is what makes an agent's write elsewhere in the file cheap
/// to absorb: the rest of the page re-renders around this editor, and nothing under
/// the caret is replaced (022 FR-012).
///
/// The caret carries the person's name above it, because the agent may be typing on
/// the same page at the same moment and a bare caret no longer says whose it is. That
/// is why this is an `NSTextView` on the Mac and a `UITextView` on a phone rather than a
/// `TextEditor`: a `TextEditor` does not say where its caret is, and the flag has to
/// stand on it.
///
/// There is no "done". A pause writes; losing focus writes and closes; Escape closes,
/// writing first if there is anything to write. Return is a newline, because a passage
/// may be several lines long and a control that sent instead would eat the paragraph
/// break the person meant.
struct PassageEditor: View {
    @Binding var draft: String
    /// The draft is due on disk: a pause, or the editor closing.
    let onCommit: () -> Void
    /// The person is done here.
    let onClose: () -> Void
    /// Whose caret this is.
    var flag: CursorFlag = .person

    @State private var pause: Task<Void, Never>?
    /// Where the caret is, in the editor's own coordinates; nil until it has one.
    @State private var caret: CGRect?
    /// How tall the flag is drawn, so it can be stood on the line rather than beside it.
    @State private var flagHeight: CGFloat = 0

    /// How long after the last keystroke the draft goes to disk. Long enough that a
    /// sentence typed at speed is one write, not twenty; short enough to be inside
    /// the spec's two seconds with room for the round trip (SC-003).
    static let pauseBeforeSaving: Duration = .seconds(1)

    var body: some View {
        PassageTextView(text: $draft, caret: $caret) {
            pause?.cancel()
            onCommit()
            onClose()
        }
        .overlay(alignment: .topLeading) {
            if let caret {
                CursorFlagLabel(flag: flag)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { flagHeight = $0 }
                    // Stood on the caret: its bottom edge on the top of the caret's line.
                    .offset(x: caret.minX, y: caret.minY - flagHeight - CursorFlag.gap)
            }
        }
        .onChange(of: draft) {
            pause?.cancel()
            pause = Task {
                try? await Task.sleep(for: Self.pauseBeforeSaving)
                guard !Task.isCancelled else { return }
                onCommit()
            }
        }
        .onDisappear { pause?.cancel() }
    }
}

#if os(macOS)
/// The text view itself: as tall as its text, as wide as it is offered, and saying
/// where its caret is whenever that moves.
private struct PassageTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var caret: CGRect?
    /// Escape, or focus going elsewhere.
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EndingTextView {
        // TextKit 1, asked for by name: the caret's rectangle and the height of the
        // text both come from the layout manager, and asking a TextKit 2 view for it
        // would drop it to 1 anyway, with a log line.
        let view = EndingTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = TextStep.reading.nsFont
        view.textColor = .textColor
        // No inset and no padding, so the first character sits where the rendered one
        // did and opening the passage moves nothing.
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.string = text
        view.onEnd = { context.coordinator.parent.onEnd() }
        view.onMove = { [weak view] in
            guard let view else { return }
            context.coordinator.report(view)
        }
        // A beat later, not at once. The prompt bar holds first responder and takes it
        // back if asked in the same pass; the walk saw a sentence typed at the page
        // land in the prompt box.
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            context.coordinator.report(view)
        }
        return view
    }

    func updateNSView(_ view: EndingTextView, context: Context) {
        context.coordinator.parent = self
        // Only when the text changed from outside — "Use theirs" — never on the
        // person's own keystroke coming back, which would put the caret at the end.
        if view.string != text {
            view.string = text
            context.coordinator.report(view)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: EndingTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite,
              let manager = view.layoutManager, let container = view.textContainer else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        let line = manager.defaultLineHeight(for: view.font ?? TextStep.reading.nsFont)
        return CGSize(width: width, height: ceil(max(used, line)))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PassageTextView

        init(_ parent: PassageTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            report(view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            report(view)
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.onEnd()
            return true
        }

        /// Where the caret is now, told to the view that draws the flag. After the
        /// layout has caught up with the keystroke, not before it.
        func report(_ view: NSTextView) {
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                parent.caret = Self.caret(in: view)
            }
        }

        private static func caret(in view: NSTextView) -> CGRect? {
            guard let manager = view.layoutManager, let container = view.textContainer else { return nil }
            let origin = view.textContainerOrigin
            let location = view.selectedRange().location
            let length = (view.string as NSString).length
            manager.ensureLayout(for: container)
            // After the last character: on the empty line a trailing newline leaves,
            // or just past the last glyph.
            if location >= length {
                let extra = manager.extraLineFragmentRect
                if !extra.isEmpty || manager.numberOfGlyphs == 0 {
                    let height = extra.isEmpty
                        ? manager.defaultLineHeight(for: view.font ?? TextStep.reading.nsFont)
                        : extra.height
                    return CGRect(x: origin.x + extra.minX, y: origin.y + extra.minY, width: 1, height: height)
                }
                let last = manager.numberOfGlyphs - 1
                let glyph = manager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
                let line = manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
                return CGRect(x: origin.x + glyph.maxX, y: origin.y + line.minY, width: 1, height: line.height)
            }
            let index = manager.glyphIndexForCharacter(at: location)
            let glyph = manager.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)
            let line = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
            return CGRect(x: origin.x + glyph.minX, y: origin.y + line.minY, width: 1, height: line.height)
        }
    }
}

/// A text view that says when the person has left it, and when its width changed
/// under the caret.
private final class EndingTextView: NSTextView {
    var onEnd: (() -> Void)?
    var onMove: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // Losing focus writes and closes. Afterwards, not during: closing removes this
        // view, and the window is still in the middle of moving focus.
        if resigned { Task { @MainActor [onEnd] in onEnd?() } }
        return resigned
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onMove?()
    }
}
#else
/// The phone's text view (034): as tall as its text, as wide as it is offered, and
/// saying where its caret is whenever that moves. There is no Escape on a touch
/// keyboard; the passage ends when focus leaves it — another passage tapped, the
/// keyboard put away, the pane left.
private struct PassageTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var caret: CGRect?
    /// Focus going elsewhere.
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = TextStep.reading.uiFont
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        // No inset and no padding, so the first character sits where the rendered one
        // did and opening the passage moves nothing.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.autocorrectionType = .default
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A beat later, so the keyboard comes up for the passage that was tapped and not
        // for whatever held focus as it was drawn.
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let view else { return }
            view.becomeFirstResponder()
            let end = view.endOfDocument
            view.selectedTextRange = view.textRange(from: end, to: end)
            context.coordinator.report(view)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        // Only when the text changed from outside — "Use theirs" — never on the
        // person's own keystroke coming back, which would put the caret at the end.
        if view.text != text {
            view.text = text
            context.coordinator.report(view)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let line = view.font?.lineHeight ?? TextStep.reading.uiFont.lineHeight
        return CGSize(width: width, height: ceil(max(fitted.height, line)))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PassageTextView

        init(_ parent: PassageTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            report(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            report(view)
        }

        func textViewDidEndEditing(_ view: UITextView) {
            // Afterwards, not during: closing removes this view while focus is moving.
            Task { @MainActor [parent] in parent.onEnd() }
        }

        /// Where the caret is now, for the flag. After the layout has caught up.
        func report(_ view: UITextView) {
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, let range = view.selectedTextRange else { return }
                let rect = view.caretRect(for: range.end)
                parent.caret = rect.isNull || rect.isInfinite ? nil : rect
            }
        }
    }
}
#endif
