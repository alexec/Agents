import Foundation
import AgentsKitCore

/// Splice one server into `mcp.json` without disturbing hand-written siblings (060, R5,
/// contracts/mcp-json.md). Uses `OrderedJSON` so key order is kept.
enum MCPJSONFile {
    struct Problem: Error, Equatable {
        var message: String
    }

    static func personalURL(home: URL) -> URL { PersonalDotAgents.mcpURL(home: home) }

    static func projectURL(folder: URL) -> URL {
        folder.appending(path: PersonalDotAgents.folder).appending(path: PersonalDotAgents.mcpFile)
    }

    /// Insert or replace `name` under `mcpServers`. Creates the file when missing.
    /// Refuses when an existing file cannot be parsed.
    static func upsert(name: String, entry: OrderedJSON, at url: URL) throws {
        var root = try loadOrEmpty(at: url)
        var servers = root["mcpServers"] ?? .object([])
        servers.set(name, entry)
        root.set("mcpServers", servers)
        try write(root, to: url)
    }

    static func remove(name: String, at url: URL) throws {
        var root = try loadOrEmpty(at: url)
        guard var servers = root["mcpServers"] else { return }
        servers.remove(name)
        root.set("mcpServers", servers)
        try write(root, to: url)
    }

    /// The entry object for one name, if present.
    static func entry(named name: String, at url: URL) throws -> OrderedJSON? {
        let root = try loadOrEmpty(at: url)
        return root["mcpServers"]?[name]
    }

    static func loadOrEmpty(at url: URL) throws -> OrderedJSON {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .object([("mcpServers", .object([]))])
        }
        // One that is there and does not read (after a second try) is refused, never
        // taken as empty: the next write would drop every hand-written server (#205).
        guard let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: url)) else {
            throw Problem(message: "mcp.json could not be read.")
        }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            return .object([("mcpServers", .object([]))])
        }
        guard let root = try? OrderedJSON.parse(data), root.objectPairs != nil else {
            throw Problem(message: "mcp.json is not valid JSON.")
        }
        if let listed = root["mcpServers"], listed.objectPairs == nil {
            throw Problem(message: "\"mcpServers\" in mcp.json should be an object, one entry per server.")
        }
        return root
    }

    /// Whole and synced, renamed over the old one (never removed first), keeping the
    /// file's own permissions when it had some.
    private static func write(_ root: OrderedJSON, to url: URL) throws {
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
        try StoreCoding.writeAtomically(Data((root.stringified() + "\n").utf8), to: url, permissions: mode)
    }
}

extension OrderedJSON {
    /// Build an mcpServers entry from transport pieces with `${NAME}` already in place.
    static func mcpEntry(stdio command: String, args: [String], env: [(String, String)]) -> OrderedJSON {
        var pairs: [(String, OrderedJSON)] = [
            ("command", .string(command)),
            ("args", .array(args.map { .string($0) })),
        ]
        if !env.isEmpty {
            pairs.append(("env", .object(env.map { ($0.0, .string($0.1)) })))
        }
        return .object(pairs)
    }

    static func mcpEntry(http url: String, headers: [(String, String)], sse: Bool = false) -> OrderedJSON {
        var pairs: [(String, OrderedJSON)] = []
        if sse { pairs.append(("type", .string("sse"))) }
        else { pairs.append(("type", .string("http"))) }
        pairs.append(("url", .string(url)))
        if !headers.isEmpty {
            pairs.append(("headers", .object(headers.map { ($0.0, .string($0.1)) })))
        }
        return .object(pairs)
    }

    /// Wire shape for `mcp/preview`'s `entry` field.
    func asJSONObject() -> [String: JSONValue] {
        guard case .object(let pairs) = self else { return [:] }
        var out: [String: JSONValue] = [:]
        for (k, v) in pairs { out[k] = v.asJSONValue() }
        return out
    }

    func asJSONValue() -> JSONValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n):
            if let i = Int(n) { return .int(i) }
            return .double(Double(n) ?? 0)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map { $0.asJSONValue() })
        case .object(let pairs):
            return .object(Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1.asJSONValue()) }))
        }
    }
}
