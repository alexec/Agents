import AgentsKitCore
import Foundation

/// The person's MCP servers, from `~/.agents/mcp.json` (054, FR-018).
///
///     { "mcpServers": {
///         "github": { "command": "npx", "args": ["-y", "…"], "env": { "GITHUB_TOKEN": "…" } },
///         "docs":   { "url": "https://…", "headers": { "Authorization": "…" } },
///         "old":    { "type": "sse", "url": "https://…" } } }
///
/// Read fresh for every session and never stored: an edit reaches the next agent, and a
/// secret in `env` or `headers` goes nowhere but the runtime (research R10, FR-023). So no
/// message made here ever quotes a value from the file; only server names, which are shown
/// everywhere anyway.
extension PersonalDotAgents {
    public static let mcpFile = "mcp.json"

    /// Why the file was skipped. Every personal server is then left out of every session
    /// until it is fixed, and the Shared tab says so.
    public struct MCPFileProblem: Error, Codable, Equatable, Sendable {
        public var message: String
        public var line: Int?

        public init(message: String, line: Int? = nil) {
            self.message = message
            self.line = line
        }
    }

    /// When the file last changed, as far as a draft needs to know: a draft made before an
    /// edit was made with the old servers (R10).
    public struct MCPStamp: Equatable, Sendable {
        var modified: Date?
        var size: Int?
    }

    public static func mcpURL(home: URL) -> URL {
        home.appending(path: folder).appending(path: mcpFile)
    }

    /// Nil when there is no file, which is the same as a file with no servers.
    public static func mcpStamp(home: URL?) -> MCPStamp? {
        guard let home,
              let attributes = try? FileManager.default.attributesOfItem(atPath: mcpURL(home: home).path)
        else { return nil }
        return MCPStamp(modified: attributes[.modificationDate] as? Date,
                        size: (attributes[.size] as? NSNumber)?.intValue)
    }

    /// The servers in `~/.agents/mcp.json`, in the file's order. A missing file is no
    /// servers and no problem.
    public static func personalServers(home: URL) -> Result<[MCPServer], MCPFileProblem> {
        servers(at: mcpURL(home: home))
    }

    /// The servers in a project's `<folder>/.agents/mcp.json`. A missing file is no servers.
    public static func projectServers(in folder: URL) -> Result<[MCPServer], MCPFileProblem> {
        servers(at: MCPJSONFile.projectURL(folder: folder))
    }

    /// The servers in one `mcp.json`. A missing file is no servers and no problem.
    static func servers(at url: URL) -> Result<[MCPServer], MCPFileProblem> {
        guard let data = try? Data(contentsOf: url) else { return .success([]) }
        return parseServers(data)
    }

    /// The names of the entries in one `mcp.json` that ask the daemon to host them (#488):
    /// a local server with `"hosted": true`. Nothing for a file that is missing or that
    /// `parseServers` would refuse.
    static func hostedNames(at url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url), case .success = parseServers(data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["mcpServers"] as? [String: Any] else { return [] }
        return Set(entries.compactMap { name, value in
            guard let entry = value as? [String: Any], entry["command"] != nil,
                  let hosted = entry["hosted"] as? Bool, hosted else { return nil }
            return name
        })
    }

