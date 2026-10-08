import Foundation

/// The order a menu's choices are drawn in (#436).
///
/// Runtimes send their choices in whatever order their adapter keeps them, and Cursor's
/// models come out jumbled. The choices are put in order once, here, as they are read
/// from the runtime or from a record, so the Mac, the Remote and the web page all draw
/// the same order with no code of their own.
///
/// Only lists with no order of their own are sorted: models, and any long list with no
/// category. Modes, effort levels and permissions keep the runtime's order, which means
/// something (low before high). Each of the runtime's groups is sorted within itself.
public enum ChoiceOrder {
    /// Whether an option's choices are put in order rather than kept as sent.
    public static func sorts(category: String?, count: Int) -> Bool {
        switch category {
        case "model": return true
        case nil: return count >= longList
        default: return false
        }
    }

    /// An uncategorised list this long is a list to search, not a scale.
    static let longList = 10

    /// The groups with each one's choices in order. The groups themselves stay put.
    public static func sorted(_ groups: [ConfigChoiceGroup], category: String?) -> [ConfigChoiceGroup] {
        groups.map { group in
            guard sorts(category: category, count: group.choices.count) else { return group }
            return ConfigChoiceGroup(name: group.name, choices: sorted(group.choices))
        }
    }

    /// Auto or Default first; then by family (Claude, GPT, Gemini, Grok, then the rest by
    /// name); within a family the newest first, the most capable first at one version,
    /// then by name. Numbers compare as numbers, so 5.10 is newer than 5.9. Ties keep
    /// the order they came in, so a list never reorders between redraws.
    public static func sorted(_ choices: [ConfigChoice]) -> [ConfigChoice] {
        let keyed = choices.enumerated().map { (offset: $0.offset, choice: $0.element, key: Key($0.element)) }
        return keyed.sorted { left, right in
            switch left.key.compare(right.key) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return left.offset < right.offset
            }
        }.map(\.choice)
    }

    struct Key {
        let leads: Bool
        let familyRank: Int
        let family: String
        let version: [Int]
        let tier: Int
        let name: [Piece]

        init(_ choice: ConfigChoice) {
            let value = choice.value.stringValue ?? ""
            let words = ChoiceOrder.words(in: choice.name)
            let first = words.first ?? ""
            leads = ["auto", "default"].contains(first) || ["auto", "default"].contains(value.lowercased())
            let seen = Set(words + ChoiceOrder.words(in: value))
            if let known = ChoiceOrder.families.firstIndex(where: { !$0.marks.isDisjoint(with: seen)
                                                                    || seen.contains(where: $0.matches) }) {
                familyRank = known
                family = ""
            } else {
                familyRank = ChoiceOrder.families.count
                family = words.first(where: { $0.first?.isLetter == true }) ?? ""
            }
            version = ChoiceOrder.version(in: choice.name.isEmpty ? value : choice.name)
            tier = ChoiceOrder.tiers.firstIndex(where: seen.contains) ?? ChoiceOrder.tiers.count
            name = ChoiceOrder.pieces(of: choice.name.lowercased())
        }

        func compare(_ other: Key) -> ComparisonResult {
            if leads != other.leads { return leads ? .orderedAscending : .orderedDescending }
            if familyRank != other.familyRank { return familyRank < other.familyRank ? .orderedAscending : .orderedDescending }
            if family != other.family { return family < other.family ? .orderedAscending : .orderedDescending }
            // Newest first: the higher version leads.
            if version != other.version {
                return version.lexicographicallyPrecedes(other.version) ? .orderedDescending : .orderedAscending
            }
            if tier != other.tier { return tier < other.tier ? .orderedAscending : .orderedDescending }
            return ChoiceOrder.compare(name, other.name)
        }
    }

    struct Family {
        let marks: Set<String>
        var prefix: String? = nil

        func matches(_ word: String) -> Bool {
            guard let prefix, word.hasPrefix(prefix) else { return false }
            let rest = word.dropFirst(prefix.count)
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }
    }

    /// The families a model list is grouped by, in the order they are drawn. A model
    /// in none of them is grouped by the first word of its name, after these.
    static let families: [Family] = [
        Family(marks: ["claude", "opus", "sonnet", "haiku", "anthropic"]),
        // OpenAI's o-series (o3, o4) is told by its shape: o and a number.
        Family(marks: ["gpt", "codex", "openai", "chatgpt"], prefix: "o"),
        Family(marks: ["gemini", "google"]),
        Family(marks: ["grok", "xai"]),
    ]

    /// The most capable first, where a family names its sizes.
    static let tiers = ["opus", "pro", "max", "sonnet", "flash", "mini", "haiku", "nano", "lite"]

    /// Lowercased runs of letters or of digits: `gpt-5.1-codex` is gpt, 5, 1, codex.
    static func words(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var digits = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                let isDigit = ch.isNumber
                if !current.isEmpty, isDigit != digits, !(digits == false && current.count == 1 && current == "o") {
                    out.append(current)
                    current = ""
                }
                digits = isDigit
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The version a model name carries: its numbers, in order, leaving out anything as
    /// long as a date (`claude-3-5-sonnet-20241022` is 3.5).
    static func version(in text: String) -> [Int] {
        var numbers: [Int] = []
        var run = ""
        for ch in text + " " {
            if ch.isASCII, ch.isNumber {
                run.append(ch)
            } else {
                if !run.isEmpty, run.count < 4, let n = Int(run) { numbers.append(n) }
                run = ""
            }
        }
        return numbers
    }

    enum Piece: Equatable {
        case text(String)
        case number(Int)
    }

    /// A name cut into text and numbers, for a natural comparison.
    static func pieces(of text: String) -> [Piece] {
        var out: [Piece] = []
        var run = ""
        var digits = false
        func flush() {
            guard !run.isEmpty else { return }
            out.append(digits ? .number(Int(run) ?? .max) : .text(run))
            run = ""
        }
        for ch in text {
            let isDigit = ch.isASCII && ch.isNumber
            if !run.isEmpty, isDigit != digits { flush() }
            digits = isDigit
            run.append(ch)
        }
        flush()
        return out
    }

    static func compare(_ left: [Piece], _ right: [Piece]) -> ComparisonResult {
        for (a, b) in zip(left, right) {
            switch (a, b) {
            case let (.number(x), .number(y)) where x != y:
                return x < y ? .orderedAscending : .orderedDescending
            case let (.text(x), .text(y)) where x != y:
                return x < y ? .orderedAscending : .orderedDescending
            case (.number, .text): return .orderedAscending
            case (.text, .number): return .orderedDescending
            default: continue
            }
        }
        if left.count == right.count { return .orderedSame }
        return left.count < right.count ? .orderedAscending : .orderedDescending
    }
}
