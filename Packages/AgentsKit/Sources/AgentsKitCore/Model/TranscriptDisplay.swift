import Foundation

/// What the chat actually draws, which is not one line per entry.
///
/// The record keeps everything that happened. Reading it does not mean seeing all of
/// it: a sentence arrives as a dozen chunks, and a job of work arrives as a run of tool
/// calls where only the last one is news.
public enum TranscriptItem: Identifiable, Hashable, Sendable {
    case entry(TranscriptEntry)
    /// Consecutive tool calls, latest last. One is shown plainly; several are shown as
    /// the latest with the rest behind a click.
    case toolRun(id: UUID, calls: [ToolCall])

    public var id: UUID {
        switch self {
        case .entry(let entry): return entry.id
        case .toolRun(let id, _): return id
        }
    }
}

extension TranscriptEntry {
    /// Turn a page of the record into what the chat shows.
    ///
    /// Two things happen here. Chunks of one message are joined back into the message.
    /// And a run of tool calls becomes one item: a tool call and its later updates are
    /// the same call, so the run holds each call once, at its latest state.
    public static func display(_ entries: [TranscriptEntry]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var run: [ToolCall] = []
        var runID = UUID()
        /// The suggestion calls we are not drawing. Kept by id because the update that
        /// follows one carries neither the name nor the title: on its own it reads as
        /// an anonymous "Tool call", and that is what would end up on screen.
        var suppressed: Set<String> = []

        func closeRun() {
            guard !run.isEmpty else { return }
            items.append(.toolRun(id: runID, calls: run))
            run = []
            runID = UUID()
        }

        for entry in coalesced(entries) {
            switch entry.kind {
            case .toolCall(let call), .toolCallUpdate(let call):
                // The app's own suggestion tool is not drawn, and nor is the outcome
                // report. Neither is hidden work: what one did is the row above the
                // prompt and what the other did is the report at the foot of the
                // conversation, and a line here saying so would be the same thing said
                // twice.
                if call.isSuggestingPrompts || call.isReportingOutcome {
                    if let id = call.toolCallID { suppressed.insert(id) }
                    continue
                }
                if let id = call.toolCallID, suppressed.contains(id) { continue }
                // An update is the same call further along, so it replaces the one
                // already in the run rather than adding a line to it.
                if let id = call.toolCallID, let existing = run.firstIndex(where: { $0.toolCallID == id }) {
                    run[existing] = merge(call, onto: run[existing])
                } else {
                    run.append(call)
                }
            default:
                closeRun()
                items.append(.entry(entry))
            }
        }
        closeRun()
        return withoutSupersededPassingLines(items)
    }

    /// A passing line is kept only while it is the latest thing on the page.
    ///
    /// "Working", "Starting Claude…", "mode is now auto": each is true of the moment it
    /// was written and of nothing after, and the line that follows it is what makes it
    /// old. So the newest passing line stays, since nothing has yet superseded it, and
    /// every earlier one goes. The record keeps them all; this is only what is drawn.
    static func withoutSupersededPassingLines(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard let latest = items.lastIndex(where: \.isDrawn) else { return items }
        return items.enumerated().compactMap { offset, item in
            item.isPassing && offset != latest ? nil : item
        }
    }

    /// An update is the same call further along, and it carries only what changed.
    ///
    /// Field by field, on purpose. A completion update carries the output and not the
    /// input, so replacing the whole thing loses what the call was made with, which is
    /// usually the more interesting half. Content is appended rather than replaced,
    /// because a tool call's content arrives in pieces.
    static func merge(_ update: ToolCall, onto existing: ToolCall) -> ToolCall {
        var merged = existing
        if !update.title.isEmpty, update.title != "Tool call" { merged.title = update.title }
        if let name = update.name { merged.name = name }
        if let kind = update.kind { merged.kind = kind }
        if let status = update.status { merged.status = status }
        if !update.content.isEmpty { merged.content += update.content }
        if !update.locations.isEmpty { merged.locations = update.locations }
        if let rawInput = update.rawInput { merged.rawInput = rawInput }
        if let rawOutput = update.rawOutput { merged.rawOutput = rawOutput }
        if let raw = update.raw { merged.raw = raw }
        return merged
    }
}

extension TranscriptItem {
    /// Whether the chat puts anything on the page for this item.
    ///
    /// An entry written by a newer build is kept in the record and drawn as nothing,
    /// so it cannot be the line that makes a passing one old.
    var isDrawn: Bool {
        if case .entry(let entry) = self, case .unrecognised = entry.kind { return false }
        return true
    }

    /// Whether this item says only where things stand right now.
    var isPassing: Bool {
        if case .entry(let entry) = self { return entry.isPassing }
        return false
    }

    /// The one line a collapsed run shows: what it is doing now.
    public var latestToolCall: ToolCall? {
        if case .toolRun(_, let calls) = self { return calls.last }
        return nil
    }

    /// How many are hidden behind the one on show.
    public var hiddenToolCallCount: Int {
        if case .toolRun(_, let calls) = self { return max(0, calls.count - 1) }
        return 0
    }
}

extension TranscriptEntry {
    /// Whether this entry is about a moment rather than about what happened.
    ///
    /// The agent starting, the agent working, a mode switched, the runtime being
    /// brought back: each is superseded by whatever comes next. An ending, an answer
    /// and a message are not, and stay. One ending is here all the same: an agent
    /// stopped because the daemon did is picked back up straight after, and once it
    /// has been, that stop is a moment too.
    public var isPassing: Bool {
        switch kind {
        case .stateChanged(.starting, _), .stateChanged(.running, _):
            return true
        case .stateChanged(.stopped, reason: .daemonGone):
            return true
        case .optionChanged:
            return true
        case .runtimeNote(let text):
            return RuntimeNote.isPassing(text)
        default:
            return false
        }
    }
}
