import Foundation

/// Turn a registry server into an `mcp.json` entry and the variables the sheet asks for
/// (060, R3, R4).
struct MCPEntryBuilder: Sendable {
    struct MacTools: Sendable, Equatable {
        var npx: Bool
        var uvx: Bool
        var docker: Bool

        static func detect() -> MacTools {
            MacTools(npx: which("npx"), uvx: which("uvx"), docker: which("docker"))
        }

        static func which(_ name: String) -> Bool {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
            for dir in path.split(separator: ":") {
                let url = URL(filePath: String(dir)).appending(path: name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return true }
            }
            return false
        }

        /// Everything available — for tests that do not care about the Mac.
        static let all = MacTools(npx: true, uvx: true, docker: true)
    }

    struct AvailableRuns: Sendable {
        var available: [DaemonAPI.MCPRunKind]
        var unavailable: [DaemonAPI.MCPRunKind]
        var foreignRemoteHost: String?
    }

    static func availableRuns(_ server: MCPRegistry.RegistryServer, onMac tools: MacTools) -> AvailableRuns {
        var available: [DaemonAPI.MCPRunKind] = []
        var unavailable: [DaemonAPI.MCPRunKind] = []
        var foreign: String?
        if let remotes = server.remotes, !remotes.isEmpty {
            available.append(.remote)
            if let remote = remotes.first, let url = remote.url, let host = URL(string: url)?.host {
                let own = MCPPublisher.ownHosts(registryName: server.name, repositoryURL: server.repository?.url)
                if !own.contains(host.lowercased()) { foreign = host }
            }
        }
        for pkg in server.packages ?? [] {
            switch pkg.registryType {
            case "npm":
                if tools.npx { available.append(.npx) } else { unavailable.append(.npx) }
            case "pypi":
                if tools.uvx { available.append(.uvx) } else { unavailable.append(.uvx) }
            case "oci":
                if tools.docker { available.append(.docker) } else { unavailable.append(.docker) }
            default:
                break
            }
        }
        // Unique, stable order
        let order: [DaemonAPI.MCPRunKind] = [.remote, .npx, .uvx, .docker]
        available = order.filter { available.contains($0) }
        unavailable = order.filter { unavailable.contains($0) }
        return AvailableRuns(available: available, unavailable: unavailable, foreignRemoteHost: foreign)
    }

    struct Built: Sendable {
        var nameHere: String
        var chosenRun: DaemonAPI.MCPRunKind
        var commandOrURL: String
        var hostLabel: String?
        var entry: OrderedJSON
        var variables: [DaemonAPI.MCPVariable]
        var transport: MCPServer.Transport
    }

    static func build(_ server: MCPRegistry.RegistryServer, run: DaemonAPI.MCPRunKind,
                      secretsAlreadySet: (String) -> Bool = { _ in false }) throws -> Built {
        let nameHere = slug(server.title ?? MCPPublisher.shortName(registryName: server.name))
        switch run {
        case .remote:
            guard let remote = server.remotes?.first, let url = remote.url else {
                throw DaemonAPI.MCPCatalogError.noRunnableWay
            }
            let host = URL(string: url)?.host
            let own = MCPPublisher.ownHosts(registryName: server.name, repositoryURL: server.repository?.url)
            let hostLabel: String?
            if let host {
                hostLabel = own.contains(host.lowercased())
                    ? "\(host) · the publisher's own"
                    : "\(host) · not the publisher's"
            } else { hostLabel = nil }
            var headers: [(String, String)] = []
            var variables: [DaemonAPI.MCPVariable] = []
            for h in remote.headers ?? [] {
                guard let headerName = h.name else { continue }
                let (value, vars) = headerValue(h, publisher: server.name)
                headers.append((headerName, value))
                for v in vars {
                    variables.append(marked(v, alreadySet: secretsAlreadySet))
                }
            }
            let sse = (remote.type == "sse")
            let entry = OrderedJSON.mcpEntry(http: url, headers: headers, sse: sse)
            let transport: MCPServer.Transport = sse
                ? .sse(url: url, headers: Dictionary(uniqueKeysWithValues: headers))
                : .http(url: url, headers: Dictionary(uniqueKeysWithValues: headers))
            return Built(nameHere: nameHere, chosenRun: .remote, commandOrURL: url,
                         hostLabel: hostLabel, entry: entry, variables: variables, transport: transport)

        case .npx:
            guard let pkg = server.packages?.first(where: { $0.registryType == "npm" }),
                  let id = pkg.identifier else { throw DaemonAPI.MCPCatalogError.noRunnableWay }
            let ver = pkg.version ?? server.version ?? "latest"
            let args = ["-y", "\(id)@\(ver)"]
            let (env, variables) = envFrom(pkg, secretsAlreadySet: secretsAlreadySet)
            let command = "npx " + args.joined(separator: " ")
            let entry = OrderedJSON.mcpEntry(stdio: "npx", args: args, env: env)
            return Built(nameHere: nameHere, chosenRun: .npx, commandOrURL: command, hostLabel: nil,
                         entry: entry, variables: variables,
                         transport: .stdio(command: "npx", args: args, env: Dictionary(uniqueKeysWithValues: env)))

        case .uvx:
            guard let pkg = server.packages?.first(where: { $0.registryType == "pypi" }),
                  let id = pkg.identifier else { throw DaemonAPI.MCPCatalogError.noRunnableWay }
            let ver = pkg.version ?? server.version ?? "latest"
            let args = ["\(id)==\(ver)"]
            let (env, variables) = envFrom(pkg, secretsAlreadySet: secretsAlreadySet)
            let command = "uvx " + args.joined(separator: " ")
            let entry = OrderedJSON.mcpEntry(stdio: "uvx", args: args, env: env)
            return Built(nameHere: nameHere, chosenRun: .uvx, commandOrURL: command, hostLabel: nil,
                         entry: entry, variables: variables,
                         transport: .stdio(command: "uvx", args: args, env: Dictionary(uniqueKeysWithValues: env)))

        case .docker:
            guard let pkg = server.packages?.first(where: { $0.registryType == "oci" }),
                  let id = pkg.identifier else { throw DaemonAPI.MCPCatalogError.noRunnableWay }
            var args = ["run", "-i", "--rm"]
            var variables: [DaemonAPI.MCPVariable] = []
            for arg in pkg.runtimeArguments ?? [] {
                if let name = arg.name { args.append(name) }
                if let value = arg.value {
                    let (filled, vars) = expandBraces(value)
                    args.append(filled)
                    variables += vars.map { marked($0, alreadySet: secretsAlreadySet) }
                }
            }
            args.append(id)
            let (env, envVars) = envFrom(pkg, secretsAlreadySet: secretsAlreadySet)
            variables += envVars
            let command = "docker " + args.joined(separator: " ")
            let entry = OrderedJSON.mcpEntry(stdio: "docker", args: args, env: env)
            return Built(nameHere: nameHere, chosenRun: .docker, commandOrURL: command, hostLabel: nil,
                         entry: entry, variables: variables,
                         transport: .stdio(command: "docker", args: args, env: Dictionary(uniqueKeysWithValues: env)))
        }
    }

