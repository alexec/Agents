import Foundation

/// A workflow trigger naming an MCP server's event (#383), such as `checks.failed`.
///
/// Named as the server names it, with no prefix: every event is `noun.verbed`, whoever
/// raises it. Without `server:` it hears every server this folder can use that offers
/// the name; with it, only those. Every other key under it is an argument of the
/// subscription, sent to the server as it is, rather than a detail matched here: only the
/// server knows how to filter its own events.
public struct MCPEventTrigger: Codable, Hashable, Sendable {
    /// The reserved key that narrows which servers it hears.
    public static let serverKey = "server"
    /// The most the arguments may take as JSON, as for pin arguments.
    public static let argumentLimit = 2048

    public var event: String
    /// `nil` means every server here that offers the event.
    public var servers: [String]?
    public var arguments: [String: JSONValue]

    public init(event: String, servers: [String]? = nil, arguments: [String: JSONValue] = [:]) {
        self.event = event
        self.servers = servers
        self.arguments = arguments
    }

    /// Whether `name` is a server's name a file may give: letters, digits, `_` and `-`.
    public static func isServerName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    /// Whether it listens to `server` at all.
    public func hears(server: String) -> Bool {
        servers.map { $0.contains(server) } ?? true
    }

    /// The subscription it makes on `server`: the first 16 hex characters of a digest of
    /// the server, the event and the arguments. Two triggers with the same three share it.
    public func subscriptionKey(server: String) -> String {
        let text = server + "\n" + event + "\n" + Self.canonicalJSON(.object(arguments))
        return String(ContentDigest.sha256(Data(text.utf8)).prefix(16))
    }

    /// Whether it names a server's whole noun, `pr.*`: a wait may (#577), where a
    /// workflow file names one event.
    public var isWholeNoun: Bool { event.hasSuffix(".*") }

    /// Whether `name` is its event, or one of its noun's.
    public func covers(_ name: String) -> Bool {
        guard isWholeNoun else { return name == event }
        return name.hasPrefix(String(event.dropLast())) && EventCatalogue.isServerEventName(name)
    }

    /// The same servers and arguments, on one event its noun covers.
    public func narrowed(to name: String) -> MCPEventTrigger {
        MCPEventTrigger(event: name, servers: servers, arguments: arguments)
    }

    /// Whether a raised event is one of its subscriptions': the same name, from a server
    /// it hears, and carrying that server's key. Matching on the key means an event can
    /// never run a workflow that did not ask for it.
    public func matches(_ event: Event) -> Bool {
        guard covers(event.name), let server = event.details["server"], hears(server: server) else { return false }
        return event.details["subscription"] == narrowed(to: event.name).subscriptionKey(server: server)
    }

    /// The arguments as the file and the wire say them, `server:` folded back in.
    public var keys: [String: JSONValue] {
        var keys = arguments
        if let servers {
            keys[Self.serverKey] = servers.count == 1 ? .string(servers[0]) : .array(servers.map(JSONValue.string))
        }
        return keys
    }

    /// Read back from a file's or the wire's keys. `nil` when `server:` is not a name or
    /// a list of names.
    public init?(event: String, keys: [String: JSONValue]) {
        var arguments = keys
        var servers: [String]?
        if let value = arguments.removeValue(forKey: Self.serverKey) {
            let names = value.stringValue.map { [$0] } ?? value.arrayValue?.compactMap(\.stringValue)
            guard let names, !names.isEmpty, names.count == (value.arrayValue?.count ?? 1),
                  names.allSatisfy(Self.isServerName) else { return nil }
            servers = names
        }
        self.init(event: event, servers: servers, arguments: arguments)
    }

    /// What this names, as a link (#3077): built from `repo` or `project` and `pr` or
    /// `issue`, assuming github.com or gitlab.com — the trigger carries no host, so a
    /// GitHub Enterprise or a self-managed GitLab's own base URL cannot be told from
    /// this alone. `nil` when the arguments do not name one.
    public var url: URL? {
        if let repo = arguments["repo"]?.stringValue {
            if let pr = arguments["pr"]?.intValue { return URL(string: "https://github.com/\(repo)/pull/\(pr)") }
            if let issue = arguments["issue"]?.intValue { return URL(string: "https://github.com/\(repo)/issues/\(issue)") }
        } else if let project = arguments["project"]?.stringValue, project.contains("/") {
            if let pr = arguments["pr"]?.intValue {
                return URL(string: "https://gitlab.com/\(project)/-/merge_requests/\(pr)")
            }
            if let issue = arguments["issue"]?.intValue { return URL(string: "https://gitlab.com/\(project)/-/issues/\(issue)") }
        }
        return nil
    }

    /// "When ci reports checks.failed (repo alexec/Agents)".
    public var summary: String {
        let who = servers.map { $0.joined(separator: " or ") } ?? "a server here"
        let narrowed = arguments.sorted { $0.key < $1.key }.map { "\($0.key) \(Self.words($0.value))" }
        return "When \(who) reports \(event)" + (narrowed.isEmpty ? "" : " (\(narrowed.joined(separator: ", ")))")
    }

    static func words(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return String(flag)
        case .null: return "null"
        case .array, .object: return canonicalJSON(value)
        }
    }

    /// JSON with its keys sorted and no spaces, so equal arguments are equal text.
    public static func canonicalJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
