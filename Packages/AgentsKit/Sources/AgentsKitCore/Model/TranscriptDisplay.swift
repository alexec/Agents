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
    ///
    /// Some of the record is not conversation and is not drawn at all: a mode or
    /// model switched, a read the app served, the turn ending, what the turn cost.
    /// The record keeps them; the page is what was said and done.
    ///
    /// The whole page, from the top. A client holding a page that grows a chunk at a
    /// time keeps a `TranscriptDisplayBuilder` instead and feeds it each entry as it
    /// arrives, which is this same fold without starting over.
    public static func display(_ entries: [TranscriptEntry], subagent: String? = nil) -> [TranscriptItem] {
        var builder = TranscriptDisplayBuilder(subagent: subagent)
        for entry in entries { builder.add(entry) }
        return builder.items
    }

    /// A passing line is kept only while it is the latest thing on the page.
    ///
    /// "Working", "Starting Claude…", "Picked the conversation back up.": each is true of the moment it
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

extension ToolCall {
    /// Nothing a line could show: no title of its own, no tool, no state, no input,
    /// output or content. `raw` does not count; it always holds the wire object.
    var saysNothing: Bool {
        (title.isEmpty || title == "Tool call") && name == nil && kind == nil && status == nil
            && content.isEmpty && locations.isEmpty && rawInput == nil && rawOutput == nil
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

    /// Whether this item is the agent's thinking, which the session draws only when
    /// asked. The record keeps it either way.
    public var isThought: Bool {
        if case .entry(let entry) = self, case .agentThought = entry.kind { return true }
        return false
    }
}

extension Array where Element == TranscriptItem {
    /// The page with the agent's thinking left off it.
    ///
    /// A thought between two calls is what splits them into two runs. Once the
    /// thought is gone, nothing on the page separates those runs, so they are one
    /// run again: the latest description, and the rest a click away. A message, or
    /// anything else that stays, still starts a new run.
    public func omittingThoughts() -> [TranscriptItem] {
        filter { !$0.isThought }.joiningAdjacentToolRuns()
    }

    /// Runs with nothing drawn between them are one run. The first run's identity
    /// is kept, so a run the reader has opened stays open as later calls join it.
    public func joiningAdjacentToolRuns() -> [TranscriptItem] {
        var kept: [TranscriptItem] = []
        for item in self {
            if case .toolRun(_, let calls) = item,
               let last = kept.indices.last,
               case .toolRun(let id, let earlier) = kept[last] {
                kept[last] = .toolRun(id: id, calls: earlier + calls)
            } else {
                kept.append(item)
            }
        }
        return kept
    }
}

extension TranscriptEntry {
    /// Whether this entry is about a moment rather than about what happened.
    ///
    /// The agent starting, the agent working, the runtime being brought back: each
    /// is superseded by whatever comes next. An ending, an answer and a message are
    /// not, and stay. One ending is here all the same: an agent stopped because the
    /// daemon did is picked back up straight after, and once it has been, that stop
    /// is a moment too. An option change is not here because it is never drawn.
    public var isPassing: Bool {
        switch kind {
        case .stateChanged(.starting, _), .stateChanged(.running, _):
            return true
        case .stateChanged(.stopped, reason: .daemonGone):
            return true
        case .runtimeNote(let text):
            return RuntimeNote.isPassing(text)
        default:
            return false
        }
    }
}

extension TranscriptEntry {
    /// Whether this is the agent going on with its work, which is what makes a retried
    /// error before it a blip it got past (#394).
    var carriesOn: Bool {
        switch kind {
        case .agentMessage, .agentThought, .toolCall, .toolCallUpdate, .appView, .planUpdated,
             .permissionAsked, .elicitationAsked:
            return true
        default:
            return false
        }
    }

