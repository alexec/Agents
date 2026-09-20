import Foundation

/// A question the agent is blocked on.
///
/// It is a request, not a notification: the runtime waits until one of its own options
/// comes back. A typed message is not an answer to it, which is why this exists at all
/// and why the daemon has to hold one while there is no window open.
public struct PermissionRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var agentID: UUID
    public var toolCall: ToolCall
    public var options: [PermissionOption]
    public var askedAt: Date

    public init(id: UUID = UUID(), agentID: UUID, toolCall: ToolCall,
                options: [PermissionOption], askedAt: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.toolCall = toolCall
        self.options = options
        self.askedAt = askedAt
    }
}

public struct PermissionOption: Codable, Hashable, Sendable, Identifiable {
    public var optionID: String
    public var name: String
    public var kind: Kind

    public var id: String { optionID }

    public enum Kind: String, Codable, Hashable, Sendable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"
        case unknown

        public init(wire: String?) {
            self = Kind(rawValue: wire ?? "") ?? .unknown
        }

        public var allows: Bool { self == .allowOnce || self == .allowAlways }
    }

    public init(optionID: String, name: String, kind: Kind) {
        self.optionID = optionID
        self.name = name
        self.kind = kind
    }
}

/// What an agent is doing, or wants to do. Kept loosely, because every runtime
/// describes its tools differently and none of that is ours to standardise.
public struct ToolCall: Codable, Hashable, Sendable {
    public var toolCallID: String?
    public var title: String
    /// The runtime's own name for the tool, which is not always the title it shows.
    public var name: String?
    public var kind: String?
    public var status: String?
    /// What it produced: diffs, output, blocks of content. Appended as updates arrive,
    /// because a tool call's content comes in pieces and the last piece is not the
    /// whole story.
    public var content: [ToolCallContent]
    public var locations: [ToolCallLocation]
    /// What it was called with, and what came back. Kept apart, because an update that
    /// carries only the output must not lose the input. That was the bug.
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    /// The rest of what arrived, for the parts of the UI that want detail: whatever
    /// the fields above did not take. Never `content`, `rawInput` or `rawOutput` —
    /// those are parsed out and kept above, and keeping them here as well stored a
    /// screenshot four times over (`trimmingParsedFields`).
    public var raw: JSONValue?

    public init(toolCallID: String? = nil, title: String, name: String? = nil,
                kind: String? = nil, status: String? = nil,
                content: [ToolCallContent] = [], locations: [ToolCallLocation] = [],
                rawInput: JSONValue? = nil, rawOutput: JSONValue? = nil,
                raw: JSONValue? = nil) {
        self.toolCallID = toolCallID
        self.title = title
        self.name = name
        self.kind = kind
        self.status = status
        // Whatever was handed over whole and not as a field of its own is split out
        // here, the same way an update off the wire is: a permission question hands
        // over the whole tool call, and a record written before these fields existed
        // holds only the whole update. Either way the fields end up filled and `raw`
        // ends up trimmed, so nothing has to look in two places.
        self.content = content.isEmpty
            ? (raw?["content"]?.arrayValue ?? []).map(ToolCallContent.init(wire:)) : content
        self.locations = locations.isEmpty
            ? (raw?["locations"]?.arrayValue ?? []).compactMap(ToolCallLocation.init(wire:)) : locations
        self.rawInput = rawInput ?? raw?["rawInput"]
        self.rawOutput = rawOutput ?? raw?["rawOutput"]
        self.raw = Self.trimmingParsedFields(raw)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field past `status` is new in 003. A record written before it has none.
        // Through the same initialiser as everything else, so a record from before
        // the fields existed is split the same way, and a record written with the
        // copies still in `raw` is trimmed as it is read: an old chat costs no more
        // to open than a new one.
        self.init(toolCallID: try c.decodeIfPresent(String.self, forKey: .toolCallID),
                  title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Tool call",
                  name: try c.decodeIfPresent(String.self, forKey: .name),
                  kind: try c.decodeIfPresent(String.self, forKey: .kind),
                  status: try c.decodeIfPresent(String.self, forKey: .status),
                  content: try c.decodeIfPresent([ToolCallContent].self, forKey: .content) ?? [],
                  locations: try c.decodeIfPresent([ToolCallLocation].self, forKey: .locations) ?? [],
                  rawInput: try c.decodeIfPresent(JSONValue.self, forKey: .rawInput),
                  rawOutput: try c.decodeIfPresent(JSONValue.self, forKey: .rawOutput),
                  raw: try c.decodeIfPresent(JSONValue.self, forKey: .raw))
    }

    /// `raw` without the parts that are kept as fields of their own.
    ///
    /// A tool call's update carries `content`, `rawInput` and `rawOutput`, and each
    /// of those is parsed into a field above. Keeping the update whole beside them
    /// meant every byte of a tool's output was in the record twice, and a screenshot
    /// — which the Claude adapter sends as content *and* as raw output — four times:
    /// two megabytes for one call, and a chat whose page took seconds to load. What
    /// is left is what nothing else took: the title, the kind, the status, the
    /// locations, and any key a runtime invents.
    public static func trimmingParsedFields(_ raw: JSONValue?) -> JSONValue? {
        guard case .object(var fields)? = raw else { return raw }
        for key in ["content", "rawInput", "rawOutput"] { fields.removeValue(forKey: key) }
        return .object(fields)
    }

    /// The one line the chat draws for this call.
    ///
    /// A runtime's title is its machinery: a command line, a path, a tool name. Where
    /// the agent wrote a `description` argument, that sentence was written for a person
    /// to read, and it is the better line by a distance. Shown on its own, not beside
    /// the title, because saying the same thing twice is the annoyance.
    public var line: String {
        let described = rawInput?["description"]?.stringValue
        if let described, !described.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return described
        }
        return title
    }

    /// Whether this is the app's own suggestion tool rather than the agent's work.
    ///
    /// Matched on the end of the name because a runtime is free to prefix it: the
    /// Claude adapter shows it as `mcp__agents__suggest_next_prompts`.
    public var isSuggestingPrompts: Bool {
        (name ?? title).hasSuffix(AppTool.suggestPrompts)
    }

    /// Whether this is the app's own show-file tool.
    public var isShowingFile: Bool {
        (name ?? title).hasSuffix(AppTool.showFile)
    }

    /// Whether this is the app's own workflow tool.
    public var isManagingWorkflows: Bool {
        (name ?? title).hasSuffix(AppTool.manageWorkflows)
    }

    /// Whether this is the app's own outcome tool.
    public var isReportingOutcome: Bool {
        (name ?? title).hasSuffix(AppTool.reportOutcome)
    }

    /// Whether this call is the app's own rather than the agent's work at all.
    public var isTheApps: Bool {
        isSuggestingPrompts || isShowingFile || isManagingWorkflows || isReportingOutcome
    }

    /// Whether the app may answer the runtime's permission question itself.
    ///
    /// All three of the app's own tools, because none of them is a question worth
    /// putting to somebody. Suggestions and a read-only pane carry no information to
    /// decide on; a workflow is answerable *after* it exists, on the project page,
    /// where it can be paused or archived by somebody who has seen what it does. A
    /// sheet in front of the writing would only make the uninformed answer the quick
    /// one — and, under a runtime that asks before every call, would stop the writing
    /// dead whenever nobody was looking.
    public var isAutoAllowable: Bool { isTheApps }

    /// The diffs this call carries, which is what the transcript draws first.
    public var diffs: [ToolCallContent.Diff] {
        content.compactMap { if case .diff(let diff) = $0 { return diff } else { return nil } }
    }
}
