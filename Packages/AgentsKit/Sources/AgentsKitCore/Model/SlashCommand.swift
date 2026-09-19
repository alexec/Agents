import Foundation

/// A command a runtime says it takes, as it said it.
///
/// Every runtime has its own: Copilot advertises thirty-odd, the Claude adapter
/// advertises whatever skills are installed. They arrive over the protocol and change
/// while a session is running, so nothing about them is written down here.
public struct SlashCommand: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String?
    /// What the command expects after it, in the runtime's words: "directory", "topic".
    public var inputHint: String?

    public var id: String { name }

    public init(name: String, description: String? = nil, inputHint: String? = nil) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }

    private enum CodingKeys: String, CodingKey { case name, description, inputHint }

    /// Decoded from what the runtime sends, which nests the hint.
    public init?(wire: JSONValue) {
        guard let name = wire["name"]?.stringValue else { return nil }
        self.name = name
        self.description = wire["description"]?.stringValue
        self.inputHint = wire["input"]?["hint"]?.stringValue
    }
}

/// What the person is part way through typing.
public struct SlashQuery: Equatable, Sendable {
    /// Where the word sits in the text, so accepting a command replaces it.
    public var start: String.Index
    /// What has been typed after the slash.
    public var term: String

    public init(start: String.Index, term: String) {
        self.start = start
        self.term = term
    }
}

extension SlashCommand {
    /// The word being typed, when it is a command and not something else.
    ///
    /// A slash only starts a command at the beginning of a word, so a path typed into
    /// the prompt does not turn the whole thing into a command picker halfway through.
    public static func query(in text: String) -> SlashQuery? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        if slash != text.startIndex {
            // Asking for the index before the first one is a crash, not a false.
            let before = text.index(before: slash)
            guard text[before].isWhitespace else { return nil }
        }
        let term = String(text[text.index(after: slash)...])
        guard !term.contains(where: \.isWhitespace) else { return nil }
        return SlashQuery(start: slash, term: term)
    }

    /// The commands worth offering for what has been typed.
    ///
    /// What starts with the term comes before what merely contains it, because the
    /// first keystroke should put the obvious one at the top.
    public static func matching(_ term: String, in commands: [SlashCommand]) -> [SlashCommand] {
        guard !term.isEmpty else { return commands }
        let needle = term.lowercased()
        let starts = commands.filter { $0.name.lowercased().hasPrefix(needle) }
        let contains = commands.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }
        return starts + contains
    }

    /// The text with the half-typed command replaced by this one.
    public func completing(_ query: SlashQuery, in text: String) -> String {
        String(text[text.startIndex..<query.start]) + "/" + name + " "
    }
}
