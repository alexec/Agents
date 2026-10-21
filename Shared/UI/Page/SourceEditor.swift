import AgentsKitCore
import CodeText
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
/// waiting to go to disk, what is on disk is taken in place. While something is, nothing
/// is saved over it (#1858): the editor says the file changed, with Compare, Keep Mine and
/// Take Theirs, and Undo after Take Theirs gives the typing back. Each save also sends the
/// digest of the text the edit began from, so a change the watch has not reported yet is
/// refused by the host and asked about the same way.
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
    /// Why a completion the person asked for brought nothing, shown for a moment (#1688).
    @State private var completionNote: String?
    @State private var noteShown: Task<Void, Never>?
    /// What is on disk now, when it changed while something typed waited to be saved
    /// (#1858). Nothing is saved while it is set: the person chooses.
    @State private var theirs: String?
    @State private var comparing = false
    /// What was typed before Take Theirs, for Undo.
    @State private var mine: String?

    init(text: String, path: String, line: Int?) {
        self.text = text
        self.path = path
        self.line = line
        _draft = State(initialValue: text)
        _saved = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let theirs {
                ChangedOnDiskStrip(comparing: $comparing,
                                   keepMine: { saved = theirs; self.theirs = nil; comparing = false; commit() },
                                   takeTheirs: {
                                       mine = draft
                                       saved = theirs
                                       draft = theirs
                                       self.theirs = nil
                                       comparing = false
                                   })
                if comparing {
                    ScrollView {
                        FileDiffView(rows: LineDiff.rows(old: theirs, new: draft), path: path,
                                     oldText: theirs, newText: draft)
                    }
                    .frame(maxHeight: 240)
                    Divider()
                }
            } else if let mine, draft == saved {
                HStack(spacing: 8) {
                    Text(SourceEditorWords.tookTheirs)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(SourceEditorWords.undo) {
                        draft = mine
                        self.mine = nil
                    }
                }
                .appText(.fine)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
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
            if let completionNote {
                Divider()
                Text(completionNote)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let diagnostics {
                ProblemsList(diagnostics: diagnostics) { jump = SourceJump(line: $0) }
            }
        }
        // The language server is asked a moment after the typing stops (#844).
        .task(id: draft) {
            guard let diagnose = actions.diagnose else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do {
                let found = try await diagnose(path, draft)
                guard !Task.isCancelled else { return }
                diagnostics = found
            } catch {
                // A failed request says so, not "no problems" (#1687).
                guard !Task.isCancelled else { return }
                let server = diagnostics?.server ?? "the language server"
                let why = (error as? JSONRPCError)?.message ?? error.localizedDescription
                diagnostics = DaemonAPI.FileDiagnostics(diagnostics: [], server: server, reason: "Couldn't ask \(server): \(why)")
            }
        }
        .onChange(of: text) { _, disk in
            guard disk != saved else { return }
            if draft == saved {
                draft = disk
                saved = disk
                theirs = nil
            } else if draft == disk {
                saved = disk
                theirs = nil
            } else {
                // Typed text waits, and the file changed under it: asked, not written over.
                pause?.cancel()
                theirs = disk
            }
        }
        .onChange(of: draft) {
            pause?.cancel()
            if let mine, draft != saved, draft != mine { self.mine = nil }
            guard draft != saved, theirs == nil else { return }
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
    /// When the person asked and nothing comes, the reason shows for a moment (#1688); a
    /// list asked for by a pause in the typing says nothing.
    private var completer: SourceCompleter? {
        guard let complete = actions.complete else { return nil }
        let path = path
        return { text, line, column, asked in
            let found = await complete(path, text, line, column)
            if asked, found.items.isEmpty { note(found.reason ?? "No completions here.") }
            return found.items.map(\.written)
        }
    }

    private func note(_ words: String) {
        completionNote = words
        noteShown?.cancel()
        noteShown = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            completionNote = nil
        }
    }

    /// Saves what is typed, unless the file changed under it and the person has not chosen
    /// yet: then the agent's change stays on disk, also when the file is left.
    private func commit() {
        pause?.cancel()
        guard draft != saved, theirs == nil, actions.canEdit else { return }
        let sending = draft
        guard let saveOver = actions.saveOver else {
            let save = actions.save
            Task {
                if let why = await save(path, sending) {
                    problem = why
                } else {
                    problem = nil
                    saved = sending
                }
            }
            return
        }
        let base = DaemonAPI.ArtifactWriteRequest.digest(saved)
        Task {
            switch await saveOver(path, sending, base) {
            case .saved:
                problem = nil
                saved = sending
            case .changedOnDisk:
                // The watch may not have said yet; what it reads next replaces this.
                problem = nil
                theirs = text
            case .failed(let why):
                problem = why
            }
        }
    }
}

/// The language server's words for a line and column (from 1); `asked` when the person
/// asked for them, not a pause in the typing (#1688).
typealias SourceCompleter = @MainActor (_ text: String, _ line: Int, _ column: Int, _ asked: Bool) async -> [String]

/// A move of the caret to a line, from the problems list: a new id each time, so the same
/// line twice moves it twice.
struct SourceJump: Equatable {
    let line: Int
    let id = UUID()
}

/// What a file's language server found (#844), under the editor: each problem's place and
/// words, a click away from its line. Nothing when the file's language has no server; a
/// line saying why when its server is not installed, is starting or did not answer, and
/// "No problems · ‹server›" once it answered with none (#1687).
private struct ProblemsList: View {
    let diagnostics: DaemonAPI.FileDiagnostics
    let goTo: (Int) -> Void

    var body: some View {
        if diagnostics.server != nil {
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
        if count == 0 { return "No problems · \(diagnostics.server ?? "")" }
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
    /// The language server's words for the caret's place (#844): ⌥Esc, F5 or Edit ▸ Complete
    /// asks, and the text view's own completion list shows them.
    var complete: SourceCompleter?
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
                let words = await complete(text, place.line, place.column, true)
                // Nothing: the editor says why under the text (#1688).
                guard let self, let textView, textView.string == text, !words.isEmpty else { return }
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
    /// The language server's words for the caret's place (#1603): a row of them above the
    /// keyboard once the typing stops in a word, or at Ctrl+Space on a hardware keyboard.
    var complete: SourceCompleter?
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = CompletingTextView()
        view.delegate = context.coordinator
        view.askCompletion = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.ask(view, asked: true)
        }
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
        /// The wait after a keystroke before the language server is asked.
        private var pause: Task<Void, Never>?

        init(_ parent: SourceTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            show([], in: view)
            pause?.cancel()
            guard parent.complete != nil, partialWord(in: view) != nil else { return }
            pause = Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, let view else { return }
                self.ask(view, asked: false)
            }
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            // The caret moved off the word the row was for.
            if view.inputAccessoryView != nil, partialWord(in: view) == nil { show([], in: view) }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            pause?.cancel()
            show([], in: view)
            parent.onEnd()
        }

        /// Asks the language server for the caret's place, then shows its words.
        func ask(_ view: UITextView, asked: Bool) {
            guard let complete = parent.complete, view.isEditable else { return }
            let text = view.text ?? ""
            let caret = view.selectedRange.location
            let place = Self.place(of: caret, in: text)
            Task { @MainActor [weak self, weak view] in
                let words = await complete(text, place.line, place.column, asked)
                guard let self, let view, view.text == text, view.selectedRange.location == caret else { return }
                let partial = self.partialWord(in: view).map { (text as NSString).substring(with: $0).lowercased() } ?? ""
                let matching = words.filter { $0.lowercased().hasPrefix(partial) }
                self.show(matching.isEmpty ? words : matching, in: view)
            }
        }

        /// The row above the keyboard: shown with words, gone without.
        private func show(_ words: [String], in view: UITextView) {
            if words.isEmpty {
                guard view.inputAccessoryView != nil else { return }
                view.inputAccessoryView = nil
            } else {
                view.inputAccessoryView = CompletionRow(words: words) { [weak self, weak view] word in
                    guard let self, let view else { return }
                    self.put(word, in: view)
                }
            }
            view.reloadInputViews()
        }

        /// The word in place of the one being typed, as one undoable change.
        private func put(_ word: String, in view: UITextView) {
            let range = partialWord(in: view) ?? NSRange(location: view.selectedRange.location, length: 0)
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let replacing = view.textRange(from: start, to: end) else { return }
            view.replace(replacing, withText: word)
            parent.text = view.text
            show([], in: view)
        }

        /// The letters, digits and underscores just before the caret; nil when there are none.
        private func partialWord(in view: UITextView) -> NSRange? {
            let selection = view.selectedRange
            guard selection.length == 0 else { return nil }
            let text = (view.text ?? "") as NSString
            var start = selection.location
            while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)),
                  scalar == "_" || CharacterSet.alphanumerics.contains(scalar) {
                start -= 1
            }
            return start < selection.location ? NSRange(location: start, length: selection.location - start) : nil
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
    }
}

