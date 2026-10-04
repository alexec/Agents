import Foundation
import AgentsKitCore

/// `~/.agents/secrets.env` (060, contracts/secrets-env.md): KEY=value lines, mode 0600.
/// Values never leave this type except when filling a session's servers.
struct SecretsEnv: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case assignment(name: String, value: String)
            case other(String)
        }
        var kind: Kind
    }

    var lines: [Line]

    static let fileName = "secrets.env"

    static func url(home: URL) -> URL {
        home.appending(path: PersonalDotAgents.folder).appending(path: fileName)
    }

    /// Names that have a value, in file order. Never the values.
    var names: [String] {
        lines.compactMap {
            if case .assignment(let name, _) = $0.kind { return name }
            return nil
        }
    }

    func value(of name: String) -> String? {
        for line in lines {
            if case .assignment(let n, let v) = line.kind, n == name { return v }
        }
        return nil
    }

    var isSet: (String) -> Bool { { value(of: $0) != nil } }

    /// A `secrets.env` that is there and could not be read (not allowed, a read error that
    /// did not pass, bytes that are not UTF-8). Nothing is written over it (#205): every
    /// other secret in it would go, and they are in no git history.
    struct Unreadable: Error, Equatable {
        var path: String
        var message: String {
            "secrets.env could not be read, so nothing was written to it and the secrets in it are kept. Check its permissions and contents at \(path), then try again."
        }
    }

    /// What is set, for reading only: an unreadable file reads as nothing set. A write
    /// goes through `loadForChange`.
    static func load(from url: URL) -> SecretsEnv {
        (try? loadForChange(from: url)) ?? SecretsEnv(lines: [])
    }

    /// What is set, to change and save. A missing file is empty; one that is there and
    /// does not read is refused, after one more try for a passing error.
    static func loadForChange(from url: URL) throws -> SecretsEnv {
        guard FileManager.default.fileExists(atPath: url.path) else { return SecretsEnv(lines: []) }
        guard let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: url)),
              let text = String(data: data, encoding: .utf8) else {
            throw Unreadable(path: url.path)
        }
        return parse(text)
    }

    static func parse(_ text: String) -> SecretsEnv {
        var lines: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("#") || raw.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(Line(kind: .other(raw)))
                continue
            }
            guard let eq = raw.firstIndex(of: "=") else {
                lines.append(Line(kind: .other(raw)))
                continue
            }
            let name = String(raw[..<eq])
            let value = String(raw[raw.index(after: eq)...])
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                lines.append(Line(kind: .other(raw)))
                continue
            }
            lines.append(Line(kind: .assignment(name: name, value: value)))
        }
        return SecretsEnv(lines: lines)
    }

    /// Replace or append one name. Other lines stay in order.
    mutating func set(_ name: String, value: String) {
        if let at = lines.firstIndex(where: {
            if case .assignment(let n, _) = $0.kind { return n == name }
            return false
        }) {
            lines[at] = Line(kind: .assignment(name: name, value: value))
        } else {
            lines.append(Line(kind: .assignment(name: name, value: value)))
        }
    }

    mutating func remove(_ name: String) {
        lines.removeAll {
            if case .assignment(let n, _) = $0.kind { return n == name }
            return false
        }
    }

    func text() -> String {
        var out = lines.map { line -> String in
            switch line.kind {
            case .assignment(let name, let value): return "\(name)=\(value)"
            case .other(let s): return s
            }
        }.joined(separator: "\n")
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Write whole, mode 0600 from the moment the file is made: a synced temporary file
    /// renamed over the old one, so a crash leaves the old secrets or the new, never none,
    /// and no copy is ever readable by others (#205).
    func save(to url: URL) throws {
        try StoreCoding.writeAtomically(Data(text().utf8), to: url, permissions: 0o600)
    }

    /// Replace `${NAME}` in a string. Returns nil when a name is missing.
    func fill(_ text: String) -> String? {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "$", text.index(i, offsetBy: 1, limitedBy: text.endIndex).map({ text[$0] == "{" }) == true {
                let open = text.index(i, offsetBy: 2)
                guard let close = text[open...].firstIndex(of: "}") else {
                    out.append(text[i]); i = text.index(after: i); continue
                }
                let name = String(text[open..<close])
                guard let value = value(of: name) else { return nil }
                out += value
                i = text.index(after: close)
            } else {
                out.append(text[i])
                i = text.index(after: i)
            }
        }
        return out
    }

    /// Fill every string in a server's transport. Nil if any `${NAME}` is missing.
    func filled(_ server: MCPServer) -> MCPServer? {
        switch server.transport {
        case .stdio(let command, let args, let env):
            guard let command = fill(command) else { return nil }
            var newArgs: [String] = []
            for a in args {
                guard let f = fill(a) else { return nil }
                newArgs.append(f)
            }
            var newEnv: [String: String] = [:]
            for (k, v) in env {
                guard let f = fill(v) else { return nil }
                newEnv[k] = f
            }
            return MCPServer(name: server.name, transport: .stdio(command: command, args: newArgs, env: newEnv))
        case .http(let url, let headers):
            guard let url = fill(url) else { return nil }
            var newHeaders: [String: String] = [:]
            for (k, v) in headers {
                guard let f = fill(v) else { return nil }
                newHeaders[k] = f
            }
            return MCPServer(name: server.name, transport: .http(url: url, headers: newHeaders))
        case .sse(let url, let headers):
            guard let url = fill(url) else { return nil }
            var newHeaders: [String: String] = [:]
            for (k, v) in headers {
                guard let f = fill(v) else { return nil }
                newHeaders[k] = f
            }
            return MCPServer(name: server.name, transport: .sse(url: url, headers: newHeaders))
        }
    }

    /// Names referenced as `${NAME}` in a string.
    static func referencedNames(in text: String) -> [String] {
        var names: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "$", text.index(i, offsetBy: 1, limitedBy: text.endIndex).map({ text[$0] == "{" }) == true {
                let open = text.index(i, offsetBy: 2)
                if let close = text[open...].firstIndex(of: "}") {
                    names.append(String(text[open..<close]))
                    i = text.index(after: close)
                    continue
                }
            }
            i = text.index(after: i)
        }
        return names
    }

    static func referencedNames(in server: MCPServer) -> [String] {
        var names: [String] = []
        switch server.transport {
        case .stdio(let command, let args, let env):
            names += referencedNames(in: command)
            args.forEach { names += referencedNames(in: $0) }
            env.values.forEach { names += referencedNames(in: $0) }
        case .http(let url, let headers), .sse(let url, let headers):
            names += referencedNames(in: url)
            headers.values.forEach { names += referencedNames(in: $0) }
        }
        return names
    }
}
