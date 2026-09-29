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
        var hits: [String] = []
        for line in lines {
            guard let pattern = patterns.first(where: { line.localizedCaseInsensitiveContains($0) }) else { continue }
            let hit = trimmed(line, to: pattern)
            if !hits.contains(hit) { hits.append(hit) }
        }
        guard !hits.isEmpty else { return nil }
        let detail = hits.joined(separator: "\n")
        return detail.count > 1200 ? String(detail.prefix(1200)) + "…" : detail
    }

    /// A line from an agent's reply can run its own words into the error, since chunks are
    /// joined without a break (Codex: "…the shell output.sandbox-exec: sandbox_apply…").
    /// What comes before the last full stop ahead of the match is dropped.
    static func trimmed(_ line: String, to pattern: String) -> String {
        guard let match = line.range(of: pattern, options: .caseInsensitive),
              let stop = line[..<match.lowerBound].lastIndex(of: ".") else { return line }
        return String(line[line.index(after: stop)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Text without ANSI colour codes, as Gemini prints its error in red.
    static func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
