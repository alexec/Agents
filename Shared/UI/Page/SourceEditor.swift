import AgentsKitCore
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
    /// What the file's language server found, as last asked (#844).
    @State private var diagnostics: DaemonAPI.FileDiagnostics?
    /// A line to move the caret to, from the problems list; a new id each time.
    @State private var jump: SourceJump?

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
                    .tinted(.failure)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }
            SourceTextView(text: $draft, line: line, jump: jump, isEditable: actions.canEdit,
                           complete: completer) {
                commit()
            }
            .accessibilityLabel(URL(filePath: path).lastPathComponent)
            if let diagnostics {
                ProblemsList(diagnostics: diagnostics) { jump = SourceJump(line: $0) }
            }
        }
        // The language server is asked a moment after the typing stops (#844).
        .task(id: draft) {
            guard let diagnose = actions.diagnose else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let found = await diagnose(path, draft), !Task.isCancelled else { return }
            diagnostics = found
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

    /// The language server's completion at a place in the text (#844), for the text view.
    private var completer: (@MainActor (String, Int, Int) async -> [String])? {
        guard let complete = actions.complete else { return nil }
        let path = path
        return { text, line, column in await complete(path, text, line, column).map(\.written) }
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

/// A move of the caret to a line, from the problems list: a new id each time, so the same
/// line twice moves it twice.
struct SourceJump: Equatable {
    let line: Int
    let id = UUID()
}

/// What a file's language server found (#844), under the editor: each problem's place and
/// words, a click away from its line. Nothing when the file's language has no server; a
/// line saying why when its server is not installed or did not answer.
private struct ProblemsList: View {
    let diagnostics: DaemonAPI.FileDiagnostics
    let goTo: (Int) -> Void

    var body: some View {
        if diagnostics.server != nil, !diagnostics.diagnostics.isEmpty || diagnostics.reason != nil {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Text(heading)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                if !diagnostics.diagnostics.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diagnostics.diagnostics.enumerated()), id: \.offset) { _, problem in
                                Button { goTo(problem.line) } label: { row(problem) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
    }

    private var heading: String {
        if let reason = diagnostics.reason, diagnostics.diagnostics.isEmpty { return reason }
        let count = diagnostics.diagnostics.count
        return "\(count) \(count == 1 ? "problem" : "problems") · \(diagnostics.server ?? "")"
    }

    private func row(_ problem: DaemonAPI.FileDiagnostic) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol(problem.severity))
                .foregroundStyle((problem.severity == "error" ? StateTint.failure
                    : problem.severity == "warning" ? .attention : .none).style(or: .secondary))
                .accessibilityLabel(problem.severity)
            Text("\(problem.line):\(problem.column)")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(problem.message)
                .appText(.fine)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .help("Go to line \(problem.line)")
    }

    private func symbol(_ severity: String) -> String {
        switch severity {
        case "error": "xmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "info.circle"
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
    var jump: SourceJump?
    let isEditable: Bool
    /// The language server's words for the caret's place (#844): ⌥Esc or F5 asks, and the
    /// text view's own completion list shows them.
    var complete: (@MainActor (_ text: String, _ line: Int, _ column: Int) async -> [String])?
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
        // Setting the text leaves the caret at its end. Opened from Open File… the
        // field's focus passes to this view, which then scrolls down to that caret,
        // laying the file out as it goes so it looks typed in. The top it is.
        view.setSelectedRange(NSRange(location: 0, length: 0))
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
        // The system's text size, if it changed while the file was open.
        let font = TextStep.code.nsFont
        if view.font != font { view.font = font }
        // Only when the text changed from outside — the file on disk — never on the
        // person's own keystroke coming back, which would lose the caret.
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        // A problem chosen in the list (#844): the caret to its line.
        if let jump, jump != context.coordinator.lastJump {
            context.coordinator.lastJump = jump
            let range = NSRange(location: sourceOffset(ofLine: jump.line, in: view.string), length: 0)
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
            view.window?.makeFirstResponder(view)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceTextView
        var lastJump: SourceJump?
        /// The language server's last words, for the completion list and its filtering.
        var offered: [String]?

        /// Complete (⌥Esc, F5): asked of the language server, then the list shown.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.complete(_:)), let complete = parent.complete else { return false }
            let place = Self.place(of: textView.selectedRange().location, in: textView.string)
            let text = textView.string
            Task { @MainActor [weak self, weak textView] in
                let words = await complete(text, place.line, place.column)
                guard let self, let textView, textView.string == text else { return }
                guard !words.isEmpty else { NSSound.beep(); return }
                self.offered = words
                textView.complete(nil)
            }
            return true
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let offered else { return words }
            let partial = (textView.string as NSString).substring(with: charRange).lowercased()
            let matching = offered.filter { $0.lowercased().hasPrefix(partial) }
            return matching.isEmpty ? offered : matching
        }

        /// A UTF-16 offset as a line and column, both from 1.
        static func place(of offset: Int, in text: String) -> (line: Int, column: Int) {
            var line = 1
            var start = 0
            for (i, unit) in text.utf16.prefix(offset).enumerated() where unit == 0x0A {
                line += 1
                start = i + 1
            }
            return (line, offset - start + 1)
        }

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
    var jump: SourceJump?
    let isEditable: Bool
    /// Not offered on a phone or iPad yet (#844): its keyboard has no completion list.
    var complete: (@MainActor (_ text: String, _ line: Int, _ column: Int) async -> [String])?
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
        // As on the Mac: the caret at the top, not at the end the text left it.
        view.selectedRange = NSRange(location: 0, length: 0)
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
        // A problem chosen in the list (#844): the caret to its line.
        if let jump, jump != context.coordinator.lastJump {
            context.coordinator.lastJump = jump
            if let start = view.position(from: view.beginningOfDocument,
                                         offset: sourceOffset(ofLine: jump.line, in: view.text)) {
                view.selectedTextRange = view.textRange(from: start, to: start)
                view.scrollRangeToVisible(view.selectedRange)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SourceTextView
        var lastJump: SourceJump?

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
