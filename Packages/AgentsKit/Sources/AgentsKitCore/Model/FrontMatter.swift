import Foundation

/// The metadata block some markdown files open with, and why it has to go.
///
/// CommonMark has never heard of YAML front matter. Handed a file that opens with
/// `---`, the parser reads the opening marker as a thematic break, the keys as a setext
/// heading — and then swallows the document's real first heading into that same
/// heading. Content is lost, not merely mis-styled. 224 files in this repository open
/// this way.
///
/// The rule is positional, and that is the whole care of it: `---` on the first line is
/// a fence around metadata, and `---` anywhere else is a horizontal rule that the
/// reader is entitled to see. Getting that backwards eats the top of a document.
public enum FrontMatter {
    /// The document without its opening metadata block.
    ///
    /// Returns the source unchanged unless the very first line is `---` and a closing
    /// `---` follows it. A file that opens with a rule and never closes one is a file
    /// with a rule in it.
    public static func strip(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return source }
        lines = lines.dropFirst()

        guard let closing = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return source }

        lines = lines[lines.index(after: closing)...]
        // The blank line the block is usually followed by belongs to the block, not to
        // the document under it.
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines = lines.dropFirst()
        }
        return lines.joined(separator: "\n")
    }
}
