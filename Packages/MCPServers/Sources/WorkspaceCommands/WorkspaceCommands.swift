import Foundation
import MCPServerKit

/// The command provider (#691, FR-070): a workspace provider whose workspaces are shell
/// commands. It follows the provider contract (contracts/provider-contract.md), so the
/// control plane uses it as it uses any other provider.
///
/// It keeps nothing on disk. A workspace with no way to ask its state (no status command, no
/// listing) is as its last start or stop left it while the server runs, and `unknown` before.
public enum WorkspaceCommands {
    public static let version = "0.1.0"
    /// The provider contract's version (FR-001).
    public static let contract = 1
    /// What one list gives, at most.
    public static let listLimit = 200

    /// How long a command may take, and how often a start or stop asks whether it is done.
    public struct Timing: Sendable {
        public var quick: Duration
        public var long: Duration
        public var pollEvery: Duration

        /// Under the control plane's own 30 seconds and 10 minutes, so its failure is ours,
        /// with our reason, rather than its timeout.
        public static let standard = Timing(quick: .seconds(25), long: .seconds(595), pollEvery: .seconds(5))

        public init(quick: Duration, long: Duration, pollEvery: Duration) {
            self.quick = quick
            self.long = long
            self.pollEvery = pollEvery
        }
    }

    /// Runs one line with `/bin/sh -c`, within a deadline.
    public typealias Runner = @Sendable (_ line: String, _ deadline: Duration) async -> ChildProcess.Outcome

    public static let shell: Runner = { line, deadline in
        await ChildProcess.run(URL(filePath: "/bin/sh"), ["-c", line], deadline: deadline, outputLimit: 1 << 20)
    }

    public static func server(_ config: CommandConfig, timing: Timing = .standard, run: @escaping Runner = shell) -> MCPServer {
        let provider = Provider(config: config, timing: timing, run: run)
        let id = Schema(["id": .string("The workspace's id, as workspaces_list gives it.", maxLength: 512)], required: ["id"])
        return MCPServer(
            info: .init(name: "workspace-commands", title: "Workspace commands", version: version),
            instructions: "A workspace provider (contract \(contract)): lists, starts and stops workspaces by running the shell commands it was configured with.",
            tools: [
                Tool(name: "workspaces_list", title: "List workspaces",
                     description: "Every workspace, with its state and how to reach it over ssh.",
                     inputSchema: Schema([:]), annotations: ["readOnlyHint": true]),
                Tool(name: "workspace_start", title: "Start a workspace",
                     description: "Starts the workspace and answers once it is running, or with why it isn't.",
                     inputSchema: id),
                Tool(name: "workspace_stop", title: "Stop a workspace",
                     description: "Stops the workspace and answers once it is stopped, or with why it isn't.",
                     inputSchema: id),
            ],
            callTool: { tool, arguments in
                let args = try tool.inputSchema.check(arguments)
                do {
                    switch tool.name {
                    case "workspaces_list":
                        let all = try await provider.list()
                        return ToolResult.structured(["contract": .int(contract), "workspaces": .array(all.map(\.json))])
                    case "workspace_start":
                        return ToolResult.structured(["workspace": try await provider.act(.start, args["id"]?.string ?? "").json])
                    default:
                        return ToolResult.structured(["workspace": try await provider.act(.stop, args["id"]?.string ?? "").json])
                    }
                } catch let failure as Failure {
                    return ToolResult.error(failure.reason)
                }
            })
    }

    /// A failure in words for the person who pressed Start.
    struct Failure: Error {
        var reason: String
    }
}

/// One workspace as a list found it.
struct Workspace: Sendable {
    var id: String
    var name: String
    var state: WorkspaceState
    /// What its templates are filled in with: `id`, `name`, and a listing's columns or fields.
    var values: [String: String]
    var commands: CommandConfig.Commands

    var ssh: String? {
        commands.ssh.map { Template.fill($0, values, quoted: false) }.flatMap { $0.contains("${") ? nil : $0 }
    }

    var json: JSON {
        var o: [String: JSON] = ["id": .string(id), "name": .string(name), "state": .string(state.rawValue),
                                 "tunnel": .bool(commands.tunnel)]
        if let ssh { o["ssh"] = .string(ssh) }
        if let cost = commands.cost { o["cost"] = .string(Template.fill(cost, values, quoted: false)) }
        return .object(o)
    }
}

