import Foundation

/// What a `session/update` notification turns into.
///
/// All sixteen kinds the protocol defines. An unfamiliar kind is reported once and
/// skipped: a new update type shipping in a runtime must never stop an agent working.
public enum SessionUpdate: Sendable {
    case entry(TranscriptEntry.Kind)
    case options([ConfigOption])
    case commands([SlashCommand])
    case modeChanged(String)
    case title(String)
    /// A typed failure on a `session_info_update`, with the title the same update gave
    /// the session if it gave one (052).
    case failure(SessionFailure, title: String?)
    case usage(Usage)
    case plan(Plan)
    case planRemoved(String)
    /// A shell or a subagent the agent left running (057). Only sent to a client that
    /// said it could show them.
    case background(BackgroundUpdate)
    case ignored(String)
    case unknown(String)

    public static func decode(_ update: JSONValue) -> SessionUpdate {
        guard let kind = update["sessionUpdate"]?.stringValue else { return .unknown("no sessionUpdate") }
        switch kind {
        case "agent_message_chunk":
            let blocks = [ContentBlock](wire: update["content"])
            return .entry(.agentMessage(messageID: update["messageId"]?.stringValue,
                                        text: blocks.plainText,
                                        blocks: blocks.containsOnlyText ? [] : blocks))
        case "agent_thought_chunk":
            return .entry(.agentThought(messageID: update["messageId"]?.stringValue,
                                        text: [ContentBlock](wire: update["content"]).plainText))
        case "user_message_chunk":
            let blocks = [ContentBlock](wire: update["content"])
            return .entry(.userMessage(blocks.plainText,
                                       blocks: blocks.containsOnlyText ? [] : blocks))
        case "tool_call":
            return .entry(.toolCall(toolCall(in: update)))
        case "tool_call_update":
            return .entry(.toolCallUpdate(toolCall(in: update)))
        case "plan":
            // The unidentified plan: one at a time, replaced by the next.
            return .plan(Plan(planID: nil, entries: entries(in: update["entries"])))
        case "plan_update":
            let plan = update["plan"] ?? update
            guard let id = plan["planId"]?.stringValue else { return .unknown(kind) }
            return .plan(Plan(planID: id, entries: entries(in: plan["entries"])))
        case "plan_removed":
            guard let id = (update["plan"] ?? update)["planId"]?.stringValue else { return .unknown(kind) }
            return .planRemoved(id)
        case "config_option_update":
            return .options(ConfigOption.list(in: update["configOptions"]))
        case "current_mode_update":
            guard let mode = update["currentModeId"]?.stringValue else { return .unknown(kind) }
            return .modeChanged(mode)
        case "session_info_update":
            let title = update["title"]?.stringValue
            if let failure = SessionFailure.from(meta: update["_meta"]) { return .failure(failure, title: title) }
            guard let title else { return .ignored(kind) }
            return .title(title)
        case "available_commands_update":
            let listed = update["availableCommands"]?.arrayValue ?? []
            return .commands(listed.compactMap(SlashCommand.init(wire:)))
        case "usage_update":
            guard let used = update["used"]?.intValue else { return .ignored(kind) }
            // No size is a window we do not know, which the meter hides itself for. It
            // is not a reason to drop the update: the cost rides in on it.
            let size = update["size"]?.intValue ?? 0
            var usage = Usage(used: used, size: size, cost: Cost(wire: update["cost"]))
            // Claude's plan window rides on the same update (052, R2).
            usage.rateLimit = RateLimitInfo.from(meta: update["_meta"])
            return .usage(usage)
        case "compaction_update":
            return .entry(.compaction(status: update["status"]?.stringValue ?? "in_progress",
                                      summary: [ContentBlock](wire: update["summary"])))
        case "notice":
            guard let notice = SessionNotice(wire: update) else { return .ignored(kind) }
            return .entry(.notice(notice))
        case "compaction_summary_chunk":
            return .entry(.compaction(status: "in_progress",
                                      summary: [ContentBlock](wire: update["content"])))
        case "async_task_spawned", "async_task_progress", "async_task_state_update",
             "subagent_spawned", "subagent_state_update":
            guard let background = BackgroundUpdate.decode(update) else { return .unknown(kind) }
            return .background(background)
        default:
            return .unknown(kind)
        }
    }

    private static func entries(in value: JSONValue?) -> [PlanEntry] {
        (value?.arrayValue ?? []).compactMap(PlanEntry.init(wire:))
    }

    private static func toolCall(in update: JSONValue) -> ToolCall {
        ToolCall(toolCallID: update["toolCallId"]?.stringValue,
                 title: update["title"]?.stringValue ?? update["kind"]?.stringValue ?? "Tool call",
                 name: update["name"]?.stringValue,
                 kind: update["kind"]?.stringValue,
                 status: update["status"]?.stringValue,
                 content: (update["content"]?.arrayValue ?? []).map(ToolCallContent.init(wire:)),
                 locations: (update["locations"]?.arrayValue ?? []).compactMap(ToolCallLocation.init(wire:)),
                 rawInput: update["rawInput"],
                 rawOutput: update["rawOutput"],
                 raw: ToolCall.trimmingParsedFields(update))
    }
}

private extension [ContentBlock] {
    /// Text-only content is stored as text, the way it always was. Blocks are kept only
    /// when there is something in them that text cannot hold.
    var containsOnlyText: Bool {
        allSatisfy { if case .text = $0 { return true } else { return false } }
    }
}
