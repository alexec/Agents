import Foundation

/// One line of the chat's wait card (#2599, #2747): where its events come from, what they
/// mean in words, and what they are narrowed by. "Agents · “Fix login” to finish",
/// "GitHub · Checks failed or PR merged (pr 123)". Events from one source narrowed the
/// same way share a line. A session is named by its title, as `WaitStatus.described`
/// names it, and an event by its meaning in the catalogue; `events` keeps the names, for
/// the line's help. The web page's is `eventWaitSummaryLines` in `rowLines.ts`.
public struct WaitEventLine: Identifiable, Hashable, Sendable {
    public let id: String
    public let source: String
    /// The events' names, as the wait has them: "agent.finished", "checks.failed".
    public var events: [String]
    /// What the events mean, joined with "or".
    public var words: String
    public let arguments: [String]
    /// The PR or issue its arguments name, as a link (#3077). `nil` when they don't.
    public let url: URL?

    public static func lines(for wait: EventWait, names: (UUID) -> String?) -> [WaitEventLine] {
        var groups: [Group] = []
        for pattern in wait.patterns {
            let server = wait.serverEvents?.first { $0.trigger.event == pattern.name }
            let servers = server.map { $0.servers.isEmpty ? ($0.trigger.servers ?? []) : $0.servers } ?? []
            let source = if server == nil {
                sourceName(pattern.name)
            } else if servers.isEmpty {
                "Connected tools"
            } else {
                servers.map(serverName).joined(separator: " or ")
            }
            // An agent finishing, narrowed to one agent, is that agent by its title.
            let finisher = pattern.name == "agent.finished" && pattern.filters.count == 1
                ? pattern.filters["agent"]?.single.map { id in UUID(uuidString: id).flatMap(names) ?? id } : nil
            let arguments: [String] = if let server {
                server.trigger.arguments.sorted { $0.key < $1.key }.map { "\($0.key) \(valueWords($0.value))" }
            } else if finisher != nil {
                []
            } else {
                pattern.filters.sorted { $0.key < $1.key }.map { key, filter in
                    let values = key == "agent"
                        ? filter.values.map { id in "\u{201C}\(UUID(uuidString: id).flatMap(names) ?? id)\u{201D}" }
                        : filter.values
                    return "\(key) \(values.joined(separator: "|"))"
                }
            }
            let id = source + "\u{0}" + arguments.joined(separator: "\u{0}")
            let index = groups.firstIndex { $0.id == id } ?? {
                groups.append(Group(id: id, source: source, arguments: arguments, url: server?.trigger.url))
                return groups.count - 1
            }()
            if !groups[index].events.contains(pattern.name) { groups[index].events.append(pattern.name) }
            if let finisher {
                if !groups[index].finishers.contains(finisher) { groups[index].finishers.append(finisher) }
                if !groups[index].phrases.contains(.finishers) { groups[index].phrases.append(.finishers) }
            } else {
                let words = server == nil ? pattern.meaning : serverWords(pattern.name)
                if !groups[index].phrases.contains(.words(words)) { groups[index].phrases.append(.words(words)) }
            }
        }
        return groups.map { group in
            let phrases = group.phrases.enumerated().map { offset, phrase in
                switch phrase {
                case .finishers: return WaitStatus.finishing(group.finishers)
                case .words(let words): return offset == 0 ? words : lowered(words)
                }
            }
            return WaitEventLine(id: group.id, source: group.source, events: group.events,
                                 words: phrases.joined(separator: " or "), arguments: group.arguments, url: group.url)
        }
    }

    private struct Group {
        let id: String
        let source: String
        let arguments: [String]
        let url: URL?
        var events: [String] = []
        var finishers: [String] = []
        var phrases: [Phrase] = []
    }

    private enum Phrase: Equatable {
        case finishers
        case words(String)
    }

    /// A meaning after "or": "An agent…" reads "an agent…"; "PR merged" and "This Mac woke
    /// up" keep their capitals.
    private static func lowered(_ words: String) -> String {
        guard let first = words.first, first.isUppercase, !words.hasPrefix("This Mac") else { return words }
        let second = words.dropFirst().first
        if let second, second.isUppercase { return words }
        return first.lowercased() + words.dropFirst()
    }

    /// A server's event has no meaning in the catalogue: its name in words, "checks.failed"
    /// as "Checks failed", "pr.merged" as "PR merged".
    static func serverWords(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).map { word in
            ["pr", "mr", "ci"].contains(word.lowercased()) ? word.uppercased() : String(word)
        }
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    static func sourceName(_ event: String) -> String {
        switch event.split(separator: ".").first.map(String.init) {
        case "mac", "machine", "person", "system", "cost", "lease": "This Mac"
        case "workflow": "Workflows"
        case "branch": "Branches"
        case "dropbox": "Drop box"
        default: "Agents"
        }
    }

    static func serverName(_ name: String) -> String {
        switch name.lowercased() {
        case "github": "GitHub"
        case "gitlab": "GitLab"
        case "linear": "Linear"
        case "email": "Email"
        default: name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    static func valueWords(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .bool(let flag): String(flag)
        case .null: "null"
        case .array, .object: String(describing: value)
        }
    }
}
