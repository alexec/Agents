import Foundation

/// Up and Down in the prompt bar (#1551): the prompts the person sent in this session, as
/// a terminal's history gives back the commands typed before. The page has its own copy
/// (`recall` in `Web/src/model/promptHistory.ts`), held to `Fixtures/web/prompt/history.json`.
public enum PromptHistory {
    public enum Direction: String, Sendable { case up, down }

    /// What the prompt bar shows after Up or Down, and how far back that is (0 is the newest
    /// prompt sent; nil is the prompt bar's own text again). Nil when the key is not history's:
    /// Up takes an empty prompt, or one recalled and left as it was; Down takes a recalled one
    /// left as it was. A prompt changed by hand is the person's, and the keys move the caret.
    public static func recall(_ direction: Direction, text: String, sent: [String],
                              at: Int?) -> (text: String, at: Int?)? {
        // The one recalled, if the prompt bar still shows it as it was given back.
        let unchanged = at.flatMap { at in at < sent.count && sent[sent.count - 1 - at] == text ? at : nil }
        switch direction {
        case .up:
            let next = unchanged.map { $0 + 1 } ?? (text.isEmpty ? 0 : nil)
            guard let next, next < sent.count else { return nil }
            return (sent[sent.count - 1 - next], next)
        case .down:
            guard let unchanged else { return nil }
            return unchanged == 0 ? ("", nil) : (sent[sent.count - unchanged], unchanged - 1)
        }
    }

    /// The prompts the person sent in these turns and entries, oldest first: not another
    /// agent's messages (#560), nor the app's own question. One sent twice in a row is one.
    public static func sent(turns: [TurnSummary], entries: [TranscriptEntry]) -> [String] {
        var sent: [String] = []
        for entry in turns.compactMap(\.ask) + entries {
            guard case .userMessage(let text, _, .person) = entry.kind,
                  !text.isEmpty, sent.last != text else { continue }
            sent.append(text)
        }
        return sent
    }
}
