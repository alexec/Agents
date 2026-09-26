import Foundation

/// Something an agent left running while it went on (057): a shell, a workflow, a
/// monitor, or a subagent of its own.
///
/// Sent by a runtime that the app told it can show these, through the JetBrains "AIR"
/// opt-in (`asyncTasks`, `nativeSubagentSessions`). Keyed on what arrives, never on which
/// runtime sent it: Claude and Codex speak the same five updates.
///
/// The running ones are drawn over the prompt, each shell with Stop. A finished one is
/// kept a while so a subagent's steps can still be opened after it is done.
public struct BackgroundItem: Codable, Hashable, Sendable, Identifiable {
    /// The runtime's own id: `asyncTaskId` for a task, `subagentSessionId` for a
    /// subagent. What Stop sends back.
    public var id: String
    public var kind: Kind
    /// The runtime's short name for it: "Print a tick every second", "Count files".
    public var name: String
    /// A task's type as the runtime says it: `shell`, `workflow`, `monitor`, `task`.
    /// Nil for a subagent.
    public var taskType: String?
    /// A task's description (for a shell, its command), or what a subagent was asked.
    public var detail: String?
    /// A shell's command line, when the tool call that started it said. The row leads
    /// with the runtime's plain name for it and keeps this for hovering (Alex, 2026-09-26):
    /// `async_task_spawned` carries only the description, so it is found on the call.
    public var command: String?
    public var state: State
    /// Whether the runtime says Stop works on it. A task says so itself; a subagent says
    /// so with `capabilities.cancel`, which no runtime sends yet (research, 057).
    public var canStop: Bool
    /// Stop was pressed and the runtime has not answered yet.
    public var isStopping: Bool
    /// The subagent that started it, when it was not the agent itself.
    public var parentID: String?
    /// The tool call it came from, so the card in the chat can say it runs on.
    public var toolCallID: String?
    /// Where a task writes what it prints. The runtime's own file.
    public var outputFilePath: String?
    /// The latest line the runtime gave about it, and the tool it last used.
    public var summary: String?
    public var lastToolName: String?
    public var startedAt: Date
    public var endedAt: Date?

    public enum Kind: String, Codable, Hashable, Sendable {
        case task
        case subagent
    }

    public enum State: String, Codable, Hashable, Sendable {
        case running
        case paused
        case completed
        case failed
        /// Stopped: a task by Stop, a subagent by the agent being stopped.
        case stopped
        /// The runtime went, and took it with it: the app lets a runtime go when its
        /// turn ends (Alex, 2026-09-26), so this is how a shell left running ends. Ours,
        /// not the runtime's.
        case disconnected

        public var isRunning: Bool { self == .running || self == .paused }

        /// Read leniently: an unknown word from a newer runtime is not a reason to
        /// lose the row. Anything terminal we have not heard of is an ending.
        init(wire: String?) {
            switch wire {
            case "running", "pending": self = .running
            case "paused": self = .paused
            case "completed": self = .completed
            case "failed": self = .failed
            case "stopped", "cancelled", "killed": self = .stopped
            case "disconnected": self = .disconnected
            default: self = .completed
            }
        }
    }

    public init(id: String, kind: Kind, name: String, taskType: String? = nil,
                detail: String? = nil, state: State = .running, canStop: Bool = false,
                isStopping: Bool = false, parentID: String? = nil, toolCallID: String? = nil,
                outputFilePath: String? = nil, summary: String? = nil, lastToolName: String? = nil,
                startedAt: Date = Date(), endedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.taskType = taskType
        self.detail = detail
        self.state = state
        self.canStop = canStop
        self.isStopping = isStopping
        self.parentID = parentID
        self.toolCallID = toolCallID
        self.outputFilePath = outputFilePath
        self.summary = summary
        self.lastToolName = lastToolName
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var isRunning: Bool { state.isRunning }

    /// Stop is offered: it runs, the runtime says Stop works on it, and it is not
    /// already on its way out.
    public var offersStop: Bool { isRunning && canStop && !isStopping }

    public var isShell: Bool { kind == .task && taskType == "shell" }
}

/// One of the five updates, read off the wire.
public enum BackgroundUpdate: Sendable, Hashable {
    /// `async_task_spawned` or `subagent_spawned`. `parentID` is the session it was
    /// announced under, when that was a subagent's rather than the agent's.
    case spawned(BackgroundItem)
    /// `async_task_progress`: whatever changed, and nothing else.
    case progress(id: String, detail: String?, summary: String?, lastToolName: String?,
                  outputFilePath: String?, toolCallID: String?)
    /// `async_task_state_update` or `subagent_state_update`.
    case state(id: String, BackgroundItem.State, summary: String?, outputFilePath: String?)