/// The provider's state: only what a start or stop left, for workspaces nothing else can ask.
actor Provider {
    enum Action: String {
        case start, stop
        var target: WorkspaceState { self == .start ? .running : .stopped }
    }

    let config: CommandConfig
    let timing: WorkspaceCommands.Timing
    let run: WorkspaceCommands.Runner
    private var left: [String: WorkspaceState] = [:]

    init(config: CommandConfig, timing: WorkspaceCommands.Timing, run: @escaping WorkspaceCommands.Runner) {
        self.config = config
        self.timing = timing
        self.run = run
    }

    // MARK: Listing

    func list() async throws -> [Workspace] {
        if let listing = config.listing { return try await listed(listing) }
        let entries = config.workspaces.prefix(WorkspaceCommands.listLimit)
        return await withTaskGroup(of: (Int, Workspace).self) { group in
            for (n, entry) in entries.enumerated() {
                group.addTask { (n, await self.written(entry)) }
            }
            var found: [(Int, Workspace)] = []
            for await one in group { found.append(one) }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// A workspace written out, with its state from its status command if it has one.
    private func written(_ entry: CommandConfig.Entry) async -> Workspace {
        let values = ["id": entry.id, "name": entry.name]
        var state = left[entry.id] ?? .unknown
        if let status = entry.commands.status {
            let outcome = await run(Template.fill(status, values, quoted: true), timing.quick)
            state = outcome.status == 0 ? config.state(for: outcome.text) : .unknown
        }
        return Workspace(id: entry.id, name: entry.name, state: state, values: values, commands: entry.commands)
    }

    private func listed(_ listing: CommandConfig.Listing) async throws -> [Workspace] {
        let outcome = await run(listing.command, timing.quick)
        guard outcome.status == 0, !outcome.timedOut else {
            throw WorkspaceCommands.Failure(reason: Self.reason(outcome, line: listing.command, doing: "listing workspaces",
                                                                deadline: timing.quick))
        }
        var rows: [[String: String]] = []
        switch listing.shape {
        case .columns(let columns):
            for line in outcome.text.split(whereSeparator: \.isNewline) {
                let fields = line.split(maxSplits: columns.count - 1, whereSeparator: \.isWhitespace).map(String.init)
                guard !fields.isEmpty else { continue }
                var row: [String: String] = [:]
                for (column, value) in zip(columns, fields) where !value.isEmpty {
                    row[column] = value.trimmingCharacters(in: .whitespaces)
                }
                rows.append(row)
            }
        case .json(let items, let fields):
            guard let json = try? JSON.parse(outcome.output),
                  let array = JSONPath.value(items, in: json)?.array else {
                throw WorkspaceCommands.Failure(reason: "The list command's output isn't a JSON array at \(items.isEmpty ? "its top" : items).")
            }
            for item in array {
                var row: [String: String] = [:]
                for (key, path) in fields {
                    if let text = JSONPath.text(path, in: item), !text.isEmpty { row[key] = text }
                }
                rows.append(row)
            }
        }
        return rows.prefix(WorkspaceCommands.listLimit).compactMap { row in
            guard let id = row["id"] else { return nil }
            var values = row
            values["name"] = row["name"] ?? id
            let said = row["state"].map(config.state(for:))
            return Workspace(id: id, name: values["name"]!, state: said ?? left[id] ?? .unknown,
                             values: values, commands: listing.commands)
        }
    }

    private func find(_ id: String) async throws -> Workspace {
        if config.listing == nil, let entry = config.workspaces.first(where: { $0.id == id }) {
            return await written(entry)
        }
        guard let found = try await list().first(where: { $0.id == id }) else {
            throw WorkspaceCommands.Failure(reason: "There is no workspace \(id).")
        }
        return found
    }

    /// Whether anything but our own memory can say how the workspace stands.
    private func canAsk(_ workspace: Workspace) -> Bool {
        config.listing != nil || workspace.commands.status != nil
    }

    // MARK: Start and stop

    func act(_ action: Action, _ id: String) async throws -> Workspace {
        let began = ContinuousClock.now
        var workspace = try await find(id)
        if workspace.state == action.target { return workspace }
        let template = action == .start ? workspace.commands.start : workspace.commands.stop
        log("workspace-commands: \(action.rawValue) \(workspace.name): \(template)")
        let outcome = await run(Template.fill(template, workspace.values, quoted: true), timing.long)
        guard outcome.status == 0, !outcome.timedOut else {
            throw WorkspaceCommands.Failure(reason: Self.reason(outcome, line: template,
                                                                doing: "\(action.rawValue)ing \(workspace.name)",
                                                                deadline: timing.long))
        }
        guard canAsk(workspace) else {
            left[id] = action.target
            workspace.state = action.target
            return workspace
        }
        while ContinuousClock.now - began < timing.long {
            workspace = try await find(id)
            if workspace.state == action.target { return workspace }
            try? await Task.sleep(for: timing.pollEvery)
        }
        throw WorkspaceCommands.Failure(
            reason: "\(workspace.name) was still \(workspace.state.rawValue) after \(Self.words(timing.long)).")
    }

    // MARK: Words

    /// Why a command failed: its own last lines, or that its CLI isn't there.
    static func reason(_ outcome: ChildProcess.Outcome, line: String, doing: String, deadline: Duration) -> String {
        if outcome.timedOut { return "\(doing.prefix(1).uppercased() + doing.dropFirst()) took longer than \(words(deadline))." }
        if let failure = outcome.failure { return failure }
        if outcome.status == 127 {
            let cli = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? line
            return "\(cli) isn't installed where the control plane runs."
        }
        let said = outcome.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? outcome.text : outcome.errorText
        let lines = said.split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n")
        let text = lines.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "\(line.split(separator: " ").first ?? "") exited with \(outcome.status)." }
        return String(text.utf8.count > 1024 ? String(decoding: text.utf8.suffix(1024), as: UTF8.self) : text)
    }

    static func words(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds >= 60 ? "\((seconds + 30) / 60) minutes" : "\(seconds) seconds"
    }
}
