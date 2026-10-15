import Foundation
import MCPServerKit

/// What the command provider runs (#691, contracts/command-provider.md): its whole
/// configuration, from `WORKSPACE_COMMANDS_CONFIG`.
///
/// Workspaces are either written out, each with its own commands, or listed by one command
/// whose rows fill in shared templates. A preset is a set of these, compiled in.
public struct CommandConfig: Sendable, Equatable {
    /// One workspace written out: its commands are run as they are, with `${id}` and
    /// `${name}` filled in.
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var name: String
        public var commands: Commands
    }

    /// The commands and details shared by every workspace a listing gives, as templates.
    public struct Commands: Sendable, Equatable {
        public var start: String
        public var stop: String
        /// Prints the workspace's state; nil when only a listing (or nothing) says.
        public var status: String?
        /// Not a command: filled in without shell quoting.
        public var ssh: String?
        public var tunnel: Bool
        public var cost: String?
    }

    /// Many workspaces from one command.
    public struct Listing: Sendable, Equatable {
        public enum Shape: Sendable, Equatable {
            /// One workspace per line, split on whitespace into these names; the last takes
            /// what is left of the line.
            case columns([String])
            /// JSON: the array at `items` (empty for the whole output), and a path within each
            /// item for each field (`id`, `name`, `state`, and any other a template names).
            case json(items: String, fields: [String: String])
        }

        public var command: String
        public var shape: Shape
        public var commands: Commands
        /// Values for a row that leaves a column or field empty, such as a preset's ssh line.
        public var defaults: [String: String] = [:]
    }

    /// Making and deleting workspaces (US5): only beside a listing, which finds what was made.
    public struct Making: Sendable, Equatable {
        /// Makes one: `${name}`, `${firstBoot}` and each option's key are filled in.
        public var create: String?
        /// Deletes one: `${id}` and its listing's values are filled in.
        public var delete: String?
        /// The New Workspace form, as a flat JSON Schema object (`workspace_options`).
        public var options: JSON?

        public init(create: String? = nil, delete: String? = nil, options: JSON? = nil) {
            self.create = create
            self.delete = delete
            self.options = options
        }

        /// Whether a made workspace runs the first-boot install itself.
        public var firstBootRuns: Bool { create?.contains("${firstBoot}") == true }
    }

    public var workspaces: [Entry]
    public var listing: Listing?
    /// The CLI's words for a state, lower-cased, to a contract state.
    public var states: [String: WorkspaceState]
    public var making: Making

    public init(workspaces: [Entry] = [], listing: Listing? = nil, states: [String: WorkspaceState] = [:],
                making: Making = Making()) {
        self.workspaces = workspaces
        self.listing = listing
        self.states = Dictionary(states.map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
        self.making = making
    }

    /// The contract state for what a status command or a listing said.
    public func state(for said: String) -> WorkspaceState {
        let word = said.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return states[word] ?? WorkspaceState(rawValue: word) ?? .unknown
    }
}

/// A workspace's state, as the contract names them.
public enum WorkspaceState: String, Sendable, Equatable, CaseIterable {
    case running, starting, stopping, stopped, unknown
}

/// Why a configuration can't be used, in words for the person who wrote it.
public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

// MARK: Reading

extension CommandConfig {
    /// `WORKSPACE_COMMANDS_CONFIG`'s text.
    public static func parse(_ text: String) throws(ConfigError) -> CommandConfig {
        let json: JSON
        do { json = try JSON.parse(text) } catch { throw ConfigError("WORKSPACE_COMMANDS_CONFIG isn't JSON") }
        return try from(json)
    }

