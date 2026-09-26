import Foundation

/// What a `SKILL.md` says about itself: the `name` and `description` in its front matter
/// (059). Enough YAML for those two: a plain or quoted value on the line, or a block
/// (`>`, `|`, `>-`, `|-`) on the indented lines under it.
struct SkillFile: Equatable, Sendable {
    var name: String?
    var description: String?

    init(text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return }
        let front = Array(lines[1..<end])
        name = Self.value("name", in: front)
        description = Self.value("description", in: front)
    }

    private static func value(_ key: String, in lines: [String]) -> String? {
        guard let at = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) else { return nil }
        let raw = lines[at].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if [">", "|", ">-", "|-", ">+", "|+"].contains(raw) {
            let block = lines[(at + 1)...].prefix { $0.hasPrefix(" ") || $0.hasPrefix("\t") || $0.isEmpty }
            let parts = block.map { $0.trimmingCharacters(in: .whitespaces) }
            let joined = raw.hasPrefix(">") ? parts.joined(separator: " ") : parts.joined(separator: "\n")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var value = raw
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// The `skills` CLI's `sanitizeName`: the folder a skill of this name is put in.
    static func folderName(_ name: String) -> String {
        var s = name.lowercased().replacingOccurrences(of: "[^a-z0-9._]+", with: "-", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[.\\-]+|[.\\-]+$", with: "", options: .regularExpression)
        s = String(s.prefix(255))
        return s.isEmpty ? "unnamed-skill" : s
    }

    /// The CLI's `toSkillSlug`, which is how it matches a catalogue's `skillId` to a folder.
    static func slug(_ name: String) -> String {
        var s = name.lowercased()
        s = s.replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
        s = s.replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