    public var itemID: String {
        switch self {
        case .spawned(let item): return item.id
        case .progress(let id, _, _, _, _, _), .state(let id, _, _, _): return id
        }
    }

    /// Read one of the five, or nil for any other kind or one missing its id.
    public static func decode(_ update: JSONValue, now: Date = Date()) -> BackgroundUpdate? {
        func text(_ key: String) -> String? {
            guard let value = update[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        switch update["sessionUpdate"]?.stringValue {
        case "async_task_spawned":
            guard let id = text("asyncTaskId") else { return nil }
            let detail = text("description")
            return .spawned(BackgroundItem(
                id: id, kind: .task, name: text("name") ?? detail ?? "Background task",
                taskType: text("taskType") ?? "task", detail: detail,
                canStop: update["canStop"]?.boolValue ?? false,
                toolCallID: text("toolCallId"), outputFilePath: text("outputFilePath"),
                startedAt: now))
        case "subagent_spawned":
            guard let id = text("subagentSessionId") else { return nil }
            return .spawned(BackgroundItem(
                id: id, kind: .subagent, name: text("name") ?? "Subagent", detail: text("task"),
                canStop: update["capabilities"]?["cancel"]?.boolValue ?? false,
                startedAt: now))
        case "async_task_progress":
            guard let id = text("asyncTaskId") else { return nil }
            return .progress(id: id, detail: text("description"), summary: text("summary"),
                             lastToolName: text("lastToolName"),
                             outputFilePath: text("outputFilePath"), toolCallID: text("toolCallId"))
        case "async_task_state_update":
            guard let id = text("asyncTaskId") else { return nil }
            return .state(id: id, BackgroundItem.State(wire: text("state")),
                          summary: text("summary"), outputFilePath: text("outputFilePath"))
        case "subagent_state_update":
            guard let id = text("subagentSessionId") else { return nil }
            return .state(id: id, BackgroundItem.State(wire: text("state")),
                          summary: nil, outputFilePath: nil)
        default:
            return nil
        }
    }
}

extension BackgroundItem {
    /// How many finished ones an agent keeps. Enough to open the steps of a subagent
    /// that has just finished; not a history, which the transcript already is.
    public static let finishedKept = 12

    /// Apply an update to an agent's list. Returns the list and, when the update
    /// changed something worth a line in the chat, the item as it now stands.
    ///
    /// Tolerant by construction, because the capture showed a real runtime repeat
    /// itself: Claude sends `stopped` twice for one Stop. A second ending of the same
    /// item changes nothing and says nothing.
    public static func applying(_ update: BackgroundUpdate, to items: [BackgroundItem],
                                now: Date = Date()) -> (items: [BackgroundItem], announce: BackgroundItem?) {
        var items = items
        switch update {
        case .spawned(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                // Announced again (Codex reopens a subagent as a new generation under a
                // new id, so this is only ever the same one said twice). Keep what we
                // had learned and take what is new.
                var merged = items[index]
                merged.name = item.name
                merged.detail = item.detail ?? merged.detail
                merged.command = item.command ?? merged.command
                merged.canStop = item.canStop
                merged.toolCallID = item.toolCallID ?? merged.toolCallID
                merged.outputFilePath = item.outputFilePath ?? merged.outputFilePath
                items[index] = merged
                return (items, nil)
            }
            items.append(item)
            return (trimmed(items), item)
        case .progress(let id, let detail, let summary, let lastToolName, let output, let toolCallID):
            guard let index = items.firstIndex(where: { $0.id == id }) else { return (items, nil) }
            if let detail { items[index].detail = detail }
            if let summary { items[index].summary = summary }
            if let lastToolName { items[index].lastToolName = lastToolName }
            if let output { items[index].outputFilePath = output }
            if let toolCallID { items[index].toolCallID = toolCallID }
            return (items, nil)
        case .state(let id, let state, let summary, let output):
            guard let index = items.firstIndex(where: { $0.id == id }) else { return (items, nil) }
            if let output { items[index].outputFilePath = output }
            if let summary { items[index].summary = summary }
            let wasRunning = items[index].isRunning
            // A running report after an ending is late, not a revival.
            if !wasRunning, state.isRunning { return (items, nil) }
            // An ending after an ending is the runtime correcting itself: Claude says
            // `stopped` from its level-triggered list and then `completed` from the task
            // itself (captured). The row takes the better word; the chat has its line.
            items[index].state = state
            if state.isRunning { return (items, nil) }
            items[index].isStopping = false
            guard wasRunning else { return (items, nil) }
            items[index].endedAt = now
            return (trimmed(items), items[index])
        }
    }

    /// Everything still running is over: the runtime that ran it is gone.
    public static func disconnecting(_ items: [BackgroundItem], now: Date = Date()) -> [BackgroundItem] {
        items.map { item in
            guard item.isRunning else { return item }
            var ended = item
            ended.state = .disconnected
            ended.isStopping = false
            ended.endedAt = now
            return ended
        }
    }

    /// Running ones kept whole; the finished ones cut to the newest few.
    static func trimmed(_ items: [BackgroundItem]) -> [BackgroundItem] {
        let finished = items.filter { !$0.isRunning }
        guard finished.count > finishedKept else { return items }
        let dropped = Set(finished.prefix(finished.count - finishedKept).map(\.id))
        return items.filter { !dropped.contains($0.id) }
    }
}

/// The words for background work, the same on the Mac and the phone.
public enum BackgroundWords {
    /// "1 shell, 1 subagent in the background". Nil when nothing runs.
    public static func mark(_ items: [BackgroundItem]) -> String? {
        let running = items.filter(\.isRunning)
        guard !running.isEmpty else { return nil }
        let shells = running.filter(\.isShell).count
        let subagents = running.filter { $0.kind == .subagent }.count
        let others = running.count - shells - subagents
        var parts: [String] = []
        if shells > 0 { parts.append(shells == 1 ? "1 shell" : "\(shells) shells") }
        if subagents > 0 { parts.append(subagents == 1 ? "1 subagent" : "\(subagents) subagents") }
        if others > 0 { parts.append(others == 1 ? "1 task" : "\(others) tasks") }
        return parts.joined(separator: ", ") + " in the background"
    }

    /// The symbol for one: a subagent is a person, anything else a prompt.
    public static func symbol(_ item: BackgroundItem) -> String {
        item.kind == .subagent ? "person.crop.circle.badge.clock" : "apple.terminal"
    }

    /// What kind of thing it is, in a word.
    public static func noun(_ item: BackgroundItem) -> String {
        if item.kind == .subagent { return "Subagent" }
        switch item.taskType {
        case "shell": return "Shell"
        case "workflow": return "Workflow"
        case "monitor": return "Monitor"
        default: return "Task"
        }
    }

    /// The line the chat keeps when one ends: "Subagent “Count files” finished".
    public static func ending(_ item: BackgroundItem) -> String {
        let what = "\(noun(item)) “\(item.name)”"
        switch item.state {
        case .completed: return "\(what) finished"
        case .failed: return "\(what) failed"
        case .stopped: return "\(what) stopped"
        case .disconnected: return "\(what) ended with the turn"
        case .running, .paused: return "\(what) is running in the background"
        }
    }

    /// How it ended, in a word or two, for a row that is still listed after it has:
    /// "Stopped", "Finished". Nil while it runs.
    public static func ended(_ item: BackgroundItem) -> String? {
        switch item.state {
        case .completed: return "Finished"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .disconnected: return "Ended with the turn"
        case .running, .paused: return nil
        }
    }

    /// How long it has run, or ran: "0:37", "12:04", "1:02:10".
    public static func age(_ item: BackgroundItem, now: Date = Date()) -> String {
        let seconds = max(0, Int((item.endedAt ?? now).timeIntervalSince(item.startedAt)))
        let (h, m, s) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