    public static func from(_ json: JSON) throws(ConfigError) -> CommandConfig {
        guard json.object != nil else { throw ConfigError("the configuration must be a JSON object") }
        if let preset = json["preset"]?.string { return try Presets.expand(preset, json) }
        let states = try stateMap(json["states"])
        if let list = json["list"]?.string {
            guard !list.isEmpty else { throw ConfigError("list is empty") }
            let shape: Listing.Shape
            if let fields = json["json"]?.object {
                var paths: [String: String] = [:]
                for (key, value) in fields where key != "items" {
                    guard let path = value.string else { throw ConfigError("json.\(key) must be a path") }
                    paths[key] = path
                }
                guard paths["id"] != nil else { throw ConfigError("json needs an id path") }
                shape = .json(items: fields["items"]?.string ?? "", fields: paths)
            } else if let columns = json["columns"]?.array?.compactMap(\.string), !columns.isEmpty {
                guard columns.contains("id") else { throw ConfigError("columns must name an id column") }
                shape = .columns(columns)
            } else {
                throw ConfigError("a list needs columns, or json paths")
            }
            return CommandConfig(listing: Listing(command: list, shape: shape, commands: try commands(json, "")),
                                 states: states, making: try making(json))
        }
        if json["create"] != nil || json["delete"] != nil {
            throw ConfigError("create and delete need a list command, which finds what they made")
        }
        guard let items = json["workspaces"]?.array, !items.isEmpty else {
            throw ConfigError("give workspaces, a list command, or a preset")
        }
        var entries: [Entry] = []
        for (n, item) in items.enumerated() {
            guard let name = item["name"]?.string ?? item["id"]?.string, !name.isEmpty else {
                throw ConfigError("workspace \(n + 1) has no name")
            }
            let id = item["id"]?.string ?? name
            guard !entries.contains(where: { $0.id == id }) else { throw ConfigError("two workspaces are called \(id)") }
            entries.append(Entry(id: id, name: name, commands: try commands(item, "\(name): ")))
        }
        return CommandConfig(workspaces: entries, states: states)
    }

    private static func commands(_ json: JSON, _ whose: String) throws(ConfigError) -> Commands {
        guard let start = json["start"]?.string, !start.isEmpty else { throw ConfigError("\(whose)no start command") }
        guard let stop = json["stop"]?.string, !stop.isEmpty else { throw ConfigError("\(whose)no stop command") }
        return Commands(start: start, stop: stop, status: json["status"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                        ssh: json["ssh"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                        tunnel: json["tunnel"]?.bool ?? false,
                        cost: json["cost"]?.string.map { String($0.prefix(120)) })
    }

    private static func making(_ json: JSON) throws(ConfigError) -> Making {
        let create = json["create"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let delete = json["delete"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let options = json["options"]
        if let options, options.object == nil { throw ConfigError("options must be a JSON Schema object") }
        if options != nil, create == nil { throw ConfigError("options are for a create command, and there is none") }
        return Making(create: create, delete: delete, options: options)
    }

    private static func stateMap(_ json: JSON?) throws(ConfigError) -> [String: WorkspaceState] {
        guard let json else { return [:] }
        guard let o = json.object else { throw ConfigError("states must map words to states") }
        var map: [String: WorkspaceState] = [:]
        for (word, state) in o {
            guard let state = state.string.flatMap(WorkspaceState.init(rawValue:)) else {
                throw ConfigError("states.\(word) must be one of \(WorkspaceState.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            map[word] = state
        }
        return map
    }
}

// MARK: Templates

public enum Template {
    /// `template` with each `${key}` replaced by its value, quoted for `/bin/sh` when `quoted`.
    /// A key with no value is left as it is, so the shell can read a variable of that name
    /// (a secret, such as `$TOKEN` written `${TOKEN}`).
    public static func fill(_ template: String, _ values: [String: String], quoted: Bool) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "${") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let key = String(rest[open.upperBound..<close])
            if let value = values[key] {
                out += quoted ? shellQuoted(value) : value
            } else {
                out += rest[open.lowerBound...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// One word to `/bin/sh`, whatever it holds.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: Paths

/// A path into JSON: dotted keys and `[n]` indexes, as in `networks.v4[0].ip_address`.
/// Empty is the value itself.
public enum JSONPath {
    public static func value(_ path: String, in json: JSON) -> JSON? {
        var current: JSON? = json
        for part in path.split(separator: ".", omittingEmptySubsequences: true) {
            var key = Substring(part)
            var indexes: [Int] = []
            while key.hasSuffix("]"), let open = key.lastIndex(of: "[") {
                guard let n = Int(key[key.index(after: open)..<key.index(before: key.endIndex)]) else { return nil }
                indexes.insert(n, at: 0)
                key = key[..<open]
            }
            if !key.isEmpty { current = current?[String(key)] }
            for n in indexes { current = current?[n] }
            if current == nil { return nil }
        }
        return current
    }

    /// The value as text: strings as they are, numbers and booleans written out.
    public static func text(_ path: String, in json: JSON) -> String? {
        switch value(path, in: json) {
        case .string(let s)?: s
        case .int(let i)?: String(i)
        case .double(let d)?: String(d)
        case .bool(let b)?: String(b)
        default: nil
        }
    }
}
