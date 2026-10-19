import Foundation

/// Run a shell command from a reply (#1533): which code blocks are commands, what is typed
/// into the session's shell for one, and what the shell printed after it, for Tell the Agent.
public enum ShellCommand {
    /// The fence tags of a shell's commands. `console` and `shell-session` are a shell's
    /// screen: the lines at a prompt are the commands, the rest is what they printed.
    private static let tags: Set<String> = ["sh", "bash", "zsh", "shell", "console", "shell-session"]
    private static let screens: Set<String> = ["console", "shell-session"]
    private static let prompts = ["$ ", "% ", "# "]

    /// The command a code block runs, or nil when the block is not a shell's or holds none.
    public static func runnable(tag: String?, text: String) -> String? {
        guard let tag = tag?.lowercased().split(separator: " ").first.map(String.init),
              tags.contains(tag) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if screens.contains(tag) {
            lines = lines.compactMap { line in
                prompts.first { line.hasPrefix($0) }.map { String(line.dropFirst($0.count)) }
            }
        }
        let command = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// What is typed into the shell for `command`: each line ends with Return.
    public static func typed(_ command: String) -> Data {
        Data((command.replacingOccurrences(of: "\n", with: "\r") + "\r").utf8)
    }

    /// The last `lines` lines a shell printed, as text: escape sequences out, a line
    /// written over after a carriage return as it ends up, trailing blank lines out.
    public static func tail(_ data: Data, lines: Int = 40) -> String {
        let text = String(decoding: data, as: UTF8.self)
        var out: [String] = []
        var line = ""
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.popFirst() {
            switch c {
            case "\u{1B}":
                // CSI: ESC [ … a final byte. OSC: ESC ] … BEL or ESC \. Others: one more.
                guard let kind = chars.popFirst() else { break }
                if kind == "[" {
                    while let next = chars.popFirst(), !(0x40...0x7E).contains(next.value) {}
                } else if kind == "]" {
                    while let next = chars.popFirst() {
                        if next == "\u{07}" { break }
                        if next == "\u{1B}" { _ = chars.popFirst(); break }
                    }
                }
            case "\n":
                out.append(line)
                line = ""
            case "\r":
                // A CR before a LF ends the line; alone, what follows writes over it.
                if chars.first != "\n" { line = "" }
            case "\t":
                line.unicodeScalars.append(c)
            default:
                if c.value >= 0x20, c.value != 0x7F { line.unicodeScalars.append(c) }
            }
        }
        out.append(line)
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        var kept = Array(out.suffix(lines))
        while kept.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeFirst() }
        return kept.joined(separator: "\n")
    }

    /// What Tell the Agent sends: the command, and the end of what it printed.
    public static func report(command: String, printed: String) -> String {
        let output = printed.isEmpty ? "(It printed nothing.)" : "```\n\(printed)\n```"
        return "I ran this command in this session's shell:\n\n```sh\n\(command)\n```\n\n"
            + "The end of what it printed:\n\n\(output)\n\nIt did not work. Find the cause and fix it."
    }
}
