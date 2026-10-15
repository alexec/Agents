import AgentsKitCore
import Foundation

/// Write It for Me (#858, plan.md): each draft of a provider's tool map or commands, held in
/// memory while an agent on this control plane's own host writes it.
///
/// The control plane does everything that touches the server, the CLI or a secret: it reads
/// the tools or the help, runs each check, and asks the person before a start, a stop or a
/// check that may change something. The agent sees each answer with every secret's value
/// replaced by its name (FR-022), and nothing is kept until the person presses Add.
public actor ProviderDrafts {
    public struct Timing: Sendable {
        /// How long a draft has, less the time spent asking and proving (FR-017).
        public var total: Duration
        /// How long a question waits for the person before it is a no (FR-019).
        public var answer: Duration
        /// How long the agent has, once the time is over, to send its best draft.
        public var lastWord: Duration
        /// How long a draft lives once its sheet has gone (R9).
        public var ownerGone: Duration
        /// How long an ended draft is kept, for Add to mark the record `writtenBy`.
        public var keptAfter: Duration
        /// How often the clock and the owner are looked at.
        public var tick: Duration
        public var help: Duration

        public static let standard = Timing(total: .seconds(300), answer: .seconds(120), lastWord: .seconds(60),
                                            ownerGone: .seconds(30), keptAfter: .seconds(600), tick: .seconds(1),
                                            help: .seconds(25))

        public init(total: Duration, answer: Duration, lastWord: Duration, ownerGone: Duration, keptAfter: Duration,
                    tick: Duration, help: Duration) {
            self.total = total
            self.answer = answer
            self.lastWord = lastWord
            self.ownerGone = ownerGone
            self.keptAfter = keptAfter
            self.tick = tick
            self.help = help
        }
    }

    /// What a CLI's help printed.
    public struct Help: Sendable {
        public var status: Int32
        public var text: String
        public init(status: Int32, text: String) {
            self.status = status
            self.text = text
        }

        /// The shell's word for a command it can't find.
        public var notInstalled: Bool { status == 127 }
    }

    /// The host on this control plane's machine, which runs the agent (research R1).
    public struct LocalHost: Sendable, Equatable {
        public var id: HostID
        public var name: String
        public init(id: HostID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// What the executable does for it.
    public struct Hooks: Sendable {
        /// A connection to a provider as a record says, with its secrets.
        public var connect: @Sendable (ProviderRecord, [String: String]) throws -> any WorkspaceProvider
        /// `‹cli› ‹words…› --help`, where the control plane runs, with the secrets as environment.
        public var help: @Sendable (_ cli: String, _ words: [String], _ secrets: [String: String]) async -> Help
        /// The host on this machine, online; nil when there is none.
        public var localHost: @Sendable () async -> LocalHost?
        /// Starts the writing agent on `host`, as the sheet's client: its id.
        public var startAgent: @Sendable (_ host: HostID, _ request: DaemonAPI.StartRequest,
                                          _ owner: ControlRouter.Caller) async throws -> UUID
        /// Stops it.
        public var stopAgent: @Sendable (_ host: HostID, _ agent: UUID, _ owner: ControlRouter.Caller) async -> Void
        /// Tells the sheet; false when its session has gone.
        public var notify: @Sendable (_ owner: ControlRouter.Caller, _ update: DaemonAPI.ProviderDraftUpdate) async -> Bool
        /// Whether the sheet's session is still here.
        public var ownerHere: @Sendable (_ owner: ControlRouter.Caller) async -> Bool
        /// The host with agents working that a provider's workspace runs, by its name (FR-020).
        public var busyHost: @Sendable (_ provider: ProviderID?, _ workspace: String) async -> String?
        /// `ssh -G ‹destination›` where the control plane runs: the config ssh would use, without
        /// connecting (#975). Nil when ssh couldn't say.
        public var sshConfig: @Sendable (_ destination: String) async -> Help?

        public init(connect: @escaping @Sendable (ProviderRecord, [String: String]) throws -> any WorkspaceProvider,
                    help: @escaping @Sendable (String, [String], [String: String]) async -> Help,
                    localHost: @escaping @Sendable () async -> LocalHost?,
                    startAgent: @escaping @Sendable (HostID, DaemonAPI.StartRequest, ControlRouter.Caller) async throws -> UUID,
                    stopAgent: @escaping @Sendable (HostID, UUID, ControlRouter.Caller) async -> Void,
                    notify: @escaping @Sendable (ControlRouter.Caller, DaemonAPI.ProviderDraftUpdate) async -> Bool,
                    ownerHere: @escaping @Sendable (ControlRouter.Caller) async -> Bool,
                    busyHost: @escaping @Sendable (ProviderID?, String) async -> String? = { _, _ in nil },
                    sshConfig: @escaping @Sendable (String) async -> Help? = { _ in nil }) {
            self.connect = connect
            self.help = help
            self.localHost = localHost
            self.startAgent = startAgent
            self.stopAgent = stopAgent
            self.notify = notify
            self.ownerHere = ownerHere
            self.busyHost = busyHost
            self.sshConfig = sshConfig
        }
    }

    /// At most this many checks, tool calls and steps (FR-017).
    public static let maxChecks = 8
    public static let maxCalls = 40
    static let maxSteps = 100
    /// What the agent is given of one output (FR-015).
    static let cut = 16 * 1024

    /// The answer every tool gives once the draft's time is over.
    public static let overWords = "The time for this draft is over: send your best draft with send_draft, or give_up."
    public static let notYoursWords = "This tool is for the agent writing that provider's map."

    /// The CLIs Agents has a preset for, and the preset's name (US2 AS6).
    static let presets: [String: (preset: String, kind: String)] = [
        "docker": ("docker", "Docker"), "doctl": ("doctl", "DigitalOcean"), "gh": ("codespaces", "Codespaces"),
        "coder": ("coder", "Coder"), "gcloud": ("gcloud-workstations", "Workstations"),
    ]

    final class Draft {
        let id: UUID
        let owner: ControlRouter.Caller
        let form: DaemonAPI.ProviderAdd
        let secrets: [String: String]
        let provider: ProviderID?
        let runtimeID: String
        let runtimeName: String
        let redact: DraftRedaction
        var host: HostID?
        var agent: UUID?
        var state = "reading"
        var steps: [DaemonAPI.DraftStep] = []
        /// The last draft sent, the result.
        var sent: JSONValue?
        /// The last draft that passed its check.
        var passed: JSONValue?
        var check: DaemonAPI.DraftCheck?
        var question: DaemonAPI.DraftQuestion?
        var waiter: CheckedContinuation<Bool, Never>?
        var note: String?
        var checks = 0
        var calls = 0
        /// Time used, less asking and proving.
        var used: Duration = .zero
        var paused = false
        var over = false
        var overSince: ContinuousClock.Instant?
        var ownerGoneSince: ContinuousClock.Instant?
        var ended = false
        var tools: [JSONValue] = []
        var helpSeen = ""
        var workspaces: [DaemonAPI.WorkspaceInfo] = []
        var ticker: Task<Void, Never>?

        init(id: UUID, owner: ControlRouter.Caller, form: DaemonAPI.ProviderAdd, secrets: [String: String],
             provider: ProviderID?, runtimeID: String, runtimeName: String) {
            self.id = id
            self.owner = owner
            self.form = form
            self.secrets = secrets
            self.provider = provider
            self.runtimeID = runtimeID
            self.runtimeName = runtimeName
            redact = DraftRedaction(secrets)
        }

        var isCommands: Bool { form.kind == .commands }
        var cli: String { (form.cli ?? "").trimmingCharacters(in: .whitespaces) }
        /// The result as it stands: the last sent, or the last that passed.
        var best: JSONValue? { sent ?? passed }
    }

    private let timing: Timing
    private let hooks: Hooks
    private let log: @Sendable (String) -> Void
    /// The clock the time limits read; a test gives its own, to say when time passes (#891).
    private let now: @Sendable () -> ContinuousClock.Instant
    private var drafts: [UUID: Draft] = [:]

    public init(timing: Timing = .standard, hooks: Hooks, log: @escaping @Sendable (String) -> Void,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.timing = timing
        self.hooks = hooks
        self.log = log
        self.now = now
    }

    // MARK: The sheet's methods

    /// The runtimes that can write here (`providers/runtimes`).
    public func runtimes() async -> DaemonAPI.ProviderRuntimes {
        guard let host = await hooks.localHost() else {
            return .init(runtimes: [], why: "No host runs where the control plane runs, so no agent can write here.")
        }
        let runtimes = ToolPolicyCatalog.writerRuntimes.enumerated().map { index, id in
            DaemonAPI.ProviderRuntimes.Runtime(id: id, name: RuntimeCatalog.runtime(id: id)?.name ?? id, isDefault: index == 0)
        }
        return .init(runtimes: runtimes, host: host.name,
                     why: runtimes.isEmpty ? "No runtime here can write with its own tools turned off." : nil)
    }

    /// `providers/draftStart`: the cheap answers first (R8), then the agent.
    /// `existing` is the provider's record and secrets in Edit… (US4).
    public func start(_ request: DaemonAPI.ProviderDraftStart, from owner: ControlRouter.Caller,
                      existing: (record: ProviderRecord, secrets: [String: String], problem: String?)? = nil)
        async throws -> DaemonAPI.ProviderDraftStarted {
        let given = (request.secrets ?? [:]).filter { !$0.value.isEmpty }
        let secrets = (existing?.secrets ?? [:]).merging(given) { $1 }
        guard ToolPolicyCatalog.writerMeta(for: request.runtimeID) != nil else {
            let name = RuntimeCatalog.runtime(id: request.runtimeID)?.name ?? request.runtimeID
            throw Self.refusal("\(name) can’t write here: its own tools can’t be turned off for one session.")
        }
        let id = UUID()
        let draft = Draft(id: id, owner: owner, form: request.form, secrets: secrets, provider: request.provider,
                          runtimeID: request.runtimeID,
                          runtimeName: RuntimeCatalog.runtime(id: request.runtimeID)?.name ?? request.runtimeID)
        // What it starts from: the tools, or the CLI's own help.
        var seed: String
        if draft.isCommands {
            let cli = draft.cli
            guard cli.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil else {
                throw Self.refusal(cli.isEmpty ? "Give the CLI its commands use." : "“\(cli)” isn’t a program’s name.")
            }
            let program = (cli as NSString).lastPathComponent
            if let preset = Self.presets[program] {
                return .init(draft: id, answered: .init(note: "Agents has a preset for \(program): use \(preset.kind).",
                                                         preset: preset.preset))
            }
            let help = await hooks.help(cli, [], secrets)
            if help.notInstalled { throw Self.refusal("\(cli) isn’t installed where the control plane runs.") }
            draft.helpSeen = help.text
            seed = draft.redact(Self.cut(help.text))
            draft.steps.append(.init(kind: .help, text: "ran \(cli) --help"))
        } else {
            let tools: [JSONValue]
            do {
                let connection = try hooks.connect(Self.record(draft, map: nil), secrets)
                defer { Task { await connection.end() } }
                tools = try await connection.tools()
            } catch {
                throw Self.refusal(draft.redact(Self.words(error)))
            }
            let names = Set(tools.compactMap { $0["name"]?.stringValue })
            if ToolMapping.required.allSatisfy(names.contains) {
                return .init(draft: id, answered: .init(note: "It follows the contract: it needs no map."))
            }
            if let shipped = try? ToolMapping.map(ShippedToolMaps.digitalOcean),
               shipped.missing(from: Array(names)) == nil {
                return .init(draft: id, answered: .init(note: "Agents ships this map.", map: ShippedToolMaps.digitalOcean))
            }
            draft.tools = tools
            seed = Self.toolsText(tools, redact: draft.redact)
            draft.steps.append(.init(kind: .read, text: "read \(tools.count) tool\(tools.count == 1 ? "" : "s")"))
        }
        guard let host = await hooks.localHost() else {
            throw Self.refusal("No host runs where the control plane runs, so no agent can write here.")
        }
        draft.host = host.id
        drafts[id] = draft
        let prompt = Self.prompt(draft, seed: seed, existing: existing.map { (Self.oldDraft($0.record), $0.problem) })
        let start = DaemonAPI.StartRequest(runtimeID: request.runtimeID, cwd: URL(fileURLWithPath: "/"), prompt: prompt,
                                           requestID: UUID(), sandbox: .on, purpose: .providerDraft(id: id))
        do {
            draft.agent = try await hooks.startAgent(host.id, start, owner)
        } catch {
            drafts[id] = nil
            throw Self.refusal(draft.redact(Self.words(error)))
        }
        draft.state = "writing"
        log("provider draft \(id.uuidString.prefix(8).lowercased()): \(draft.runtimeName) writing \(draft.isCommands ? "commands for \(draft.cli)" : "a tool map") on \(host.name)")
        draft.ticker = Task { [weak self] in await self?.watch(id) }
        await tell(draft)
        return .init(draft: id)
    }

    /// `providers/draftCancel`: × , Back and Cancel.
    public func cancel(_ id: UUID, from owner: ControlRouter.Caller) async {
        guard let draft = drafts[id], draft.owner.client == owner.client else { return }
        await end(draft, state: "cancelled", note: nil)
    }

    /// `providers/draftAnswer`.
    public func answer(_ answer: DaemonAPI.ProviderDraftAnswer, from owner: ControlRouter.Caller) throws {
        guard let draft = drafts[answer.draft], draft.owner.client == owner.client else {
            throw Self.refusal("That draft has ended.")
        }
        guard draft.question?.id == answer.question, let waiter = draft.waiter else {
            throw Self.refusal("That question was answered already.")
        }
        draft.waiter = nil
        waiter.resume(returning: answer.yes)
    }

    /// The result of a done draft, for `providers/add` to mark its record (`writtenBy`).
    public func result(_ id: UUID) -> (runtimeID: String, json: JSONValue)? {
        guard let draft = drafts[id], draft.state == "done", let best = draft.best else { return nil }
        return (draft.runtimeID, best)
    }

    // MARK: The writer's tools

    /// A writer's tool, from its host (`host/providerDraft`).
    public func call(from host: HostID, _ call: DaemonAPI.HostProviderDraftCall) async throws -> JSONValue {
        guard let draft = drafts[call.draft], draft.agent == call.agentID, draft.host == host else {
            throw JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: Self.notYoursWords)
        }
        if call.tool == "turn_ended" {
            await turnEnded(draft, reason: call.arguments?["reason"]?.stringValue)
            return [:]
        }
        let note = await tool(draft, call.tool, call.arguments ?? [:])
        return ["note": .string(draft.redact(note))]
    }

    private func tool(_ draft: Draft, _ name: String, _ arguments: JSONValue) async -> String {
        guard !draft.ended else { return "This draft has ended." }
        draft.calls += 1
        let final = name == AppTool.sendDraft || name == AppTool.giveUp
        if draft.calls > Self.maxCalls || (name == AppTool.checkDraft && draft.checks >= Self.maxChecks) { markOver(draft) }
        if draft.over, !final { return Self.overWords }
        switch name {
        case AppTool.readTools:
            guard !draft.isCommands else { return "This draft is for a CLI: use read_help." }
            return Self.toolsText(draft.tools, redact: draft.redact)
        case AppTool.readHelp:
            return await readHelp(draft, arguments)
        case AppTool.checkDraft:
            return await check(draft, arguments["draft"])
        case AppTool.proveStart, AppTool.proveStop:
            return await prove(draft, start: name == AppTool.proveStart, arguments)
        case AppTool.sendDraft:
            guard let given = arguments["draft"], case .object = given else { return "Send the draft as a JSON object in `draft`." }
            if let problem = Self.problem(given, commands: draft.isCommands) { return "Not sent: \(problem)" }
            draft.sent = given
            let note = arguments["note"]?.stringValue.map { Self.lines($0, 3) }
            await end(draft, state: "done", note: note.map { draft.redact($0) })
            return "Sent. End your turn now."
        case AppTool.giveUp:
            let reason = arguments["reason"]?.stringValue.map { Self.lines($0, 3) } ?? "It gave up."
            await end(draft, state: "failed", note: draft.redact(reason))
            return "Ended."
        default:
            return "No tool called \(name)."
        }
    }

    private func readHelp(_ draft: Draft, _ arguments: JSONValue) async -> String {
        guard draft.isCommands else { return "This draft is for an MCP server: use read_tools." }
        let words = arguments["words"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let refused = DraftSafety.helpWords(words, seen: draft.helpSeen) { return "Not run: \(refused)" }
        let help = await hooks.help(draft.cli, words, draft.secrets)
        draft.helpSeen += "\n" + help.text
        await step(draft, .help, "ran \(([draft.cli] + words).joined(separator: " ")) --help")
        return Self.cut(help.text.isEmpty ? "(It printed nothing, and exited \(help.status).)" : help.text)
    }

    private func check(_ draft: Draft, _ given: JSONValue?) async -> String {
        guard let given, case .object = given else { return "Give the draft as a JSON object in `draft`." }
        if let problem = Self.problem(given, commands: draft.isCommands) { return "Failed: \(problem)" }
        let verdict = draft.isCommands ? DraftSafety.commands(given, cli: draft.cli)
            : DraftSafety.listTool(given, tools: draft.tools)
        if case .ask(let reason) = verdict {
            let what = draft.isCommands ? "its list" : "\(given["list"]?["tool"]?.stringValue ?? "its list tool")"
            let yes = await ask(draft, .init(kind: .check,
                                             text: "\(draft.runtimeName) wants to run \(what) to check the \(draft.isCommands ? "commands" : "map"). It isn’t on the safe list because \(reason).",
                                             yes: "Run Check"))
            guard yes else {
                await step(draft, .ask, "check not run: the person said no")
                return "The person said no to this check (\(reason)). Write a list that is plainly a list, or send the draft unchecked with a note."
            }
        }
        draft.checks += 1
        draft.state = "checking"
        await tell(draft)
        let result: Result<ProviderConnection.Checked, Error>
        do {
            let connection = try hooks.connect(Self.record(draft, map: given), draft.secrets)
            result = await Self.attempt { try await connection.check() }
            await connection.end()
        } catch {
            result = .failure(error)
        }
        draft.state = "writing"
        switch result {
        case .success(let checked):
            draft.passed = given
            draft.workspaces = checked.workspaces
            draft.check = .init(passed: true, workspaces: checked.workspaces)
            await step(draft, .check, "checked: listed \(checked.workspaces.count)")
            var answer = "Passed: listed \(checked.workspaces.count).\n" + checked.workspaces.map(Self.line).joined(separator: "\n")
            if let items = checked.items, items > checked.workspaces.count, let first = checked.firstItem {
                answer += "\n\(items - checked.workspaces.count) of the \(items) items at list.items have no id or name by this map. The first item:\n"
                    + draft.redact(Self.sample(first))
            }
            // ssh, which Add as Host… and an ssh start need (#975): tested, or said to be missing.
            var resolved: String?
            let noSSH = checked.workspaces.isEmpty ? !Self.hasSSH(given, commands: draft.isCommands)
                : checked.workspaces.allSatisfy { $0.ssh == nil }
            if let workspace = checked.workspaces.first(where: { $0.ssh != nil }), let destination = workspace.ssh {
                let words = Self.resolved(destination, await hooks.sshConfig(WorkspaceProviders.sshDestination(destination)))
                resolved = draft.redact(words)
                await step(draft, .check, words)
                answer += "\n" + words
            } else if noSSH {
                await step(draft, .check, "no ssh destination")
                answer += "\nNo workspace has an ssh destination, so none can be added as a host. " + Self.sshHunt
                if checked.items == nil || checked.items == checked.workspaces.count, let first = checked.firstItem {
                    answer += " The first item:\n" + draft.redact(Self.sample(first))
                }
            }
            draft.check = .init(passed: true, workspaces: checked.workspaces, ssh: resolved, noSSH: noSSH ? true : nil)
            await tell(draft)
            return answer
        case .failure(let error):
            let words = draft.redact(Self.words(error))
            draft.check = .init(passed: false, problem: words)
            await step(draft, .check, "check failed: \(words)")
            return "Failed: \(words)"
        }
    }

    private func prove(_ draft: Draft, start: Bool, _ arguments: JSONValue) async -> String {
        guard let given = arguments["draft"], case .object = given else { return "Give the draft as a JSON object in `draft`." }
        if let problem = Self.problem(given, commands: draft.isCommands) { return "Not asked: \(problem)" }
        let named = arguments["workspace"]?.stringValue ?? ""
        guard let workspace = draft.workspaces.first(where: { $0.id == named })
                ?? draft.workspaces.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame }) else {
            return "Not asked: \(named.isEmpty ? "say which workspace" : "\(named) isn’t in the last list"). check_draft lists them."
        }
        if !start, let busy = await hooks.busyHost(draft.provider, workspace.id) {
            return "Not asked: agents are working on \(busy)."
        }
        let provider = draft.form.name.isEmpty ? "the provider" : draft.form.name
        var text = "\(draft.runtimeName) wants to \(start ? "start" : "stop") \(workspace.name) on \(provider) to prove the \(draft.isCommands ? "commands" : "map")."
        if start, let cost = workspace.cost { text += " \(cost) while running." }
        if start { text += " It stays running until you stop it." }
        let yes = await ask(draft, .init(kind: start ? .start : .stop, workspace: workspace.name, cost: workspace.cost,
                                         text: text, yes: start ? "Start It" : "Stop It"))
        guard yes else {
            await step(draft, .ask, "asked to \(start ? "start" : "stop") \(workspace.name): no")
            return "The person said no."
        }
        draft.state = "proving"
        draft.paused = true
        await tell(draft)
        let result: Result<DaemonAPI.WorkspaceInfo?, Error>
        do {
            let connection = try hooks.connect(Self.record(draft, map: given), draft.secrets)
            result = await Self.attempt { start ? try await connection.start(workspace.id) : try await connection.stop(workspace.id) }
            await connection.end()
        } catch {
            result = .failure(error)
        }
        draft.paused = false
        draft.state = "writing"
        let verb = start ? "Started" : "Stopped"
        switch result {
        case .success(let after):
            await step(draft, .prove, "\(verb.lowercased()) \(workspace.name)")
            return "\(verb) \(workspace.name)\(after.map { ": \($0.state)" } ?? ". check_draft lists its state now.")"
        case .failure(let error):
            let words = draft.redact(Self.words(error))
            await step(draft, .prove, "couldn’t \(start ? "start" : "stop") \(workspace.name): \(words)")
            return "Failed: \(words)"
        }
    }

    /// Asks the person in the sheet, and waits; no answer in time is a no. The draft's clock
    /// stops while it waits.
    private func ask(_ draft: Draft, _ question: DaemonAPI.DraftQuestion) async -> Bool {
        draft.question = question
        draft.state = "asking"
        draft.paused = true
        await step(draft, .ask, question.text)
        let wait = timing.answer
        let id = draft.id
        let timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.unanswered(id, question.id)
        }
        let yes = await withCheckedContinuation { draft.waiter = $0 }
        timer.cancel()
        draft.question = nil
        draft.paused = false
        if !draft.ended { draft.state = "writing" }
        await tell(draft)
        return yes && !draft.ended
    }

    private func unanswered(_ id: UUID, _ question: UUID) {
        guard let draft = drafts[id], draft.question?.id == question, let waiter = draft.waiter else { return }
        draft.waiter = nil
        waiter.resume(returning: false)
    }

    // MARK: Its life

    /// Once a tick: the clock, and whether the sheet is still there.
    private func watch(_ id: UUID) async {
        var last = now()
        while !Task.isCancelled, let draft = drafts[id], !draft.ended {
            try? await Task.sleep(for: timing.tick)
            let now = self.now()
            if !draft.paused { draft.used += now - last }
            last = now
            if draft.used >= timing.total { markOver(draft) }
            if let since = draft.overSince, now - since >= timing.lastWord {
                if draft.best != nil {
                    await end(draft, state: "done", note: "It ran out of time; this is its last draft.")
                } else {
                    await end(draft, state: "failed", note: "Couldn’t write \(draft.isCommands ? "the commands" : "a map") in \(Self.minutes(timing.total)).")
                }
                return
            }
            if await hooks.ownerHere(draft.owner) {
                draft.ownerGoneSince = nil
            } else if let since = draft.ownerGoneSince {
                if now - since >= timing.ownerGone { await end(draft, state: "cancelled", note: nil) }
            } else {
                draft.ownerGoneSince = now
            }
        }
    }

    private func markOver(_ draft: Draft) {
        guard !draft.over else { return }
        draft.over = true
        draft.overSince = now()
    }

    private func turnEnded(_ draft: Draft, reason: String?) async {
        guard !draft.ended else { return }
        if draft.best != nil {
            await end(draft, state: "done", note: draft.note)
        } else {
            await end(draft, state: "failed",
                      note: "It ended without sending \(draft.isCommands ? "commands" : "a map")\(reason.map { ": \($0)" } ?? ".")")
        }
    }

    /// Ends a draft: the agent stops, the sheet is told, and it is dropped a while later.
    private func end(_ draft: Draft, state: String, note: String?) async {
        guard !draft.ended else { return }
        draft.ended = true
        draft.state = state
        draft.note = note
        draft.question = nil
        draft.ticker?.cancel()
        if let waiter = draft.waiter {
            draft.waiter = nil
            waiter.resume(returning: false)
        }
        await tell(draft)
        log("provider draft \(draft.id.uuidString.prefix(8).lowercased()): \(state)\(note.map { ": \(draft.redact($0))" } ?? "") after \(draft.checks) check\(draft.checks == 1 ? "" : "s")")
        if let host = draft.host, let agent = draft.agent {
            let owner = draft.owner
            Task { await self.hooks.stopAgent(host, agent, owner) }
        }
        let id = draft.id, keep = timing.keptAfter
        Task { [weak self] in
            try? await Task.sleep(for: keep)
            await self?.drop(id)
        }
    }

    private func drop(_ id: UUID) { drafts[id] = nil }

    private func step(_ draft: Draft, _ kind: DaemonAPI.DraftStep.Kind, _ text: String) async {
        draft.steps.append(.init(kind: kind, text: draft.redact(text)))
        if draft.steps.count > Self.maxSteps { draft.steps.removeFirst(draft.steps.count - Self.maxSteps) }
        await tell(draft)
    }

    /// Tells the sheet where the draft stands, redacted whole: a workspace's name or a
    /// server's words can hold a secret as well as the agent's draft can.
    private func tell(_ draft: Draft) async {
        var update = DaemonAPI.ProviderDraftUpdate(
            draft: draft.id, state: draft.state, runtimeName: draft.runtimeName, steps: draft.steps,
            draftJSON: draft.state == "done" ? draft.best : draft.passed,
            check: draft.check, question: draft.question, note: draft.note)
        if !draft.redact.isEmpty {
            if let json = try? JSONValue.encoding(update),
               let redacted = try? draft.redact(json).decode(DaemonAPI.ProviderDraftUpdate.self) {
                update = redacted
            } else {
                // A secret that is also one of the update's own words: what can't be read
                // back redacted isn't sent.
                update.check = update.check.map { .init(passed: $0.passed) }
                update.draftJSON = nil
                if let text = update.question?.text { update.question?.text = draft.redact(text) }
                update.note = update.note.map { draft.redact($0) }
            }
        }
        _ = await hooks.notify(draft.owner, update)
    }

    // MARK: Helpers

    /// `‹cli› ‹words…› --help` where the control plane runs, as the command provider runs its
    /// commands: in its home, with the secrets as environment, cut off after 25 seconds.
    public static func runHelp(_ cli: String, _ words: [String], secrets: [String: String], in folder: URL,
                               deadline: Duration = .seconds(25)) async -> Help {
        let environment = ProcessInfo.processInfo.environment.merging(secrets) { $1 }
        let outcome = await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/env"), [cli] + words + ["--help"],
                                             environment: environment, in: folder, deadline: deadline,
                                             outputLimit: 256 * 1024)
        var text = outcome.text
        if !outcome.errorText.isEmpty { text += (text.isEmpty ? "" : "\n") + outcome.errorText }
        if outcome.timedOut { text += "\n[It didn’t finish in \(minutes(deadline)).]" }
        return Help(status: outcome.status, text: text)
    }

    /// `ssh -G ‹destination›` where the control plane runs: what ssh's config makes of it, without
    /// connecting (#975).
    public static func runSSHConfig(_ destination: String, in folder: URL) async -> Help {
        let outcome = await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/ssh"), ["-G", "--", destination], in: folder,
                                             deadline: .seconds(10), outputLimit: 64 * 1024)
        return Help(status: outcome.status, text: outcome.status == 0 ? outcome.text : outcome.errorText)
    }

    /// A record for the draft's form, with `map` as its tool map or commands.
    static func record(_ draft: Draft, map: JSONValue?) -> ProviderRecord {
        let form = draft.form
        return ProviderRecord(id: draft.provider ?? ProviderID(rawValue: "draft-\(draft.id.uuidString.prefix(8).lowercased())"),
                              name: form.name.isEmpty ? "draft" : form.name, kind: form.kind, command: form.command,
                              args: form.args, url: form.url, headers: form.headers,
                              commands: form.kind == .commands ? map : nil, secretNames: draft.secrets.keys.sorted(),
                              map: form.kind == .commands ? nil : map)
    }

    /// What is wrong with a draft's shape, as Add would say it; nil when it parses.
    static func problem(_ draft: JSONValue, commands: Bool) -> String? {
        if commands {
            guard draft["preset"] != nil || draft["list"]?.stringValue != nil || draft["workspaces"]?.arrayValue != nil else {
                return "a config has `list` (with `columns` or `json`), or `workspaces`."
            }
            if draft["list"] != nil, draft["columns"] == nil, draft["json"] == nil {
                return "a config with `list` needs `columns` or `json`."
            }
            return nil
        }
        do {
            _ = try ToolMapping.map(draft)
            return nil
        } catch {
            return words(error)
        }
    }

    /// The map or commands a provider has, to write again from (US4).
    static func oldDraft(_ record: ProviderRecord) -> JSONValue? {
        record.kind == .commands ? record.commands : record.map
    }

    static func toolsText(_ tools: [JSONValue], redact: DraftRedaction) -> String {
        let kept: [JSONValue] = tools.map { tool in
            var object: [String: JSONValue] = [:]
            for key in ["name", "description", "inputSchema", "annotations"] { if let value = tool[key] { object[key] = value } }
            return .object(object)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(JSONValue.array(kept))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return cut(redact(text))
    }

    /// One item of a list, as JSON, at most 2 KB: what a check shows of what a map missed.
    static func sample(_ item: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(item)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        guard text.utf8.count > 2048 else { return text }
        return String(decoding: Array(text.utf8.prefix(2048)), as: UTF8.self) + " [cut at 2 KB]"
    }

    static func line(_ workspace: DaemonAPI.WorkspaceInfo) -> String {
        var parts = ["\(workspace.name) (id \(workspace.id)): \(workspace.state)"]
        if let ssh = workspace.ssh { parts.append("ssh \(ssh)") }
        if let cost = workspace.cost { parts.append(cost) }
        return "- " + parts.joined(separator: ", ")
    }

    /// Whether a draft names an ssh destination: `list.ssh` in a map, `ssh` in a config or in
    /// any of its workspaces, or a preset's (#975).
    static func hasSSH(_ draft: JSONValue, commands: Bool) -> Bool {
        func given(_ value: JSONValue?) -> Bool { !(value?.stringValue ?? "").isEmpty }
        guard commands else { return given(draft["list"]?["ssh"]) }
        return draft["preset"] != nil || given(draft["ssh"])
            || (draft["workspaces"]?.arrayValue ?? []).contains { given($0["ssh"]) }
    }

    /// What `ssh -G` resolved a destination to, in one line for the agent and the checks (#975):
    /// "ssh -G coder@cws.devstack-1: hostname cws.devstack-1, user coder, port 22, ProxyCommand ssh -W %h:%p bastion".
    static func resolved(_ destination: String, _ output: Help?) -> String {
        guard let output, output.status == 0 else {
            let why = output.map { lines($0.text, 2) } ?? ""
            return "ssh -G \(destination) failed\(why.isEmpty ? "" : ": \(why)"). Check the destination."
        }
        var config: [String: String] = [:]
        for line in output.text.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { continue }
            let key = words[0].lowercased()
            if config[key] == nil { config[key] = String(words[1]) }
        }
        var parts: [String] = []
        for (key, name) in [("hostname", "hostname"), ("user", "user"), ("port", "port"),
                            ("proxycommand", "ProxyCommand"), ("proxyjump", "ProxyJump")] {
            if let value = config[key], value != "none" { parts.append("\(name) \(value)") }
        }
        return "ssh -G \(destination): " + (parts.isEmpty ? "it printed no hostname." : parts.joined(separator: ", "))
    }

    /// Where to look for an ssh destination an item doesn't give by name (#975).
    static let sshHunt = """
        Look through the whole item for one: a user@host inside IDE or deep-link URLs (ssh-remote+coder@host), \
        host= and user= query parameters, a program=ssh argument (arg=coder%40host). Write it as a template over the \
        item's own fields, such as "coder@cws.{name}", never one workspace's literal. If it can't be written from the \
        item's fields, leave ssh out and give the literal you found in send_draft's note.
        """

    static func cut(_ text: String) -> String {
        guard text.utf8.count > cut else { return text }
        let head = String(decoding: Array(text.utf8.prefix(cut)), as: UTF8.self)
        return head + "\n[Cut at 16 KB of \(text.utf8.count / 1024) KB.]"
    }

    static func lines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).prefix(count).joined(separator: "\n")
    }

    static func minutes(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds >= 60 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
    }

    static func words(_ error: any Error) -> String {
        if let failure = error as? ProviderFailure { return failure.description }
        if let refused = error as? JSONRPCError { return refused.message }
        return "\(error)"
    }

    static func refusal(_ message: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCError.invalidParams, message: message)
    }

    static func attempt<T: Sendable>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    // MARK: The prompt (research R7)

    static func prompt(_ draft: Draft, seed: String, existing: (old: JSONValue?, problem: String?)?) -> String {
        let goal = draft.isCommands
            ? "Write a config for Agents' command provider, so the CLI `\(draft.cli)` can list, start and stop the machines it runs agents on."
            : "Write a tool map, so this MCP server's own tools can list, start and stop the machines Agents runs agents on."
        var parts = [
            """
            You write one \(draft.isCommands ? "command-provider config" : "tool map") for Agents' Add Provider sheet. \
            \(goal) A person reads what you send and adds it.

            You have only these tools: \(draft.isCommands ? "read_help" : "read_tools"), check_draft, prove_start, \
            prove_stop, send_draft and give_up. You can't run commands, read files or reach the network: the control \
            plane does all of that for you.

            Rules:
            - Check before you send: check_draft lists the workspaces once with your draft. Change it and check again \
            until it passes. At most \(maxChecks) checks and \(maxCalls) calls; about \(minutes(Timing.standard.total)).
            - The list must be a plain list. A check that may change something is asked of the person, who may say no.
            - Ask with prove_start or prove_stop only when you are not sure of the start or stop. Each costs money and \
            changes a machine, so the person is asked every time. Don't ask more than once for each.
            - Give ssh when you can: without it, no workspace can be added as a host, or started over ssh. \
            \(sshHunt) check_draft tests it with `ssh -G`, which resolves it without connecting.
            - End with send_draft (the draft that passed, and a short note for the person: what you did not try), or \
            give_up with one sentence. Then end your turn.
            """,
        ]
        if !draft.secrets.isEmpty {
            parts.append("Its secrets are \(draft.secrets.keys.sorted().joined(separator: ", ")). You never see their values: where one would show, you see ${NAME}. Don't put a secret in a draft: the control plane passes them to the \(draft.isCommands ? "CLI as environment" : "server") itself.")
        }
        parts.append(draft.isCommands ? commandFormat : mapFormat)
        if let existing {
            if let old = existing.old, let data = try? JSONEncoder().encode(old) {
                parts.append("It has this \(draft.isCommands ? "config" : "map") now:\n" + draft.redact(String(decoding: data, as: UTF8.self)))
            }
            if let problem = existing.problem { parts.append("Its last list failed: " + draft.redact(problem)) }
        }
        parts.append(draft.isCommands ? "`\(draft.cli) --help` printed:\n\(seed)" : "The server's tools (read_tools gives them again):\n\(seed)")
        return parts.joined(separator: "\n\n")
    }

    static let mapFormat = """
        The tool map's format (JSON):
        {
          "list": { "tool": "droplet-list", "arguments": { "tag_name": "agents" },
                    "items": "droplets", "id": "id", "name": "name", "state": "status",
                    "ssh": "root@{networks.v4[0].ip_address}", "cost": "${size.price_hourly}/hour",
                    "states": { "active": "running", "new": "starting", "off": "stopped" } },
          "start": { "tool": "droplet-power-on", "arguments": { "droplet_id": "{id}" } },
          "stop":  { "tool": "droplet-power-off", "arguments": { "droplet_id": "{id}" } }
        }
        - list.tool, start.tool and stop.tool are the server's tools, by name; each must be in its tools.
        - arguments is a template for the call's arguments. "{id}" is the workspace's id; "{id:number}" sends it as a number.
        - A path is dotted keys, with [n] for an index and [] for every element: droplets, networks.v4[0].ip_address.
          It is read in the tool's structuredContent, or its first text parsed as JSON.
        - list.items is the path to the array of workspaces; empty for the result itself. id, name and state are paths in
          each item. state's value is looked up in states, which maps the server's words to running, starting, stopping,
          stopped or unknown.
        - ssh, tunnel and cost are optional: a path, or a template with {path} in it.
        - create, delete and options are optional, the same shape as start.
        """

    static let commandFormat = """
        The command provider's config (JSON). Commands run with /bin/sh where the control plane runs.
        One workspace each:
        { "workspaces": [ { "id": "devstack-1", "name": "devstack", "start": "cws start devstack-1",
                            "stop": "cws stop devstack-1", "status": "cws status devstack-1", "ssh": "devstack-1.cws" } ] }
        - id defaults to name. status is optional; it prints the state, mapped by "states".
        Or many from one list:
        { "list": "cws list --no-header", "columns": ["id", "name", "state", "ip"],
          "start": "cws start ${id}", "stop": "cws stop ${id}", "ssh": "root@${ip}",
          "states": { "up": "running", "down": "stopped" } }
        - list prints one workspace per line, split on whitespace into columns; the last column takes the rest.
        - Or, instead of columns, "json": {"items": "<path>", "id": "<path>", "name": "<path>", "state": "<path>"}
          reads the output as JSON, with the tool map's paths.
        - ${column} in a template is the value from that workspace's row.
        - states maps the CLI's words to running, starting, stopping, stopped or unknown.
        """
}