    /// Whether the work stopped here: the person spoke, or the agent ended. A retried
    /// error before this is the last thing the agent did, and stays.
    var endsTheWork: Bool {
        switch kind {
        case .userMessage:
            return true
        case .stateChanged(.starting, _), .stateChanged(.running, _):
            return false
        case .stateChanged:
            return true
        default:
            return false
        }
    }
}

/// The page as the chat draws it, kept up as entries arrive.
///
/// A reply arrives as a dozen chunks a second, and folding the whole page again for
/// each one — joining every chunk of every message, merging every tool call into its
/// run — is work that grows with the page and is repeated for every line of it. This
/// holds the fold and takes one entry at a time: a chunk that continues the last
/// message replaces the last item, a tool call joins the open run, and anything else
/// closes the run and is drawn after it.
///
/// A run is identified by the entry that opened it rather than by a fresh id each
/// time the page is folded. That is what lets the chat keep the row for a run — and
/// whether the reader has unfolded it — while the run is still going.
public struct TranscriptDisplayBuilder: Sendable {
    /// Everything drawn so far, with the open run not yet among it.
    private var drawn: [TranscriptItem] = []
    private var run: [ToolCall] = []
    private var runID: UUID?
    /// The suggestion calls we are not drawing. Kept by id because the update that
    /// follows one carries neither the name nor the title: on its own it reads as
    /// an anonymous "Tool call", and that is what would end up on screen.
    private var suppressed: Set<String> = []
    /// Where in `drawn` each closed run's calls are, by call id, for an update that
    /// arrives after something else has closed its run.
    private var closedRunAt: [String: Int] = [:]
    /// Where in `drawn` each view is (#187), by its call's id: the call's later entries
    /// carry its result, and the view stays where the call began.
    private var viewAt: [UUID: Int] = [:]
    /// The last entry taken, as it stands after joining, for the chunk that
    /// continues it.
    private var last: TranscriptEntry?
    /// How much of `drawn` is past the agent carrying on (#394). A retried error after
    /// this may still be what stopped the work; one before it has been dealt with: left
    /// out once the agent carried on, or kept because the turn ended on it.
    private var settled = 0
    /// Whose page this is: nil for the chat, which is the agent's own, or a subagent's
    /// id for that subagent's steps (057). Each leaves out everything the other says.
    public let subagent: String?

    public init(subagent: String? = nil) {
        self.subagent = subagent
    }

    public mutating func add(_ entry: TranscriptEntry) {
        // Before anything else, including the join: a subagent's chunk arriving between
        // two of the agent's is not part of either message.
        guard entry.subagentID == subagent else { return }
        if let last, let joined = TranscriptEntry.join(entry, onto: last) {
            // The chunk continues the last message. That message closed any run before
            // it and nothing has been drawn since, so it is the last item on the page.
            self.last = joined
            if !drawn.isEmpty { drawn[drawn.count - 1] = .entry(joined) }
            return
        }
        last = entry
        switch entry.kind {
        case .toolCall(let call), .toolCallUpdate(let call):
            // The app's own end-of-turn call is not drawn, by its name or the two it had.
            // It is not hidden work: what it did is the row of chips above the prompt
            // and the report at the foot of the conversation, and a line here saying
            // so would be the same thing said twice.
            if call.isFinishingTurn || call.isRetiredEndOfTurn {
                if let id = call.toolCallID { suppressed.insert(id) }
                return
            }
            if let id = call.toolCallID, suppressed.contains(id) { return }
            // An update is the same call further along, so it replaces the one
            // already in the run rather than adding a line to it.
            if let id = call.toolCallID, let existing = run.firstIndex(where: { $0.toolCallID == id }) {
                run[existing] = TranscriptEntry.merge(call, onto: run[existing])
            } else if case .toolCallUpdate = entry.kind, let id = call.toolCallID,
                      mergeIntoClosedRun(call, id: id) {
                // A call already drawn in a run that something has since closed: the
                // Bash call that starts a background shell finishes after the line
                // saying so (057). A new run would be a second, nameless "Tool call".
                return
            } else if case .toolCallUpdate = entry.kind, call.saysNothing {
                // An update for no call on the page that carries nothing to draw. Claude
                // sends one for a background Agent call whose tool_call never arrives
                // (057): on its own it is a line reading "Tool call" and nothing else.
                return
            } else {
                run.append(call)
            }
            if runID == nil { runID = entry.id }
            resolveIntermittentErrors()
        case .appView(let call):
            if let at = viewAt[call.id], drawn.indices.contains(at), case .entry(var first) = drawn[at] {
                first.kind = .appView(call)
                drawn[at] = .entry(first)
                return
            }
            closeRun()
            resolveIntermittentErrors()
            viewAt[call.id] = drawn.count
            drawn.append(.entry(entry))
        case .background(let item) where item.isRunning && item.kind == .task && item.toolCallID != nil:
            // A task starting from a tool call: the call is already on the page, and
            // says it runs on while it does (057). Not a break in the run either.
            return
        case .optionChanged:
            // Plumbing, not conversation. The mode or model in force is on the prompt
            // controls, which is where anyone looks for it; a line saying "mode is now
            // auto" told the reader nothing they could not already see, and every
            // runtime that announces its own setting at start put one on the page
            // before a word was said. Kept in the record, drawn as nothing, and not a
            // break in a run of tool calls either: a mode switched mid-turn is still
            // the same job of work.
            return
        case .servedRequest(let request) where request.isQuiet:
            // A read the app served. On the record, because what an agent touched is
            // worth being able to find; not on the page, because a read changes
            // nothing and the reply that follows is what the read was for. A write, a
            // refusal and a failure all still say so.
            return
        case .stateChanged(.finished, _), .usageRecorded:
            // The turn ending, and what it cost. Neither is drawn: the reply ending is
            // what says the turn did, and the money is counted where money is looked
            // for. Not a silent skip, though. A turn that ends still ends the run of
            // tool calls it was, and it still makes "Working" untrue, so it does what
            // any drawn line would do to the page and puts nothing on it.
            closeRun()
            supersedePassingLines()
            if case .stateChanged = entry.kind { settleIntermittentErrors() }
        default:
            closeRun()
            if entry.carriesOn {
                resolveIntermittentErrors()
            } else if entry.endsTheWork {
                settleIntermittentErrors()
            }
            drawn.append(.entry(entry))
        }
    }

