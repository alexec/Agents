import Foundation

/// What a runtime the chat carries on with is handed: the conversation so far, from the
/// app's own record (052, R4). Markdown, so it reads the same to a model and to the
/// person who unfolds it under the switch note.
public enum Handoff {
    /// The default budget when the new runtime's context size is not known.
    public static let defaultBudget = 400_000

    public struct Document: Hashable, Sendable {
        public var markdown: String
        /// Turns left out to fit the budget; nil when nothing was.
        public var leftOut: Int?
    }

    /// - Parameters:
    ///   - fromRuntime: the runtime that ran out, named in the header.
    ///   - budget: characters. The first request and the latest turns are kept; the middle
    ///     goes first, and the document says how many turns.
    public static func document(entries: [TranscriptEntry], fromRuntime: String, why: String,
                                budget: Int = defaultBudget) -> Document {
        let header = """
            # Conversation so far

            This conversation is carried over from \(fromRuntime), because \(why). You are \
            continuing it. The files are already as described below: nothing was undone.


            """
        var turns: [String] = []
        var current: [String] = []
        var plan: Plan?
        for entry in entries {
            switch entry.kind {
            case .userMessage(let text, _, let from):
                if !current.isEmpty { turns.append(current.joined(separator: "\n")) }
                current = ["**\(from == .app ? "The app" : "You"):** \(text)"]
            case .agentMessage(_, let text, _) where !text.isEmpty:
                current.append("**\(fromRuntime):** \(text)")
            case .toolCall(let call) where !call.isTheApps:
                current.append("- \(call.line)" + (call.locations.first.map { " (`\($0.path)`)" } ?? ""))
            case .planUpdated(let updated):
                plan = updated
            default:
                continue
            }
        }
        if !current.isEmpty { turns.append(current.joined(separator: "\n")) }

        var planText = ""
        if let plan, !plan.entries.isEmpty {
            planText = "\n## The plan, as it stood\n\n"
                + plan.entries.map { "- [\($0.status == .completed ? "x" : " ")] \($0.content)" }.joined(separator: "\n")
                + "\n"
        }
        let whole = header + turns.joined(separator: "\n\n") + "\n" + planText
        guard whole.count > budget, turns.count > 2 else { return Document(markdown: whole, leftOut: nil) }

        // Keep the first request and as many of the latest turns as fit.
        let first = turns[0]
        var kept: [String] = []
        var size = header.count + first.count + planText.count + 80
        for turn in turns.dropFirst().reversed() {
            guard size + turn.count + 2 <= budget else { break }
            kept.insert(turn, at: 0)
            size += turn.count + 2
        }
        let leftOut = turns.count - 1 - kept.count
        let shortened = header + first + "\n\n[\(leftOut) earlier turns left out]\n\n"
            + kept.joined(separator: "\n\n") + "\n" + planText
        return Document(markdown: shortened, leftOut: leftOut)
    }
}