/// The source text view, with Ctrl+Space on a hardware keyboard asking for completion (#1603).
/// While the row of words is up, ↑ and ↓ choose one, Return and Tab put it in, and Escape
/// closes the row, as the Mac's list and the web's take them (#1686).
private final class CompletingTextView: UITextView {
    var askCompletion: (() -> Void)?

    private var row: CompletionRow? { inputAccessoryView as? CompletionRow }

    override var keyCommands: [UIKeyCommand]? {
        let ask = UIKeyCommand(title: "Complete", action: #selector(complete), input: " ", modifierFlags: .control)
        ask.wantsPriorityOverSystemBehavior = true
        var commands = (super.keyCommands ?? []) + [ask]
        if row != nil {
            let keys: [(String, String, Selector)] = [
                ("Previous Completion", UIKeyCommand.inputUpArrow, #selector(previousCompletion)),
                ("Next Completion", UIKeyCommand.inputDownArrow, #selector(nextCompletion)),
                ("Use Completion", "\r", #selector(take)),
                ("Use Completion", "\t", #selector(take)),
                ("Close Completions", UIKeyCommand.inputEscape, #selector(close)),
            ]
            for (title, input, action) in keys {
                let command = UIKeyCommand(title: title, action: action, input: input)
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands
    }

    @objc private func complete() { askCompletion?() }
    @objc private func previousCompletion() { row?.move(by: -1) }
    @objc private func nextCompletion() { row?.move(by: 1) }
    @objc private func take() { row?.takeChosen() }
    @objc private func close() {
        inputAccessoryView = nil
        reloadInputViews()
    }
}

/// The language server's words in a row above the keyboard (#1603); a tap puts one in. Each
/// word is at least 44 points high and grows with the text size; one is chosen, for the
/// keyboard (#1686).
private final class CompletionRow: UIInputView, UIInputViewAudioFeedback {
    private let words: [String]
    private let chosen: (String) -> Void
    private var buttons: [UIButton] = []
    private let scroll = UIScrollView()
    /// The word Return or Tab puts in: the first, until ↑ or ↓ moves it.
    private var choice = 0

    var enableInputClicksWhenVisible: Bool { true }

    init(words: [String], chosen: @escaping (String) -> Void) {
        self.words = words
        self.chosen = chosen
        // A 44 point word and its margin, or more with a larger text size.
        let height = max(52, (TextStep.code.uiFont.lineHeight + 12 + 8).rounded(.up))
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: max(52, (TextStep.code.uiFont.lineHeight + 12 + 8).rounded(.up)))
    }

    private func build() {
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        for index in words.indices {
            let button = UIButton(type: .system)
            button.tag = index
            button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            row.addArrangedSubview(button)
            buttons.append(button)
        }
        drawChoice()

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -8),
        ])
    }

    /// The chosen word filled, the others grey.
    private func drawChoice() {
        for (index, button) in buttons.enumerated() {
            var configuration = index == choice ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            configuration.title = words[index]
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes.font = TextStep.code.uiFont
                return attributes
            }
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            if index != choice { configuration.baseForegroundColor = .label }
            button.configuration = configuration
            button.accessibilityTraits = index == choice ? [.button, .selected] : .button
        }
    }

    /// ↑ or ↓: the word before or after, kept in view.
    func move(by step: Int) {
        guard !words.isEmpty else { return }
        choice = min(max(choice + step, 0), words.count - 1)
        drawChoice()
        let button = buttons[choice]
        scroll.scrollRectToVisible(button.convert(button.bounds, to: scroll).insetBy(dx: -8, dy: 0), animated: true)
    }

    /// Return or Tab: the chosen word put in.
    func takeChosen() {
        guard words.indices.contains(choice) else { return }
        chosen(words[choice])
    }

    @objc private func pressed(_ sender: UIButton) {
        UIDevice.current.playInputClick()
        guard words.indices.contains(sender.tag) else { return }
        chosen(words[sender.tag])
    }
}
#endif

/// The words for a file that changed on disk while something typed waited (#1858), once for
/// both apps. The web page says the same in `files/SourceEditor.tsx`.
enum SourceEditorWords {
    static let changed = "This file changed on disk while you were typing. Nothing was saved over it."
    static let compare = "Compare"
    static let hideCompare = "Hide Comparison"
    static let keepMine = "Keep Mine"
    static let takeTheirs = "Take Theirs"
    static let tookTheirs = "You took the version on disk."
    static let undo = "Undo"
}

/// Over the editor while the file changed under the person's typing (#1858).
private struct ChangedOnDiskStrip: View {
    @Binding var comparing: Bool
    let keepMine: () -> Void
    let takeTheirs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(SourceEditorWords.changed, systemImage: "exclamationmark.triangle")
                .tinted(.attention)
            HStack(spacing: 8) {
                Button(comparing ? SourceEditorWords.hideCompare : SourceEditorWords.compare) { comparing.toggle() }
                    .help("Your text beside the file on disk")
                Button(SourceEditorWords.keepMine, action: keepMine)
                    .help("Save your text over the file on disk")
                Button(SourceEditorWords.takeTheirs, action: takeTheirs)
                    .help("Take the file on disk; Undo gives your text back")
                Spacer(minLength: 0)
            }
        }
        .appText(.fine)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        Divider()
    }
}
