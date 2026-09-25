import Foundation

/// Something the agent thinks you might want to say next.
///
/// The protocol has no way to send one: every "suggestion" in ACP is a code edit. So
/// these arrive the only way an agent can hand the app something of its own, which is
/// a tool call against an MCP server we serve. `AppService` is that server.
///
/// A suggestion is a draft, never an instruction. Tapping one fills the prompt and
/// leaves the cursor in it: what goes to the runtime is still what the user sent.
public struct SuggestedPrompt: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The few words on the chip.
    public var label: String
    /// What goes into the prompt when it is tapped, which is usually longer.
    public var prompt: String

    public init(id: UUID = UUID(), label: String, prompt: String) {
        self.id = id
        self.label = label
        self.prompt = prompt
    }

    /// The most one turn may offer: one (031). The first of several was nearly always
    /// the one that mattered, and the rest were filler a count had asked for. A
    /// conversation briefed when the answer was four still sends a list; it is cut to
    /// its first here rather than refused.
    public static let limit = 1
    static let labelLimit = 60
    static let promptLimit = 2_000

    /// What an agent sent, made fit to show.
    ///
    /// Trimmed, cut to length, empties dropped. Nothing here refuses a list over one
    /// bad entry: a suggestion is a nicety, and losing it because the first label came
    /// through blank would be worse than showing the next one.
    public init?(wire: JSONValue) {
        let prompt = (wire["prompt"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let label = (wire["label"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(label: String((label.isEmpty ? prompt : label).prefix(Self.labelLimit)),
                  prompt: String(prompt.prefix(Self.promptLimit)))
    }

    public static func list(in value: JSONValue?) -> [SuggestedPrompt] {
        Array((value?.arrayValue ?? []).compactMap(SuggestedPrompt.init(wire:)).prefix(limit))
    }

    /// What `finish_turn` carries: the one, or failing that the first of the list a
    /// conversation briefed before 031 still sends. The one wins where both came.
    public static func next(one: JSONValue?, orFirstOf many: JSONValue?) -> [SuggestedPrompt] {
        if let one, let prompt = SuggestedPrompt(wire: one) { return [prompt] }
        return list(in: many)
    }
}
