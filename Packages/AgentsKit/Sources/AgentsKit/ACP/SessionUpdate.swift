import Foundation

/// What a `session/update` notification turns into.
///
/// Every kind below was seen coming out of a real runtime. An unfamiliar kind is
/// reported once and skipped: a new update type shipping in a runtime must never stop
/// an agent working.
public enum SessionUpdate: Sendable {
    case entry(TranscriptEntry.Kind)
    case options([ConfigOption])
    case commands([SlashCommand])
    case modeChanged(String)
    case title(String)
    case ignored(String)
    case unknown(String)

    public static func decode(_ update: JSONValue) -> SessionUpdate {
        guard let kind = update["sessionUpdate"]?.stringValue else { return .unknown("no sessionUpdate") }
        switch kind {
        case "agent_message_chunk":
            return .entry(.agentMessage(messageID: update["messageId"]?.stringValue,
                                        text: text(in: update)))
        case "agent_thought_chunk":
            return .entry(.agentThought(messageID: update["messageId"]?.stringValue,
                                        text: text(in: update)))
        case "user_message_chunk":
            return .entry(.userMessage(text(in: update)))
        case "tool_call":
            return .entry(.toolCall(toolCall(in: update)))
        case "tool_call_update":
            return .entry(.toolCallUpdate(toolCall(in: update)))
        case "plan":
            return .entry(.plan(update))
        case "config_option_update":
            let options = (try? update["configOptions"]?.decode([ConfigOption].self)) ?? nil
            return .options(options ?? [])
        case "current_mode_update":
            guard let mode = update["currentModeId"]?.stringValue else { return .unknown(kind) }
            return .modeChanged(mode)
        case "session_info_update":
            guard let title = update["title"]?.stringValue else { return .ignored(kind) }
            return .title(title)
        case "available_commands_update":
            let listed = update["availableCommands"]?.arrayValue ?? []
            return .commands(listed.compactMap(SlashCommand.init(wire:)))
        case "usage_update":
            // Token counts are a later feature. Named here so that "ignored on
            // purpose" and "not recognised" stay different things.
            return .ignored(kind)
        default:
            return .unknown(kind)
        }
    }

    /// Content arrives either as one block or as a list of them.
    private static func text(in update: JSONValue) -> String {
        guard let content = update["content"] else { return "" }
        if let single = content["text"]?.stringValue { return single }
        if let blocks = content.arrayValue {
            return blocks.compactMap { $0["text"]?.stringValue }.joined()
        }
        return ""
    }

    private static func toolCall(in update: JSONValue) -> ToolCall {
        ToolCall(toolCallID: update["toolCallId"]?.stringValue,
                 title: update["title"]?.stringValue ?? update["kind"]?.stringValue ?? "Tool call",
                 kind: update["kind"]?.stringValue,
                 status: update["status"]?.stringValue,
                 raw: update)
    }
}