    private static func envFrom(_ pkg: MCPRegistry.RegistryServer.Package,
                                secretsAlreadySet: (String) -> Bool) -> ([(String, String)], [DaemonAPI.MCPVariable]) {
        var env: [(String, String)] = []
        var variables: [DaemonAPI.MCPVariable] = []
        for v in pkg.environmentVariables ?? [] {
            guard let name = v.name else { continue }
            if v.isSecret == true {
                env.append((name, "${\(name)}"))
                variables.append(marked(.init(name: name, description: v.description ?? "", kind: .secret,
                                              required: v.isRequired ?? true, alreadySet: false, placeholder: nil),
                                        alreadySet: secretsAlreadySet))
            } else {
                let placeholder = v.defaultValue
                variables.append(.init(name: name, description: v.description ?? "", kind: .plain,
                                       required: v.isRequired ?? false, alreadySet: false, placeholder: placeholder))
                if let placeholder { env.append((name, placeholder)) }
            }
        }
        return (env, variables)
    }

    private static func headerValue(_ h: MCPRegistry.RegistryServer.Remote.Header,
                                    publisher: String) -> (String, [DaemonAPI.MCPVariable]) {
        if let value = h.value {
            return expandBraces(value)
        }
        let name = preferredSecretName(header: h.name ?? "TOKEN", publisher: publisher, description: h.description)
        let required = h.isRequired ?? (h.isSecret == true)
        let variable = DaemonAPI.MCPVariable(name: name, description: h.description ?? "", kind: .secret,
                                             required: required, alreadySet: false, placeholder: nil)
        // Authorization conventionally carries Bearer
        if (h.name ?? "").lowercased() == "authorization" {
            return ("Bearer ${\(name)}", [variable])
        }
        return ("${\(name)}", [variable])
    }

    private static func preferredSecretName(header: String, publisher: String, description: String?) -> String {
        let desc = (description ?? "").lowercased()
        if publisher.contains("github"), desc.contains("github") || desc.contains("pat") || desc.contains("token") {
            return "GITHUB_TOKEN"
        }
        if publisher.contains("upstash") || publisher.contains("context7") {
            return "CONTEXT7_API_KEY"
        }
        if desc.contains("smithery") { return "SMITHERY_API_KEY" }
        return header.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    /// `{token}` / `Bearer {smithery_api_key}` → `${TOKEN}` forms.
    private static func expandBraces(_ text: String) -> (String, [DaemonAPI.MCPVariable]) {
        var out = ""
        var vars: [DaemonAPI.MCPVariable] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "{" {
                let open = text.index(after: i)
                if let close = text[open...].firstIndex(of: "}") {
                    let raw = String(text[open..<close])
                    let name = raw.uppercased().replacingOccurrences(of: "-", with: "_")
                    out += "${\(name)}"
                    vars.append(.init(name: name, description: "", kind: .secret, required: true,
                                      alreadySet: false, placeholder: nil))
                    i = text.index(after: close)
                    continue
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return (out, vars)
    }

    private static func marked(_ v: DaemonAPI.MCPVariable, alreadySet: (String) -> Bool) -> DaemonAPI.MCPVariable {
        var copy = v
        copy.alreadySet = alreadySet(v.name)
        return copy
    }

    static func slug(_ title: String) -> String {
        let lower = title.lowercased()
        var out = ""
        var dash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch); dash = false
            } else if !dash && !out.isEmpty {
                out.append("-"); dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "server" : out
    }
}
