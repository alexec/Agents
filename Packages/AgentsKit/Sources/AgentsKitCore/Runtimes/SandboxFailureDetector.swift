import Foundation

/// Whether a runtime's words mean its command sandbox could not be set up (064, R11).
///
/// The patterns are `SandboxCatalog`'s, taken from real failures; each names the sandbox's
/// own setup, so a command denied inside a working sandbox ("Operation not permitted" about
/// its own target) never matches (FR-006, SC-004).
public enum SandboxFailureDetector {
    /// The lines that matched, colour codes taken out, for the card's details; nil when
    /// nothing matched.
    public static func match(runtimeID: String, text: String) -> String? {
        guard let patterns = SandboxCatalog.entry(for: runtimeID)?.failurePatterns, !patterns.isEmpty,
              !text.isEmpty else { return nil }
        let plain = stripped(text)
        let lines = plain.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let hits = lines.filter { line in patterns.contains { line.localizedCaseInsensitiveContains($0) } }
        guard !hits.isEmpty else { return nil }
        let detail = hits.joined(separator: "\n")
        return detail.count > 1200 ? String(detail.prefix(1200)) + "…" : detail
    }

    /// Text without ANSI colour codes, as Gemini prints its error in red.
    static func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