    /// What a drawn line does to the passing lines before it, done by a line that
    /// is not drawn.
    private mutating func supersedePassingLines() {
        while let last = drawn.last, last.isPassing { drawn.removeLast() }
        settled = min(settled, drawn.count)
    }

    /// The work stopped, so every retried error since the agent last carried on stays,
    /// unless the message it is in went on past it.
    private mutating func settleIntermittentErrors() {
        Self.leaveOutErrorsPassedInMessage(&drawn, from: settled)
        settled = drawn.count
    }

    /// Each message from `from` on with the retried errors it went on past left out.
    private static func leaveOutErrorsPassedInMessage(_ all: inout [TranscriptItem], from: Int) {
        for index in all.indices where index >= from {
            guard case .entry(var entry) = all[index],
                  case .agentMessage(let id, let text, let blocks) = entry.kind, blocks.isEmpty,
                  let rest = IntermittentError.without(in: text, all: false) else { continue }
            entry.kind = .agentMessage(messageID: id, text: rest, blocks: blocks)
            all[index] = .entry(entry)
        }
    }

    /// The agent has carried on, so every retried error since the last time it did was
    /// a blip it got past: those lines leave the page, and a message that was nothing
    /// else leaves with them. Only lines after every run and view are ever taken off,
    /// since anything that carries on moves `settled` past it, so their places hold.
    private mutating func resolveIntermittentErrors() {
        for index in drawn.indices.reversed() where index >= settled {
            guard case .entry(var entry) = drawn[index],
                  case .agentMessage(let id, let text, let blocks) = entry.kind, blocks.isEmpty,
                  let rest = IntermittentError.without(in: text, all: true) else { continue }
            if rest.isEmpty {
                drawn.remove(at: index)
            } else {
                entry.kind = .agentMessage(messageID: id, text: rest, blocks: blocks)
                drawn[index] = .entry(entry)
            }
        }
        settled = drawn.count
    }

    /// Merge an update into the closed run that holds its call, if one does.
    private mutating func mergeIntoClosedRun(_ update: ToolCall, id: String) -> Bool {
        guard let at = closedRunAt[id], drawn.indices.contains(at),
              case .toolRun(let runID, var calls) = drawn[at],
              let index = calls.firstIndex(where: { $0.toolCallID == id }) else { return false }
        calls[index] = TranscriptEntry.merge(update, onto: calls[index])
        drawn[at] = .toolRun(id: runID, calls: calls)
        return true
    }

    private mutating func closeRun() {
        guard !run.isEmpty, let runID else { return }
        // Only lines after a run are ever taken back off `drawn`, so its place holds.
        for id in run.compactMap(\.toolCallID) { closedRunAt[id] = drawn.count }
        drawn.append(.toolRun(id: runID, calls: run))
        run = []
        self.runID = nil
    }

    /// What the chat shows now: everything drawn, the open run after it, and the
    /// passing lines that something has since superseded left out.
    public var items: [TranscriptItem] {
        var all = drawn
        Self.leaveOutErrorsPassedInMessage(&all, from: settled)
        if !run.isEmpty, let runID { all.append(.toolRun(id: runID, calls: run)) }
        return TranscriptEntry.withoutSupersededPassingLines(all)
    }
}
