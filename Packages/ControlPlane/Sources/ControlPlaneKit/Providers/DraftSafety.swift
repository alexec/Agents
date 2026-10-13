import AgentsKitCore
import Foundation

/// What a draft's check may run without asking the person (#858, FR-013, FR-014, research
/// R5). A check calls a tool or a command the agent chose, and the agent's words come in part
/// from a server's descriptions and a CLI's help, which nobody here wrote. So a check runs on
/// its own only when it is plainly a list; anything else is asked, with the reason.
public enum DraftSafety {
    public enum Verdict: Equatable, Sendable {
        case run
        case ask(String)
    }

    /// A list's name must have one of these words.
    static let allowed: Set<String> = ["list", "ls", "get", "describe", "status", "show"]
    /// And none of these.
    static let blocked: Set<String> = [
        "create", "delete", "destroy", "remove", "rm", "rmi", "power", "start", "stop", "restart", "reboot",
        "resize", "update", "set", "terminate", "kill", "shutdown", "halt", "reset", "rebuild", "restore",
        "purge", "prune", "drop", "wipe", "suspend", "down",
    ]

    /// The words of a tool's name or a command: split on anything not a letter or digit, and
    /// at a lower-case letter followed by a capital (`dropletList`), lower-cased.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var last: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                if let last, last.isLowercase, character.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
            last = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// Why `words` isn't plainly a list; nil when it is.
    static func notAList(_ words: [String]) -> String? {
        if let bad = words.first(where: blocked.contains) { return "it has the word “\(bad)”" }
        guard words.contains(where: allowed.contains) else {
            return "its name has none of the words list, ls, get, describe, status or show"
        }
        return nil
    }

    /// Whether a tool map's list may be called alone. `tools` is the server's `tools/list`,
    /// for the list tool's annotations.
    public static func listTool(_ draft: JSONValue, tools: [JSONValue]) -> Verdict {
        guard let name = draft["list"]?["tool"]?.stringValue else { return .run }
        for key in ["start", "stop", "create", "delete", "options"] where draft[key]?["tool"]?.stringValue == name {
            return .ask("\(name) is the map’s \(key) as well")
        }
        let annotations = tools.first { $0["name"]?.stringValue == name }?["annotations"]
        if annotations?["destructiveHint"]?.boolValue == true { return .ask("the server says \(name) is destructive") }
        if annotations?["readOnlyHint"]?.boolValue == false { return .ask("the server says \(name) changes something") }
        if let reason = notAList(words(name)) { return .ask(reason) }
        if let arguments = draft["list"]?["arguments"], let reason = carriesOut(text(arguments)) {
            return .ask("its arguments hold \(reason)")
        }
        return .run
    }

    /// Whether a command-provider config's check may run alone: what it runs is its `list`,
    /// or each workspace's `status`. A preset runs only its own fixed commands.
    public static func commands(_ config: JSONValue, cli: String) -> Verdict {
        if config["preset"]?.stringValue != nil { return .run }
        var lines: [String] = []
        if let list = config["list"]?.stringValue {
            lines = [list]
        } else {
            lines = (config["workspaces"]?.arrayValue ?? []).compactMap { $0["status"]?.stringValue }
        }
        for line in lines {
            if case .ask(let reason) = command(line, cli: cli) { return .ask(reason) }
        }
        return .run
    }

    /// One command a check would run.
    public static func command(_ line: String, cli: String) -> Verdict {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let first = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard !cli.isEmpty, first == cli else { return .ask("`\(trimmed)` doesn’t start with \(cli)") }
        if let bad = [";", "&", "|", ">", "<", "`", "$", "\n", "\r"].first(where: trimmed.contains) {
            return .ask("`\(trimmed)` has \(bad == "\n" || bad == "\r" ? "a new line" : "“\(bad)”")")
        }
        if let reason = carriesOut(trimmed) { return .ask("`\(trimmed)` holds \(reason)") }
        if let reason = notAList(words(String(trimmed.dropFirst(first.count)))) { return .ask("`\(trimmed)`: \(reason)") }
        return .run
    }

    /// Why `read_help`'s words are refused (FR-014); nil when they may run. `seen` is every
    /// help the CLI has printed for this draft.
    public static func helpWords(_ given: [String], seen: String) -> String? {
        guard given.count <= 3 else { return "At most three words." }
        let printed = Set(words(seen))
        for word in given {
            if word.hasPrefix("-") { return "“\(word)” is a flag: give subcommands only." }
            guard word.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
                return "“\(word)” isn’t a plain word."
            }
            if blocked.subtracting(["start", "stop"]).contains(word.lowercased()) {
                return "“\(word)” may change something, so its help isn’t run."
            }
            guard printed.contains(word.lowercased()) || seen.contains(word) else {
                return "“\(word)” isn’t a word the CLI’s help printed."
            }
        }
        return nil
    }

    /// `$`, `${…}` or an address, which could carry a secret out of the machine.
    static func carriesOut(_ text: String) -> String? {
        if text.contains("://") { return "an address" }
        if text.contains("$") { return "“$”" }
        return nil
    }

    static func text(_ json: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(json) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
