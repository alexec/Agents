/// What a stretch of code is, as far as its colour goes (041 research R4).
///
/// Nine, not the thirty-odd names the grammars' queries use. The person needs to tell a
/// string from a keyword from a comment at a glance; a palette that also tells a method from
/// a function from a constructor is noise at the size code is read in this app.
public enum CodeRole: Hashable, Sendable, CaseIterable {
    case keyword, string, comment, number, type, function, property, punctuation, plain

    /// The role for a capture name from a `highlights.scm`: `keyword.return`,
    /// `string.special.url`, `function.method.builtin`. Total: a name it does not know is
    /// plain, so a grammar update that invents a capture never breaks a file.
    public static func role(forCapture name: String) -> CodeRole {
        if let exact = exceptions[name] { return exact }
        let head = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return byHead[head] ?? .plain
    }

    /// Whole names that do not follow their first part.
    private static let exceptions: [String: CodeRole] = [
        "variable.builtin": .keyword,     // self, this, super
        "variable.parameter.builtin": .keyword,
        "string.special.symbol": .number, // Ruby :symbols read as values
        "punctuation.special": .keyword,  // ${ } in templates
        "text.literal": .string,          // Markdown code spans
        "text.uri": .string,
        "text.reference": .function,
        "text.title": .keyword,           // Markdown headings
        "text.emphasis": .plain,
        "text.strong": .plain,
    ]

    private static let byHead: [String: CodeRole] = [
        "keyword": .keyword, "conditional": .keyword, "repeat": .keyword,
        "include": .keyword, "exception": .keyword, "storageclass": .keyword,
        "tag": .keyword,                  // HTML element names
        "string": .string, "character": .string, "escape": .string,
        "comment": .comment,
        "number": .number, "float": .number, "boolean": .number, "constant": .number,
        "type": .type, "constructor": .type, "module": .type, "namespace": .type,
        "function": .function, "method": .function,
        "property": .property, "attribute": .property, "field": .property, "label": .plain,
        "operator": .punctuation, "punctuation": .punctuation, "delimiter": .punctuation,
    ]
}
