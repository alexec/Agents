import AgentsKitCore
import Foundation

/// A server typed on the sheet, turned into the `mcp.json` entry that would be written and the
/// server Verify connects to (#305). Secrets are handled as a registry add does (060): the
/// entry holds `${NAME}`, and the value goes to the person's `secrets.env`, only once added.
struct MCPHandEntry: Sendable {
    /// What is written: `${NAME}` where a secret goes.
    var entry: OrderedJSON
    /// The same, as a server, `${NAME}` still in it.
    var stored: MCPServer
    /// With every `${NAME}` filled: what Verify connects to. Never logged, never kept.
    var filled: MCPServer
    /// Values typed on the sheet, to write to `secrets.env` on Add.
    var newSecrets: [String: String]
    var run: DaemonAPI.MCPRunKind

    static func build(_ hand: DaemonAPI.MCPHandServer, secrets: SecretsEnv) throws -> MCPHandEntry {
        let name = hand.name.trimmingCharacters(in: .whitespaces)
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil else {
            throw DaemonAPI.MCPCatalogError.invalid("A name is letters, digits, dots, dashes and underscores, starting with a letter or digit.")
        }
        var newSecrets: [String: String] = [:]

        /// One value as the entry holds it: itself, or `${NAME}` for a secret.
        func held(_ value: DaemonAPI.MCPHandValue, header: Bool) throws -> String {
            guard value.secret else { return value.value }
            let given = value.secretName?.trimmingCharacters(in: .whitespaces) ?? ""
            let secretName = given.isEmpty
                ? DaemonAPI.MCPHandServer.defaultSecretName(server: name, value: value.name, header: header)
                : given
            guard Self.isVariableName(secretName) else {
                throw DaemonAPI.MCPCatalogError.invalid("A secret's name is letters, digits and underscores: \(secretName) is not.")
            }
            if !value.value.isEmpty {
                if let other = newSecrets[secretName], other != value.value {
                    throw DaemonAPI.MCPCatalogError.invalid("\(secretName) is given two different values.")
                }
                newSecrets[secretName] = value.value
            } else if secrets.value(of: secretName) == nil {
                throw DaemonAPI.MCPCatalogError.missingSecret(name: secretName)
            }
            return "${\(secretName)}"
        }

        let entry: OrderedJSON
        let stored: MCPServer
        let run: DaemonAPI.MCPRunKind
        switch hand.kind {
        case .command:
            let command = hand.command.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { throw DaemonAPI.MCPCatalogError.invalid("A local server needs a command.") }
            var env: [(String, String)] = []
            for value in hand.env where !value.name.isEmpty || !value.value.isEmpty {
                let key = value.name.trimmingCharacters(in: .whitespaces)
                guard Self.isVariableName(key) else {
                    throw DaemonAPI.MCPCatalogError.invalid("A variable's name is letters, digits and underscores: \(key.isEmpty ? "one has none" : "\(key) is not").")
                }
                guard !env.contains(where: { $0.0 == key }) else {
                    throw DaemonAPI.MCPCatalogError.invalid("\(key) is set twice.")
                }
                env.append((key, try held(value, header: false)))
            }
            entry = .mcpEntry(stdio: command, args: hand.args, env: env)
            stored = MCPServer(name: name, transport: .stdio(command: command, args: hand.args,
                                                             env: Dictionary(uniqueKeysWithValues: env)))
            run = .command
        case .url:
            let url = hand.url.trimmingCharacters(in: .whitespaces)
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host?.isEmpty == false else {
                throw DaemonAPI.MCPCatalogError.invalid("A remote server's URL starts with https:// (or http://).")
            }
            var headers: [(String, String)] = []
            for value in hand.headers where !value.name.isEmpty || !value.value.isEmpty {
                let key = value.name.trimmingCharacters(in: .whitespaces)
                guard key.range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil else {
                    throw DaemonAPI.MCPCatalogError.invalid("A header's name is one word: \(key.isEmpty ? "one has none" : "\(key) is not").")
                }
                guard !headers.contains(where: { $0.0.lowercased() == key.lowercased() }) else {
                    throw DaemonAPI.MCPCatalogError.invalid("\(key) is set twice.")
                }
                headers.append((key, try held(value, header: true)))
            }
            entry = .mcpEntry(http: url, headers: headers)
            stored = MCPServer(name: name, transport: .http(url: url, headers: Dictionary(uniqueKeysWithValues: headers)))
            run = .remote
        }

        // A plain value may name a secret already set, as `${NAME}`; every one has to be.
        var overlay = secrets
        for (key, value) in newSecrets { overlay.set(key, value: value) }
        guard let filled = overlay.filled(stored) else {
            let missing = SecretsEnv.referencedNames(in: stored).first { overlay.value(of: $0) == nil } ?? "A secret"
            throw DaemonAPI.MCPCatalogError.missingSecret(name: missing)
        }
        return MCPHandEntry(entry: entry, stored: stored, filled: filled, newSecrets: newSecrets, run: run)
    }

    static func isVariableName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// What Verify says, in words, for a client that did not get an answer.
    static func sentence(_ failure: MCPClient.Failure, timeout: Int) -> String {
        switch failure {
        case .authRequired: "It asks for a sign-in."
        case .httpStatus(let status): "It answered with HTTP \(status), not as an MCP server."
        case .sessionExpired: "It dropped the session it had just opened."
        case .unreachable(let why): why
        case .stopped(let why) where why == "The server stopped.": "The server stopped before it answered."
        case .stopped(let why): why
        case .timedOut: "It did not answer within \(timeout) seconds."
        case .refused(_, let message, _): message.isEmpty ? "It refused to start a session." : "It refused: \(message)"
        case .notMCP: "What came back was not MCP."
        case .transportNotSupported: "The app can't connect to a server of that kind."
        }
    }
}

/// Servers that answered Verify, kept in memory until added, or for 30 minutes (#305).
/// Holds the secret values typed on the sheet: never written anywhere but `secrets.env`.
actor MCPVerifiedStore {
    struct Verified: Sendable {
        var destination: DaemonAPI.SkillDestination
        var built: MCPHandEntry
    }

    private var items: [UUID: (Verified, Date)] = [:]

    func put(_ verified: Verified) -> UUID {
        let now = Date()
        items = items.filter { $0.value.1 > now }
        let id = UUID()
        items[id] = (verified, now.addingTimeInterval(30 * 60))
        return id
    }

    func take(_ id: UUID) -> Verified? {
        guard let (verified, expiry) = items.removeValue(forKey: id), expiry > Date() else { return nil }
        return verified
    }
}
