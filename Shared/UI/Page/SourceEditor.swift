import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A file that is not a page, open for typing (#415).
///
/// Markdown is a live page and HTML a drawn one; everything else that is text is this:
/// the file's source in the code face, editable where it is shown. It saves the way the
/// page does, through `PageActions.save`, a moment after the typing stops and again when
/// the file is left, so there is no Save to forget.
///
/// The file can change under it — an agent writing the same file. While nothing typed is
/// waiting to go to disk, what is on disk is taken in place; while something is, the
/// person's text wins, and what they typed is written over it when the pause comes.
///
/// Plain, not coloured: colour is drawn a line at a time by `FileLines`, and a text view
/// the person types in is one run of text. A file only partly read is not this view at
/// all — saving it would cut it short — and stays `FileLines`.
struct SourceEditor: View {
    /// What the file holds on disk, as last read.
    let text: String
    let path: String
    /// The line to put the caret on, counted from one, or nil for the top.
    let line: Int?

    @Environment(\.pageActions) private var actions
    @State private var draft: String
    /// What is known to be on disk: the last read, or the last save that worked.
    @State private var saved: String
    @State private var pause: Task<Void, Never>?
    @State private var problem: String?

    init(text: String, path: String, line: Int?) {
        self.text = text
        self.path = path
        self.line = line
        _draft = State(initialValue: text)
        _saved = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem {
                Text(problem)
                    .appText(.fine)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }
            SourceTextView(text: $draft, line: line, isEditable: actions.canEdit) {
                commit()
            }
            .accessibilityLabel(URL(filePath: path).lastPathComponent)
        }
        .onChange(of: text) { _, disk in
            if draft == saved { draft = disk }
            saved = disk
        }
        .onChange(of: draft) {
            pause?.cancel()
            guard draft != saved else { return }
            pause = Task {
                try? await Task.sleep(for: PassageEditor.pauseBeforeSaving)
                guard !Task.isCancelled else { return }
                commit()
            }
        }
        // Left with something unsaved — Back, another file, the pane shut: written now.
        .onDisappear { commit() }
    }

    private func commit() {
        pause?.cancel()
        guard draft != saved, actions.canEdit else { return }
        let sending = draft
        let save = actions.save
        Task {
            if let why = await save(path, sending) {
                problem = why
            } else {
                problem = nil
                saved = sending
            }
        }
    }
}

/// Where a line starts in a text, counted from one: the offset in UTF-16, as the text
/// views count. Past the end is the end.
private func sourceOffset(ofLine line: Int, in text: String) -> Int {
    let units = text.utf16
    var number = 1
    var offset = 0
    for unit in units {
        if number >= line { return offset }
        offset += 1
        if unit == 0x0A { number += 1 }
    }
    return offset
}

#if os(macOS)
/// The text view, scrolling, in the code face, with none of the typing help that turns
/// quotes curly in source.
private struct SourceTextView: NSViewRepresentable {
    @Binding var text: String
    let line: Int?
    let isEditable: Bool
    /// Focus going elsewhere: what is typed goes now rather than after the pause.
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = TextStep.code.nsFont
        view.textColor = .textColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.string = text
        view.isEditable = isEditable
        if let line {
            // A beat later, once the view is in a window and laid out to scroll in.
            Task { @MainActor [weak view] in
                guard let view else { return }
                let range = NSRange(location: sourceOffset(ofLine: line, in: view.string), length: 0)
                view.setSelectedRange(range)
                view.scrollRangeToVisible(range)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = isEditable
        // Only when the text changed from outside — the file on disk — never on the
        // person's own keystroke coming back, which would lose the caret.
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceTextView

        init(_ parent: SourceTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEnd()
        }
    }
}
#else
/// The Remote's text view (034): scrolling, in the code face, with none of the typing
/// help that capitalises and curls quotes in source.
private struct SourceTextView: UIViewRepresentable {
    @Binding var text: String
    let line: Int?
    let isEditable: Bool
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = TextStep.code.uiFont
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        view.text = text
        view.isEditable = isEditable
        if let line {
            Task { @MainActor [weak view] in
                guard let view, let start = view.position(from: view.beginningOfDocument,
                                                           offset: sourceOffset(ofLine: line, in: view.text)) else { return }
                view.selectedTextRange = view.textRange(from: start, to: start)
                view.scrollRangeToVisible(view.selectedRange)
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEditable
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SourceTextView

        init(_ parent: SourceTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
        }

        func textViewDidEndEditing(_ view: UITextView) {
            parent.onEnd()
        }
    }
}
#endif