    static func parseServers(_ data: Data) -> Result<[MCPServer], MCPFileProblem> {
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return .success([]) }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Foundation's own message quotes the text around the fault, which may be a
            // secret, so only where it is goes out.
            let index = (error as NSError).userInfo["NSJSONSerializationErrorIndex"] as? Int
            return .failure(MCPFileProblem(message: "mcp.json is not valid JSON.",
                                           line: index.map { line(at: $0, in: data) }))
        }
        guard let object = root as? [String: Any] else {
            return .failure(MCPFileProblem(message: "mcp.json should hold one object, with the servers under \"mcpServers\"."))
        }
        guard let listed = object["mcpServers"] else { return .success([]) }
        guard let entries = listed as? [String: Any] else {
            return .failure(MCPFileProblem(message: "\"mcpServers\" in mcp.json should be an object, one entry per server."))
        }
        // JSONSerialization forgets the order of keys; the file's order is the order a
        // clash between two of the person's own servers is settled in.
        let names = orderedKeys(of: "mcpServers", in: data) ?? entries.keys.sorted()
        var servers: [MCPServer] = []
        for name in names {
            guard let value = entries[name] else { continue }
            switch server(named: name, value) {
            case .success(let server): servers.append(server)
            case .failure(let problem):
                return .failure(MCPFileProblem(message: problem.message,
                                               line: line(ofKey: name, in: data)))
            }
        }
        return .success(servers)
    }

    static func server(named name: String, _ value: Any) -> Result<MCPServer, MCPFileProblem> {
        guard let entry = value as? [String: Any] else {
            return .failure(MCPFileProblem(message: "The server “\(name)” should be an object."))
        }
        func strings(_ key: String) -> [String]?? {
            guard let raw = entry[key] else { return .some(nil) }
            guard let list = raw as? [Any], let strings = list as? [String] else { return nil }
            return .some(strings)
        }
        func table(_ key: String) -> [String: String]?? {
            guard let raw = entry[key] else { return .some(nil) }
            guard let table = raw as? [String: String] else { return nil }
            return .some(table)
        }
        // `"hosted": true` asks the daemon to run one copy for every agent here (#488).
        if let hosted = entry["hosted"] {
            guard let hosted = hosted as? Bool else {
                return .failure(MCPFileProblem(message: "The server “\(name)” has a hosted that is not true or false."))
            }
            if hosted, entry["command"] == nil {
                return .failure(MCPFileProblem(message: "The server “\(name)” is hosted but has no command: "
                                               + "only a local server can be hosted."))
            }
        }
        if let command = entry["command"] {
            guard let command = command as? String, !command.isEmpty else {
                return .failure(MCPFileProblem(message: "The server “\(name)” has a command that is not a string."))
            }
            guard let args = strings("args") else {
                return .failure(MCPFileProblem(message: "The server “\(name)” has args that are not a list of strings."))
            }
            guard let env = table("env") else {
                return .failure(MCPFileProblem(message: "The server “\(name)” has an env whose values are not all strings."))
            }
            return .success(MCPServer(name: name, transport: .stdio(command: command, args: args ?? [], env: env ?? [:])))
        }
        guard let url = entry["url"] else {
            return .failure(MCPFileProblem(message: "The server “\(name)” has neither a command nor a url."))
        }
        guard let url = url as? String, !url.isEmpty else {
            return .failure(MCPFileProblem(message: "The server “\(name)” has a url that is not a string."))
        }
        guard let headers = table("headers") else {
            return .failure(MCPFileProblem(message: "The server “\(name)” has headers whose values are not all strings."))
        }
        switch entry["type"] as? String ?? "http" {
        case "http", "streamable-http", "streamableHttp":
            return .success(MCPServer(name: name, transport: .http(url: url, headers: headers ?? [:])))
        case "sse":
            return .success(MCPServer(name: name, transport: .sse(url: url, headers: headers ?? [:])))
        default:
            return .failure(MCPFileProblem(message: "The server “\(name)” has a type that is not http or sse."))
        }
    }

    /// The 1-based line of a byte offset.
    private static func line(at index: Int, in data: Data) -> Int {
        data.prefix(max(0, index)).reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    /// The line a server's name is first written on, for a problem with that server.
    private static func line(ofKey key: String, in data: Data) -> Int? {
        guard let quoted = try? JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed),
              let range = data.range(of: quoted) else { return nil }
        return line(at: range.lowerBound, in: data)
    }

    /// The keys of one top-level object in the order they are written, by a small scan
    /// of the text: enough for a file JSONSerialization has already accepted.
    static func orderedKeys(of member: String, in data: Data) -> [String]? {
        let bytes = [UInt8](data)
        var index = 0
        var depth = 0
        var keys: [String] = []
        var inMember = false
        var memberDepth = 0
        var expectingKey = false

        func readString() -> String? {
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") {
                    index += 1
                    let slice = Data(bytes[start..<index])
                    return (try? JSONSerialization.jsonObject(with: slice, options: .fragmentsAllowed)) as? String
                }
                index += 1
            }
            return nil
        }

        var lastString: String?
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                let string = readString()
                if inMember && depth == memberDepth && expectingKey, let string { keys.append(string) }
                lastString = string
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if byte == UInt8(ascii: "{"), depth == 2, lastString == member, !inMember {
                    inMember = true
                    memberDepth = depth
                }
                expectingKey = byte == UInt8(ascii: "{")
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if inMember && depth == memberDepth { return keys }
                depth -= 1
            case UInt8(ascii: ","):
                // Inside an object a comma is followed by a key; inside an array it is not,
                // but arrays are never at the member's depth, where keys are collected.
                expectingKey = true
            case UInt8(ascii: ":"):
                expectingKey = false
            default:
                break
            }
            index += 1
        }
        return inMember ? keys : nil
    }
}
