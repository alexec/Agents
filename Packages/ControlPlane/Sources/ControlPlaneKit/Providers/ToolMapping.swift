import AgentsKitCore
import Foundation

/// How the control plane reads a provider's tools (#691): the contract's own
/// (contracts/provider-contract.md), or another server's through a tool map
/// (contracts/tool-map.md).
public struct ToolMapping: Sendable, Equatable {
    /// One contract tool and what stands for it.
    public struct Call: Sendable, Equatable {
        public var tool: String
        /// A template for its arguments; `{id}` is the workspace's id.
        public var arguments: JSONValue?
    }

    /// Where a list's workspaces are in the result.
    public struct Listing: Sendable, Equatable {
        /// The array: a path, `droplets[]` or `droplets`; empty for the result itself.
        public var items: String
        public var id: String
        public var name: String
        public var state: String
        public var ssh: String?
        public var tunnel: String?
        public var cost: String?
        /// Its words for a state, lower-cased, to a contract state.
        public var states: [String: String]
    }

    public var list: Call
    public var start: Call
    public var stop: Call
    public var listing: Listing
    /// The contract's own tools, read as the contract says; false for a map.
    public var native: Bool

    /// The contract's tools, as a provider that follows it offers them.
    public static let contract = ToolMapping(
        list: Call(tool: "workspaces_list"), start: Call(tool: "workspace_start", arguments: ["id": "{id}"]),
        stop: Call(tool: "workspace_stop", arguments: ["id": "{id}"]),
        listing: Listing(items: "workspaces", id: "id", name: "name", state: "state", ssh: "ssh", tunnel: "tunnel",
                         cost: "cost", states: [:]),
        native: true)

    public static let required = ["workspaces_list", "workspace_start", "workspace_stop"]
    public static let optional = ["workspace_options": "options", "workspace_create": "create", "workspace_delete": "delete"]

    /// A map as the provider's record keeps it. Throws saying what is wrong with it.
    public static func map(_ json: JSONValue) throws -> ToolMapping {
        func call(_ key: String) throws -> Call {
            guard let tool = json[key]?["tool"]?.stringValue, !tool.isEmpty else {
                throw ProviderFailure("The tool map has no \(key).tool.")
            }
            return Call(tool: tool, arguments: json[key]?["arguments"])
        }
        let list = json["list"]
        func path(_ key: String, required: Bool) throws -> String? {
            let value = list?[key]?.stringValue
            if required, value?.isEmpty ?? true { throw ProviderFailure("The tool map has no list.\(key).") }
            return value
        }
        var states: [String: String] = [:]
        for (word, state) in list?["states"]?.objectValue ?? [:] {
            guard let state = state.stringValue, Self.states.contains(state) else {
                throw ProviderFailure("list.states.\(word) must be one of \(Self.states.joined(separator: ", ")).")
            }
            states[word.lowercased()] = state
        }
        return ToolMapping(
            list: try call("list"), start: try call("start"), stop: try call("stop"),
            listing: Listing(items: try path("items", required: false) ?? "", id: try path("id", required: true)!,
                             name: try path("name", required: true)!, state: try path("state", required: true)!,
                             ssh: try path("ssh", required: false), tunnel: try path("tunnel", required: false),
                             cost: try path("cost", required: false), states: states),
            native: false)
    }

    public static let states = ["running", "starting", "stopping", "stopped", "unknown"]

    /// The tool its server lacks, by its own name, first in the order list, start, stop.
    public func missing(from tools: [String]) -> String? {
        [list.tool, start.tool, stop.tool].first { !tools.contains($0) }
    }

    // MARK: Calls and results

    /// A call's arguments, with `{id}` filled in.
    public func arguments(_ call: Call, id: String?) -> JSONValue {
        guard let template = call.arguments else { return [:] }
        return Self.fill(template, ["id": id ?? ""])
    }

