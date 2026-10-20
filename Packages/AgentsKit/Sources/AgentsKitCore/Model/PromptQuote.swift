import Foundation

/// Quote in Prompt (#1553): words from a reply, added to the prompt bar as a Markdown quote
/// with an empty line after it, where the caret goes. The page has its own copy (`quoteInto`
/// and `giveBackInto` in `Web/src/model/promptQuote.ts`), held to `Fixtures/web/prompt/quote.json`
/// and `Fixtures/web/prompt/give-back.json`.
public enum PromptQuote {
    /// `text` with `quote` added at its end as a quote. Nothing to quote leaves it as it was.
    public static func adding(_ quote: String, to text: String) -> String {
        let words = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return text }
        let quoted = words.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \(line)" }
            .joined(separator: "\n")
        // An empty line before it, so it is not read as part of the line before.
        let before = text.isEmpty || text.hasSuffix("\n\n") ? text
            : text.hasSuffix("\n") ? text + "\n" : text + "\n\n"
        return before + quoted + "\n\n"
    }

    /// Words given back to the prompt bar, such as a queued prompt's edit that came too late
    /// (#1665): in place of an empty bar, else after what is typed with an empty line
    /// between, so a draft is never written over.
    public static func givingBack(_ words: String, to text: String) -> String {
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return words }
        let before = text.hasSuffix("\n\n") ? text : text.hasSuffix("\n") ? text + "\n" : text + "\n\n"
        return before + words
    }
}

/// Words handed to one prompt bar from elsewhere (#1679): a quote, or an edit given back. Keyed
/// by the agent whose bar takes them, so with a session in a window of its own, or two iPad
/// scenes, they go to their own chat and not to the bar in front. Nil is the new-session bar.
public struct PromptOffer: Equatable, Sendable {
    public var agentID: UUID?
    public var words: String

    public init(agentID: UUID?, words: String) {
        self.agentID = agentID
        self.words = words
    }
}
