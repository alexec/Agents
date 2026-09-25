import Foundation
import Observation
import os

/// One shown text, split into lines, with its colour arriving a window at a time
/// (041 research R3).
///
/// A view draws `lines` at once and asks `spans(line:)` for each row it draws; a row whose
/// window has not arrived yet draws plain, and redraws when it does. The text never waits for
/// the colour (FR-017).
@MainActor @Observable
public final class CodeDocument {
    public private(set) var lines: [Substring]
    public private(set) var language: CodeLanguage?
    /// Set when the text is past a limit and is shown plain on purpose (FR-018).
    public private(set) var plainBecause: PlainReason?

    /// Window index → the spans of each line in it.
    private var windows: [Int: [[CodeSpan]]] = [:]
    @ObservationIgnored private var asked: Set<Int> = []
    @ObservationIgnored private var text: String
    @ObservationIgnored private var lineStarts: [Int] = []
    @ObservationIgnored private let id = UUID()
    /// Whether the colourer holds a parse of this text. Windows are asked for only once it does.
    @ObservationIgnored private var parsed: Task<Bool, Never>?
    /// Bumped on every change of text, so a window computed for old text is dropped.
    @ObservationIgnored private var generation = 0

    public init(text: String, language: CodeLanguage?) {
        self.text = text
        self.lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        self.language = language
        self.plainBecause = language == nil ? nil : Limits.plainReason(for: text)
        lineStarts = Colourer.lineStarts(of: lines)
        startParse()
    }

    isolated deinit {
        let id = id
        Task { await Colourer.shared.forget(id: id) }
    }

    /// The spans of a line, or none until its window has arrived.
    public func spans(line: Int) -> [CodeSpan] {
        let window = line / Limits.window
        guard let spans = windows[window] else { return [] }
        let index = line - window * Limits.window
        return index < spans.count ? spans[index] : []
    }

    /// Asks for the window holding `line`, and the one after it, so scrolling down finds its
    /// colour already there.
    public func appear(line: Int) {
        let window = line / Limits.window
        request(window)
        request(window + 1)
    }

    /// New text for the same document: an agent still writing the file. Reparsed around the
    /// change, and only the windows the change touched are asked for again (R7).
    public func update(text newText: String) {
        guard newText != text else { return }
        let oldLines = lines
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false)
        text = newText
        lines = newLines
        lineStarts = Colourer.lineStarts(of: newLines)
        generation += 1
        let reason = language == nil ? nil : Limits.plainReason(for: newText)
        guard reason == nil, plainBecause == nil, let parsed else {
            // Crossed a limit, or was never parsed: start again from what the text is now.
            plainBecause = reason
            windows = [:]
            asked = []
            startParse()
            return
        }

        // The first line that differs; everything before it keeps its colour.
        var firstChanged = 0
        while firstChanged < oldLines.count, firstChanged < newLines.count,
              oldLines[firstChanged] == newLines[firstChanged] { firstChanged += 1 }
        let keep = firstChanged / Limits.window
        let visible = asked
        windows = windows.filter { $0.key < keep }
        asked = asked.filter { $0 < keep }

        let id = id
        self.parsed = Task {
            guard await parsed.value else { return false }
            await Colourer.shared.edit(id: id, text: newText)
            return true
        }
        for window in visible where window >= keep { request(window) }
    }

    // MARK: -

    private func startParse() {
        guard plainBecause == nil, let language else {
            parsed = nil
            return
        }
        let id = id, text = text
        let signpostID = Self.signposter.makeSignpostID()
        let state = Self.signposter.beginInterval("parse", id: signpostID)
        parsed = Task {
            let ok = await Colourer.shared.parse(id: id, text: text, language: language)
            Self.signposter.endInterval("parse", state)
            return ok
        }
    }

    private func request(_ window: Int) {
        let first = window * Limits.window
        guard first < lines.count, !asked.contains(window), let parsed else { return }
        asked.insert(window)
        let range = first..<min(first + Limits.window, lines.count)
        let starts = lineStarts
        let id = id, generation = generation
        let firstWindow = windows.isEmpty
        let signpostID = Self.signposter.makeSignpostID()
        let state = firstWindow ? Self.signposter.beginInterval("firstWindow", id: signpostID) : nil
        Task {
            guard await parsed.value else { return }
            let spans = await Colourer.shared.spans(id: id, lines: range, lineStarts: starts)
            if let state { Self.signposter.endInterval("firstWindow", state) }
            // Text that changed while this was being worked out has asked again.
            guard generation == self.generation else { return }
            windows[window] = spans
        }
    }

    private static let signposter = OSSignposter(subsystem: "com.alexecollins.Agents",
                                                 category: "CodeText")
}