    /// What a tool answered, as JSON: `structuredContent`, or its first text parsed. A result
    /// with `isError` throws its text, cut to 1 KB.
    public static func content(of result: JSONValue) throws -> JSONValue {
        let text = result["content"]?.arrayValue?.first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue
        if result["isError"]?.boolValue == true {
            let said = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderFailure(said.isEmpty ? "The provider said no, and not why."
                                  : String(decoding: said.utf8.prefix(1024), as: UTF8.self))
        }
        if let structured = result["structuredContent"] { return structured }
        if let text, let parsed = try? JSONValue.parse(Data(text.utf8)) { return parsed }
        throw ProviderFailure("The provider’s answer isn’t JSON.")
    }

    /// The workspaces a list result holds, at most 200. One with no id or name is left out.
    public func workspaces(_ content: JSONValue) -> [DaemonAPI.WorkspaceInfo] {
        let array = Self.value(listing.items, in: content)?.arrayValue ?? []
        return array.prefix(200).compactMap(workspace)
    }

    /// One workspace, from an item of a list, or a start's or stop's `workspace`.
    public func workspace(_ item: JSONValue) -> DaemonAPI.WorkspaceInfo? {
        guard let id = Self.text(listing.id, in: item), !id.isEmpty,
              let name = Self.text(listing.name, in: item), !name.isEmpty else { return nil }
        let said = Self.text(listing.state, in: item)?.lowercased() ?? "unknown"
        let state = listing.states[said] ?? (Self.states.contains(said) ? said : "unknown")
        return DaemonAPI.WorkspaceInfo(
            id: id, name: name, state: state,
            ssh: listing.ssh.flatMap { Self.text($0, in: item) }.flatMap { $0.isEmpty ? nil : $0 },
            tunnel: listing.tunnel.flatMap { Self.value($0, in: item)?.boolValue },
            cost: listing.cost.flatMap { Self.text($0, in: item) }.map { String($0.prefix(120)) })
    }

    // MARK: Paths

    /// The value at a path: dotted keys, `[n]` indexes, and a trailing `[]` (the array
    /// itself). Empty is the value.
    static func value(_ path: String, in json: JSONValue) -> JSONValue? {
        var path = Substring(path)
        if path.hasSuffix("[]") { path = path.dropLast(2) }
        var current: JSONValue? = json
        for part in path.split(separator: ".", omittingEmptySubsequences: true) {
            var key = part
            var indexes: [Int] = []
            while key.hasSuffix("]"), let open = key.lastIndex(of: "[") {
                guard let n = Int(key[key.index(after: open)..<key.index(before: key.endIndex)]) else { return nil }
                indexes.insert(n, at: 0)
                key = key[..<open]
            }
            if !key.isEmpty { current = current?[String(key)] }
            for n in indexes {
                guard let array = current?.arrayValue, array.indices.contains(n) else { return nil }
                current = array[n]
            }
            if current == nil { return nil }
        }
        return current
    }

    /// A path's value as text, or a template's: `root@{networks.v4[0].ip_address}` fills
    /// each `{path}`, and is nil when any of them finds nothing.
    static func text(_ pathOrTemplate: String, in json: JSONValue) -> String? {
        guard pathOrTemplate.contains("{") else { return scalar(value(pathOrTemplate, in: json)) }
        var out = ""
        var rest = Substring(pathOrTemplate)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            guard let found = scalar(value(String(rest[rest.index(after: open)..<close]), in: json)) else { return nil }
            out += found
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private static func scalar(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?: s
        case .bool(let b)?: String(b)
        case .int(let i)?: String(i)
        case .double(let d)?: d.rounded() == d && abs(d) < 1e15 ? String(Int(d)) : String(d)
        default: nil
        }
    }

    /// A JSON template with each `{key}` in its strings filled in. A string that is only
    /// `{id}` stays a string.
    static func fill(_ template: JSONValue, _ values: [String: String]) -> JSONValue {
        switch template {
        case .string(let s):
            var out = s
            for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: value) }
            return .string(out)
        case .array(let a): return .array(a.map { fill($0, values) })
        case .object(let o): return .object(o.mapValues { fill($0, values) })
        default: return template
        }
    }
}

/// A provider's failure, in words for the strip and the Providers page.
public struct ProviderFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
