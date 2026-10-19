import Foundation

/// Quote in Prompt (#1553): words from a reply, added to the prompt bar as a Markdown quote
/// with an empty line after it, where the caret goes. The page has its own copy (`quoteInto`
/// in `Web/src/model/promptQuote.ts`), held to `Fixtures/web/prompt/quote.json`.
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
}
