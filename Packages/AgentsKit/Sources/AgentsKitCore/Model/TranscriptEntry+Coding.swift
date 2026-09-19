import Foundation

/// How an entry is written down, spelled out rather than synthesised.
///
/// Three reasons it is by hand. A record written by an older version must still read,
/// so the keys 001 wrote are the keys we still write. A record written by a newer
/// version must not lose an older reader its transcript, so a kind we do not know is
/// kept whole rather than throwing. And the new fields are added to existing cases,
/// which a synthesised decoder would demand of every old entry.
extension TranscriptEntry.Kind {
    public init(from decoder: any Decoder) throws {
        let raw = try JSONValue(from: decoder)
        // A kind we cannot read is something that happened, written by a version that
        // knew what it was. Kept whole rather than thrown.
        self = Self.read(raw) ?? .unrecognised(raw)
    }

    private static func read(_ raw: JSONValue) -> TranscriptEntry.Kind? {
        guard let object = raw.objectValue, let name = object.keys.first,
              let payload = object[name] else { return nil }
        switch name {
        case "userMessage":
            return .userMessage(payload["_0"]?.stringValue ?? "",
                                blocks: [ContentBlock](wire: payload["blocks"]))
        case "agentMessage":
            return .agentMessage(messageID: payload["messageID"]?.stringValue,
                                 text: payload["text"]?.stringValue ?? "",
                                 blocks: [ContentBlock](wire: payload["blocks"]))
        case "agentThought":
            return .agentThought(messageID: payload["messageID"]?.stringValue,
                                 text: payload["text"]?.stringValue ?? "")
        case "toolCall", "toolCallUpdate":
            guard let call = try? payload["_0"]?.decode(ToolCall.self) else { return nil }
            return name == "toolCall" ? .toolCall(call) : .toolCallUpdate(call)
        case "plan":
            return .plan(payload["_0"] ?? .null)
        case "planUpdated":
            guard let plan = try? payload["_0"]?.decode(Plan.self) else { return nil }
            return .planUpdated(plan)
        case "usageRecorded":
            guard let usage = try? payload["_0"]?.decode(TurnUsage.self) else { return nil }
            return .usageRecorded(usage)
        case "servedRequest":
            guard let request = try? payload["_0"]?.decode(ServedRequest.self) else { return nil }
            return .servedRequest(request)
        case "elicitationAsked":
            guard let request = try? payload["_0"]?.decode(ElicitationRequest.self) else { return nil }
            return .elicitationAsked(request)
        case "elicitationAnswered":
            guard let id = payload["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
            return .elicitationAnswered(id: id, summary: payload["summary"]?.stringValue ?? "")
        case "compaction":
            return .compaction(status: payload["status"]?.stringValue ?? "",
                               summary: [ContentBlock](wire: payload["summary"]))
        case "permissionAsked":
            guard let request = try? payload["_0"]?.decode(PermissionRequest.self) else { return nil }
            return .permissionAsked(request)
        case "permissionAnswered":
            return .permissionAnswered(optionID: payload["optionID"]?.stringValue ?? "",
                                       optionName: payload["optionName"]?.stringValue)
        case "optionChanged":
            return .optionChanged(id: payload["id"]?.stringValue ?? "",
                                  value: payload["value"] ?? .null)
        case "stateChanged":
            guard let state = try? payload["_0"]?.decode(AgentState.self) else { return nil }
            return .stateChanged(state, reason: try? payload["reason"]?.decode(EndedReason.self))
        case "runtimeNote":
            return .runtimeNote(payload["_0"]?.stringValue ?? "")
        default:
            return nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try wire.encode(to: encoder)
    }

    var wire: JSONValue {
        switch self {
        case .userMessage(let text, let blocks):
            var payload: [String: JSONValue] = ["_0": .string(text)]
            if !blocks.isEmpty { payload["blocks"] = blocks.wire }
            return ["userMessage": .object(payload)]
        case .agentMessage(let messageID, let text, let blocks):
            var payload: [String: JSONValue] = ["text": .string(text)]
            if let messageID { payload["messageID"] = .string(messageID) }
            if !blocks.isEmpty { payload["blocks"] = blocks.wire }
            return ["agentMessage": .object(payload)]
        case .agentThought(let messageID, let text):
            var payload: [String: JSONValue] = ["text": .string(text)]
            if let messageID { payload["messageID"] = .string(messageID) }
            return ["agentThought": .object(payload)]
        case .toolCall(let call):
            return ["toolCall": ["_0": (try? JSONValue.encoding(call)) ?? .null]]
        case .toolCallUpdate(let call):
            return ["toolCallUpdate": ["_0": (try? JSONValue.encoding(call)) ?? .null]]
        case .plan(let value):
            return ["plan": ["_0": value]]
        case .planUpdated(let plan):
            return ["planUpdated": ["_0": (try? JSONValue.encoding(plan)) ?? .null]]
        case .usageRecorded(let usage):
            return ["usageRecorded": ["_0": (try? JSONValue.encoding(usage)) ?? .null]]
        case .servedRequest(let request):
            return ["servedRequest": ["_0": (try? JSONValue.encoding(request)) ?? .null]]
        case .elicitationAsked(let request):
            return ["elicitationAsked": ["_0": (try? JSONValue.encoding(request)) ?? .null]]
        case .elicitationAnswered(let id, let summary):
            return ["elicitationAnswered": ["id": .string(id.uuidString), "summary": .string(summary)]]
        case .compaction(let status, let summary):
            return ["compaction": ["status": .string(status), "summary": summary.wire]]
        case .permissionAsked(let request):
            return ["permissionAsked": ["_0": (try? JSONValue.encoding(request)) ?? .null]]
        case .permissionAnswered(let optionID, let optionName):
            var payload: [String: JSONValue] = ["optionID": .string(optionID)]
            if let optionName { payload["optionName"] = .string(optionName) }
            return ["permissionAnswered": .object(payload)]
        case .optionChanged(let id, let value):
            return ["optionChanged": ["id": .string(id), "value": value]]
        case .stateChanged(let state, let reason):
            var payload: [String: JSONValue] = ["_0": (try? JSONValue.encoding(state)) ?? .null]
            if let reason { payload["reason"] = (try? JSONValue.encoding(reason)) ?? .null }
            return ["stateChanged": .object(payload)]
        case .runtimeNote(let text):
            return ["runtimeNote": ["_0": .string(text)]]
        case .unrecognised(let raw):
            // Written back exactly as it was read, so passing a record through an
            // older build does not quietly delete what it did not understand.
            return raw
        }
    }
}
