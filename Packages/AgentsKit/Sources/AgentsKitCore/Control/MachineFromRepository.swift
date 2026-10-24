import Foundation

/// Start a Machine from a Repository (#1809): pick a repository, pick a provider that makes
/// machines, start. The control plane gives the repository to the provider (Codespaces makes
/// the codespace from it) or has the new host clone it once it joins, and the folder shows
/// then. The web page's `machineFromRepository.ts` is the same.
public enum MachineFromRepository {
    /// An https repository address, as the control plane takes one (`repositoryPath`).
    public struct Repository: Equatable, Sendable {
        public var url: String
        /// owner/name, or group/subgroup/name.
        public var path: String
        /// The last part, without `.git`.
        public var name: String
    }

    public static func repository(_ text: String) -> Repository? {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, url.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let parts = URLComponents(string: url), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil
        else { return nil }
        var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.contains("/"), !path.contains("//"), let name = path.split(separator: "/").last else { return nil }
        return Repository(url: url, path: path, name: String(name))
    }

    /// A host name for the machine: the repository's name in letters, digits and dashes,
    /// starting with a letter, and a short `suffix` so a second machine from it has its own.
    public static func machineName(_ repository: String, suffix: String) -> String {
        var base = ""
        var dash = false
        for c in repository.lowercased() {
            if c.isASCII, c.isLetter || c.isNumber {
                if dash, !base.isEmpty { base.append("-") }
                base.append(c)
                dash = false
            } else {
                dash = true
            }
        }
        if base.first.map({ !$0.isLetter }) ?? true { base = base.isEmpty ? "m" : "m-" + base }
        var cut = String(base.prefix(30))
        while cut.hasSuffix("-") { cut.removeLast() }
        return "\(cut)-\(suffix)"
    }

    /// Four hex digits for `machineName`.
    public static func nameSuffix() -> String { String(format: "%04x", Int.random(in: 0..<0x10000)) }

    /// The providers that can make a machine.
    public static func makers(_ providers: [DaemonAPI.ProviderSummary]) -> [DaemonAPI.ProviderSummary] {
        // Only those the person may start machines from (#1761).
        providers.filter { $0.capabilities.contains("create") && $0.usable }
    }

    /// One field of a provider's New Machine form.
    public struct Field: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case string, integer, boolean }
        public var key: String
        public var title: String
        public var kind: Kind
        public var choices: [String]?
        public var value: String
        public var help: String?
        public var id: String { key }
    }

    /// The form's fields, by key, but `repository`, which the repository fills.
    public static func fields(_ schema: JSONValue?) -> [Field] {
        let properties = schema?["properties"]?.objectValue ?? [:]
        return properties.keys.sorted().filter { $0 != "repository" }.map { key in
            let p = properties[key] ?? .null
            let type = p["type"]?.stringValue
            let kind: Field.Kind = type == "integer" || type == "number" ? .integer : type == "boolean" ? .boolean : .string
            return Field(key: key, title: p["title"]?.stringValue ?? key, kind: kind,
                         choices: p["enum"]?.arrayValue?.map(text), value: p["default"].map(text) ?? "",
                         help: p["description"]?.stringValue)
        }
    }

    private static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        default: ""
        }
    }

    /// What Start sends: providers/create with the repository, if any (#2131), and the form's
    /// values, typed.
    public static func request(_ provider: ProviderID, name: String, repository: Repository?,
                               fields: [Field]) -> DaemonAPI.ProviderCreate {
        var options: [String: JSONValue] = [:]
        for field in fields {
            let v = field.value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            switch field.kind {
            case .integer: options[field.key] = Int(v).map(JSONValue.int) ?? .string(v)
            case .boolean: options[field.key] = .bool(v == "true")
            case .string: options[field.key] = .string(v)
            }
        }
        return DaemonAPI.ProviderCreate(id: provider, name: name, options: .object(options), repository: repository?.url)
    }

    /// The web page's machineWords.
    public enum Words {
        public static let title = "Start a Machine from a Repository"
        public static let menuItem = "Start a Machine from a Repository…"
        public static let repositoryPrompt = "The repository’s https address"
        public static func repositoryNote(_ repository: Repository?, typed: Bool) -> String {
            if let repository { return "The machine clones \(repository.path) and adds it as a folder." }
            return typed ? "Give an https address of a repository, such as on GitHub or GitLab." : "The repository to work in."
        }
        public static let noMakers = "No provider here can make a machine. Add DigitalOcean, Compute Engine or Codespaces in Settings ▸ Machine providers."
        public static func starting(_ name: String) -> String { "Starting \(name)…" }
        public static func joining(_ name: String, _ repository: Repository) -> String {
            "\(name) is starting. It installs Agents, joins and clones \(repository.path) on its first boot. The folder shows when it has."
        }
        public static func notJoining(_ name: String, provider: String) -> String {
            "\(provider) made \(name), but can't install Agents on its first boot. Add it as a machine in the Mac app: Settings ▸ Machine Providers, Add as Machine…."
        }
        public static let privateNote = "A private repository needs git access on the new machine."
    }
}
