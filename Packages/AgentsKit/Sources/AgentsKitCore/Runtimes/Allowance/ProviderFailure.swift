import Foundation

/// A failure of the provider behind one model, not of the runtime (#140).
///
/// OpenCode's free models each come from their own endpoint, and one being down said
/// nothing about the runtime: its default model worked a minute later. So these count
/// against the model the turn was on, and never take the runtime out of the pool. Every
/// entry quotes something a runtime was seen to say.
public enum ProviderFailure {
    /// OpenCode 1.x, captured on 2026-10-03 from `opencode/ling-3.0-flash-fin-free`:
    /// JSON-RPC `-32603` with `Upstream request failed: Endpoint is unavailable`.
    /// "Error from provider" is the same adapter's wording for a provider's own error.
    public static let words = ["upstream request failed", "error from provider", "endpoint is unavailable"]

    /// Whether a JSON-RPC error is a provider's failure: an internal error whose message,
    /// or the message under its data, says so in the words above.
    public static func recognises(_ error: JSONRPCError) -> Bool {
        guard error.code == JSONRPCError.internalError else { return false }
        return recognises(words: error.message) || recognises(words: error.data.map { "\($0)" } ?? "")
    }

    /// Whether words a runtime ended a turn with say a provider failed (049's in-words
    /// failures, which OpenCode also uses).
    public static func recognises(words: String) -> Bool {
        let lowered = words.lowercased()
        return Self.words.contains { lowered.contains($0) }
    }
}
