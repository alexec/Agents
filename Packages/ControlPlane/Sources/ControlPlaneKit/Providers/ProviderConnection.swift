import AgentsKit
import AgentsKitCore
import Foundation

/// What the control plane asks of a provider: a `ProviderConnection`, or a stand-in in tests.
public protocol WorkspaceProvider: Sendable {
    func check() async throws -> ProviderConnection.Checked
    func list() async throws -> [DaemonAPI.WorkspaceInfo]
    @discardableResult func start(_ id: String) async throws -> DaemonAPI.WorkspaceInfo?
    @discardableResult func stop(_ id: String) async throws -> DaemonAPI.WorkspaceInfo?
    func end() async
}

/// One provider's MCP server, reached as its record says (#691, research R1–R2, R5): the
/// command provider, a server the control plane runs, or one at an address. It checks the
/// server is a provider, and calls its tools with the contract's timeouts (FR-005).
public actor ProviderConnection: WorkspaceProvider {
    /// How long a call may take: a list, then a start or stop.
    public struct Timing: Sendable {
        public var quick: Duration
        public var long: Duration
        public static let standard = Timing(quick: .seconds(30), long: .seconds(600))
        public init(quick: Duration, long: Duration) {
            self.quick = quick
            self.long = long
        }
    }

    /// What `check` found.
    public struct Checked: Sendable, Equatable {
        public var capabilities: [String]
        public var contract: Int
        public var workspaces: [DaemonAPI.WorkspaceInfo]
        public init(capabilities: [String] = [], contract: Int = 1, workspaces: [DaemonAPI.WorkspaceInfo]) {
            self.capabilities = capabilities
            self.contract = contract
            self.workspaces = workspaces
        }
    }

    /// The contract versions this control plane reads.
    public static let contracts = [1]

    public let record: ProviderRecord
    private let server: MCPServer
    private let mapping: ToolMapping
    private let cwd: URL
    private let timing: Timing
    private let log: @Sendable (String) -> Void
    private var client: MCPToolClient?

    /// Throws when the record can't be reached as it is: a map that doesn't parse, or no
    /// command provider to run.
    public init(record: ProviderRecord, secrets: [String: String], cwd: URL, timing: Timing = .standard,
                commandProvider: URL? = ProviderConnection.commandProvider(),
                log: @escaping @Sendable (String) -> Void) throws {
        self.record = record
        self.cwd = cwd
        self.timing = timing
        self.log = log
        mapping = try record.map.map(ToolMapping.map) ?? .contract
        server = try Self.server(for: record, secrets: secrets, commandProvider: commandProvider)
    }

    /// The MCP server a record stands for, with its secrets: as environment for one it runs,
    /// in its headers for one at an address. Never logged.
    static func server(for record: ProviderRecord, secrets: [String: String], commandProvider: URL?) throws -> MCPServer {
        let name = "provider \(record.id.rawValue)"
        switch record.kind {
        case .commands:
            guard let binary = commandProvider else {
                throw ProviderFailure("workspace-commands isn’t installed beside the control plane.")
            }
            let config = String(decoding: (try? JSONEncoder().encode(record.commands ?? [:])) ?? Data("{}".utf8), as: UTF8.self)
            return MCPServer(name: name, transport: .stdio(command: binary.path, args: [],
                                                           env: secrets.merging(["WORKSPACE_COMMANDS_CONFIG": config]) { $1 }))
        case .stdio:
            return MCPServer(name: name, transport: .stdio(command: record.command ?? "", args: record.args ?? [], env: secrets))
        case .http:
            let headers = (record.headers ?? [:]).mapValues { value in
                secrets.reduce(value) { $0.replacingOccurrences(of: "${\($1.key)}", with: $1.value) }
            }
            return MCPServer(name: name, transport: .http(url: record.url ?? "", headers: headers))
        }
    }

    /// `workspace-commands` (R5): beside `agents-control`, then `AGENTS_WORKSPACE_COMMANDS`,
    /// then on PATH.
    public static func commandProvider(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var candidates = [executable.deletingLastPathComponent().appendingPathComponent("workspace-commands")]
        if let given = environment["AGENTS_WORKSPACE_COMMANDS"], !given.isEmpty {
            candidates.append(URL(fileURLWithPath: given))
        }
        for folder in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(folder)).appendingPathComponent("workspace-commands"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Checking

    /// Whether the server is a provider (US2 AS2, AS6): the contract's tools or the map's,
    /// and a contract this control plane reads. Lists it once, so the list comes back too.
    public func check() async throws -> Checked {
        let tools = try await connected { try await $0.listTools() }
        if mapping.native {
            let missing = ToolMapping.required.filter { !tools.contains($0) }
            if !missing.isEmpty {
                throw ProviderFailure("It isn’t a workspace provider: it has no \(Self.list(missing)) tool.")
            }
        } else if let missing = mapping.missing(from: tools) {
            throw ProviderFailure("The tool map names \(missing), which the server doesn’t have.")
        }
        let content = try await call(mapping.list, id: nil, timeout: timing.quick)
        var contract = 1
        if mapping.native {
            guard let said = content["contract"]?.intValue else {
                throw ProviderFailure("Its workspaces_list doesn’t say which contract it follows.")
            }
            guard Self.contracts.contains(said) else {
                throw ProviderFailure("It follows contract \(said); this control plane reads \(Self.contracts.map(String.init).joined(separator: ", ")).")
            }
            contract = said
        } else if ToolMapping.value(mapping.listing.items, in: content)?.arrayValue == nil {
            throw ProviderFailure("The tool map’s list.items finds no list in what \(mapping.list.tool) answered.")
        }
        let capabilities = mapping.native ? ToolMapping.optional.filter { tools.contains($0.key) }.map(\.value).sorted() : []
        return Checked(capabilities: capabilities, contract: contract, workspaces: mapping.workspaces(content))
    }

    // MARK: Calls

    public func list() async throws -> [DaemonAPI.WorkspaceInfo] {
        mapping.workspaces(try await call(mapping.list, id: nil, timeout: timing.quick))
    }

    /// Starts the workspace; its state after, when the provider said.
    @discardableResult
    public func start(_ id: String) async throws -> DaemonAPI.WorkspaceInfo? {
        try await act(mapping.start, id)
    }

    @discardableResult
    public func stop(_ id: String) async throws -> DaemonAPI.WorkspaceInfo? {
        try await act(mapping.stop, id)
    }

    private func act(_ call: ToolMapping.Call, _ id: String) async throws -> DaemonAPI.WorkspaceInfo? {
        let content = try await self.call(call, id: id, timeout: timing.long)
        return mapping.native ? content["workspace"].flatMap(mapping.workspace) : nil
    }

    public func end() async {
        await client?.end()
        client = nil
    }

    private func call(_ call: ToolMapping.Call, id: String?, timeout: Duration) async throws -> JSONValue {
        let arguments = mapping.arguments(call, id: id)
        let result = try await connected { try await $0.callTool(call.tool, arguments: arguments, timeout: timeout) }
        return try ToolMapping.content(of: result)
    }

    /// `work` on a live connection: made when there is none, and made once more when the
    /// one there has gone (a stdio server that ended, an http session it forgot).
    private func connected<T: Sendable>(_ work: (MCPToolClient) async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            let client: MCPToolClient
            if let held = self.client {
                client = held
            } else {
                client = MCPToolClient(server: server, cwd: cwd, timeout: timing.quick, log: log)
                do {
                    try await client.connect()
                } catch {
                    await client.end()
                    throw ProviderFailure(Self.unreachable(error))
                }
                self.client = client
            }
            do {
                return try await work(client)
            } catch let error as MCPToolClient.Failure {
                // Only a connection that went is tried again: a call the server heard and
                // refused, or ran out of time on, could start a workspace twice.
                if attempt == 0, error.retriable, self.client === client {
                    await client.end()
                    self.client = nil
                    continue
                }
                throw ProviderFailure(error.timedOut ? "It didn’t answer in time." : error.description)
            }
        }
        throw ProviderFailure("It can’t be reached.")
    }

    static func unreachable(_ error: MCPToolClient.Failure) -> String {
        error.authRequired ? "It wants a sign-in, which providers can’t do yet: give it a token as a secret."
            : "It can’t be reached: \(error.description)"
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " or " + names.last!
        }
    }
}
