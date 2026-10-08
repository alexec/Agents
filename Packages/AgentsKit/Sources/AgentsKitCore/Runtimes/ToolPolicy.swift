import Foundation

// A policy is which of a runtime's own tools an agent started by this app may keep.
//
// Every runtime arrives holding its own version of nearly everything this app owns: a
// way to make something happen on a schedule, a way to raise a question to somebody, a
// way to start another agent, somewhere to put what it wrote. The app has been arguing
// with those in words, and words lose — an instruction sits in the first prompt of a
// conversation, and a tool sits in front of the model on every single turn. So the tool
// goes instead, for the sessions this app starts and only for those. Nothing here reads
// or writes anything of the person's, and nothing is left behind when the app is not
// running.
//
// It is a table rather than a run of conditionals because of the rule the README sets
// for the whole app: no code in the app asks which runtime it is talking to. `Lever` is
// six ways of *asking* — a deny list in the session, an allow list in the session,
// flags at launch, JSON in a variable, a file the runtime is pointed at, or nothing at
// all — and the runtime
// id appears exactly once, as the
// key this table is looked up by.
//
// Nothing in here was read out of documentation. Every name, every key path and every
// flag was sent to the real runtime and the answer checked; the measurements, with their
// dates and versions, are in `specs/015-runtime-tool-scoping/research.md`. That is also
// why `residue` exists: three of the four runtimes will not let go of everything, and a
// policy that pretended otherwise would be a policy nobody could trust.

/// What job of this app's a tool duplicates.
public enum RemitCategory: String, Codable, Hashable, Sendable, CaseIterable {
    /// Schedules, cron entries, timers, wake-ups, monitors and standing goals.
    case standingArrangements
    /// Raising a question, a form or a notification to a person.
    case escalation
    /// Creating, starting, messaging, inspecting or stopping other agents.
    case agents
    /// Storing work outside the project: document stores, drives, session databases.
    case artefacts
    /// Offering the person a follow-up prompt.
    case suggestions
    /// Changing the folder the session works in, or making a worktree to move into (053).
    case workingFolder

    /// What to do instead, said in the one sentence an agent is given.
    ///
    /// Every removal and every piece of residue names exactly one category, which is
    /// what makes this table arguable rather than a list of names somebody disliked —
    /// and it is why the briefing line and the permission refusal cannot disagree about
    /// a tool: they both read this.
    ///
    /// Exhaustive on purpose, with no `default`: a category added without a sentence is
    /// a category an agent would be refused with silence.
    public var instead: String {
        switch self {
        case .standingArrangements:
            "Use `\(AppTool.manageWorkflows)` for anything that has to happen on its own."
        case .escalation:
            "Ask me with your question or form tool; it reaches me wherever I am."
        case .agents:
            "This app starts and stops agents; ask me rather than starting one."
        case .artefacts:
            "Put it in the conversation or in a file in this project."
        case .suggestions:
            "If you suggest a next prompt, give it to `\(AppTool.finishTurn)`."
        case .workingFolder:
            "Give `worktree` or `leave_worktree` to `\(AppTool.finishTurn)` to change where you work."
        }
    }
}

/// A tool taken away, and the job of ours it was duplicating.
public struct RemovedTool: Codable, Hashable, Sendable {
    /// The runtime's own id for the tool, spelled the way its lever spells it: bare
    /// (`task`), whole-server (`mcp__claude_ai_Google_Drive`) or exact (`ScheduleWakeup`).
    public var name: String
    public var category: RemitCategory

    public init(name: String, category: RemitCategory) {
        self.name = name
        self.category = category
    }
}

/// A tool left in place that looks like it should have gone.
public struct KeptTool: Codable, Hashable, Sendable {
    public var name: String
    /// Why it survived.
    ///
    /// This field exists for one tool and one reader. The escalation tool is the thing
    /// this whole feature was built to protect, and it looks exactly like the rivals
    /// being removed; without a reason written beside it, somebody tidying this table in
    /// a year moves it into `removed` and takes away the only way an agent has of
    /// reaching the person.
    public var because: String

    public init(name: String, because: String) {
        self.name = name
        self.because = because
    }
}

/// A conflicting tool a runtime will not let us remove. Covered by words instead.
public struct ResidualTool: Codable, Hashable, Sendable {
    public var name: String
    public var category: RemitCategory

    /// Taken from the category rather than stored, so the briefing line and the refusal
    /// cannot drift apart into two sentences about the same tool.
    public var instead: String { category.instead }

    public init(name: String, category: RemitCategory) {
        self.name = name
        self.category = category
    }
}

/// Config the app writes for a runtime that will read policy only from a file.
///
/// Nothing reads it back. It is an argument that happens to need a path: written whole
/// before the process starts, pointed at by an environment variable or by a launch
/// argument, and rebuilt every launch from the policy above it (Research R11).
///
/// Grok reads its switches only from a file named by `GROK_CONFIG_PATH`. Gemini reads
/// extra policy from `--policy <path>`, which adds to the person's own policies where a
/// settings file named by a variable would replace theirs key by key (046, R5).
public struct EnvironmentFile: Codable, Hashable, Sendable {
    /// The file's name under `<root>/runtimes/`.
    public var name: String
    public var contents: String
    /// The environment variable pointed at it, or nil when an argument is.
    public var variable: String?
    /// The launch flag its path follows, or nil when a variable points at it.
    public var argument: String?

    public init(name: String, contents: String, variable: String) {
        self.name = name
        self.contents = contents
        self.variable = variable
        self.argument = nil
    }

    public init(name: String, contents: String, argument: String) {
        self.name = name
        self.contents = contents
        self.variable = nil
        self.argument = argument
    }
}

/// A runtime's sign-in relayed from the Mac to a server (047, research R12; Claude's, 056).
///
/// The sign-in stays on the Mac. On the server the runtime starts with a stand-in that holds
/// no secret, pointed at the relay gate on loopback over TLS it is told to trust; the Mac's
/// relay puts its own current token on each request and sends it on to `upstreamHost`.
public struct SignInRelay: Codable, Hashable, Sendable {
    /// Where the Mac's own sign-in is kept.
    public enum MacSignInLocation: Codable, Hashable, Sendable {
        /// A file, relative to the home folder (Codex's `~/.codex/auth.json`).
        case file(String)
        /// A generic password in the login Keychain, as `/usr/bin/security` reads it
        /// (Claude's `Claude Code-credentials`, 056 research R5).
        case keychain(service: String)
    }

    /// How the runtime on the server is pointed at the gate.
    public enum Pointing: Codable, Hashable, Sendable {
        /// A home of the app's own holding a config (with `{port}` for the gate's port) and
        /// the stand-in sign-in file, named by `homeVariable` (Codex).
        case home(homeVariable: String, configFile: String, signInFile: String, configTemplate: String)
        /// Variables only; their values may hold `{port}` and `{standIn}` (Claude, 056 R7).
        case environment([String: String])
    }

    public var upstreamHost: String
    public var macSignIn: MacSignInLocation
    public var pointing: Pointing
    /// The variable naming the CA certificate the runtime is told to trust.
    public var certificateVariable: String
    /// Taken out of the environment of a relayed run, so no other sign-in wins over it.
    public var clearedVariables: [String]
    /// Where a server's own sign-in for this runtime may be, to tell whether it has one:
    /// variables in the login environment, and a file relative to the home folder.
    public var ownSignInVariables: [String]
    public var ownSignInFile: String?

    public init(upstreamHost: String, macSignIn: MacSignInLocation, pointing: Pointing,
                certificateVariable: String, clearedVariables: [String] = [],
                ownSignInVariables: [String] = [], ownSignInFile: String? = nil) {
        self.upstreamHost = upstreamHost
        self.macSignIn = macSignIn
        self.pointing = pointing
        self.certificateVariable = certificateVariable
        self.clearedVariables = clearedVariables
        self.ownSignInVariables = ownSignInVariables
        self.ownSignInFile = ownSignInFile
    }

    /// The config written into the runtime's home, for a `.home` relay; nil otherwise.
    public func config(gatePort: UInt16) -> String? {
        guard case .home(_, _, _, let template) = pointing else { return nil }
        return template.replacingOccurrences(of: "{port}", with: String(gatePort))
    }

    /// The variables of an `.environment` relay, filled in; empty for a `.home` one.
    public func environment(gatePort: UInt16, standIn: String) -> [String: String] {
        guard case .environment(let template) = pointing else { return [:] }
        return template.mapValues {
            $0.replacingOccurrences(of: "{port}", with: String(gatePort)).replacingOccurrences(of: "{standIn}", with: standIn)
        }
    }
}

/// How a removal is asked for.
///
/// Six ways of asking, not six runtimes. Nothing downstream switches on a runtime id:
/// the daemon asks the policy for a `_meta` object, a list of launch arguments and a set
/// of environment files, and sends whatever comes back.
///
/// An allow list carries its own `keep` rather than deriving it from `removed`, because
/// "everything except these" and "only these" are different claims and only one of them
/// is true of any given runtime. Deriving one from the other would make the table lie
/// about which claim it is making.
public enum Lever: Hashable, Sendable {
    /// The removed names go into an array at this key path inside `session/new` `_meta`.
    case sessionMetaDenyList(path: [String])
    /// The names in `keep` go into an array at this key path; `extra` is whatever else
    /// that object needs to be accepted.
    case sessionMetaAllowList(path: [String], keep: [String], extra: [String: JSONValue])
    /// The removed names follow `flag` on the command line, and `extra` is the rest of
    /// the flags.
    case launchArguments(flag: String, repeatsFlag: Bool, extra: [String])
    /// A JSON object in an environment variable, read by the runtime at start and merged
    /// into its own config for that process only (047: Codex's `CODEX_CONFIG`, whose
    /// feature switches take the removed tools away). The removed names are for the
    /// briefing; the switches that remove them are in `value`.
    case environmentJSON(variable: String, value: JSONValue)
    /// The removed names are written into one of the policy's `environmentFiles`, which the
    /// runtime is pointed at; nothing rides on the session or the command line besides the
    /// file's own path (046: Gemini's `--policy`).
    case file
    /// No mechanism at all. Everything conflicting is residue.
    case words
}

/// How a runtime is directed to the app's MCP tool schemas.
public enum AppToolSchemaDelivery: Hashable, Sendable {
    case none
    case sessionRules
    case firstPrompt
}

/// One runtime's policy: what goes, what deliberately stays, and what we could not move.
public struct ToolPolicy: Hashable, Sendable {
    public var runtimeID: String
    public var removed: [RemovedTool] = []
    public var kept: [KeptTool] = []
    public var residue: [ResidualTool] = []
    public var lever: Lever
    /// Some runtimes need the app's tools written out because they do not reliably
    /// discover them from the MCP catalog. The delivery point is runtime-specific.
    public var appToolSchemaDelivery: AppToolSchemaDelivery
    public var environmentFiles: [EnvironmentFile] = []
    /// This runtime's own name for a tool that can actually put a question to the person,
    /// where there is one — the one tool in `kept` the briefing may name out loud.
    ///
    /// "Can actually" is the whole of it, and it is narrower than "has a question tool".
    /// Grok has `ask_user_question`, keeps it, and lists it — and it draws a card in a
    /// terminal UI that does not exist over `agent stdio`, with no ACP notification that
    /// carries a question (R13). Naming it there was measured and made things worse: the
    /// agent spent its turn searching the MCP catalogue for a tool that could never reach
    /// anybody, and then guessed regardless. So this is `nil` for Grok.
    ///
    /// 016 deliberately named no tool in its escalation line, and was right to at the
    /// time: the tool belongs to the runtime, each spells it differently, and naming one
    /// would have been the first place in the app to branch on runtime identity. 015
    /// changed the facts that rested on. There is now a table that knows, per runtime,
    /// which tool this is — protecting it from removal is the single thing that feature
    /// could break that would matter most — so the name is already written down, and the
    /// briefing reads it from here rather than the app guessing.
    ///
    /// `nil` where we do not know the name, which is not a formality: Copilot has a
    /// question flow and nobody has established what its model calls it, so its line stays
    /// as it was rather than naming something that might not be there (FR-008).
    public var escalationTool: String?
    /// The order to offer this runtime's own sign-in methods in, by id, first to last (047:
    /// Codex puts ChatGPT before an API key, D1). Methods not named keep their order after
    /// these. Empty keeps the rule for everyone else: the first one without a terminal.
    public var preferredAuthMethods: [String]
    /// Added to its environment by a server's daemon only (047: Codex's `NO_BROWSER`, so a
    /// ChatGPT sign-in is never offered on a server).
    public var serverEnvironment: [String: String]
    /// How this runtime's sign-in is relayed from the Mac to a server (047), or nil when it
    /// is not.
    public var relay: SignInRelay?
    /// Not offered the client's file reading, so the runtime reads from disk itself; writes
    /// still come through the app (046). Gemini's `write_file` reads first and treats only
    /// an error carrying code `ENOENT` as "a new file", which a JSON-RPC error over ACP can
    /// never carry: every new file it tried to write through the app failed (walk,
    /// 2026-09-25).
    public var readsFilesItself: Bool
    /// The sign-in method to call `authenticate` with when picking a conversation back up is
    /// refused as not signed in, before trying once more (046: Gemini's `gemini-api-key`,
    /// which reads the key from its environment and records that choice in Gemini's own
    /// settings — so only when needed).
    public var authMethodBeforeContinuing: String?

    public init(runtimeID: String,
                removed: [RemovedTool] = [],
                kept: [KeptTool] = [],
                residue: [ResidualTool] = [],
                lever: Lever,
                appToolSchemaDelivery: AppToolSchemaDelivery = .none,
                environmentFiles: [EnvironmentFile] = [],
                escalationTool: String? = nil,
                preferredAuthMethods: [String] = [],
                serverEnvironment: [String: String] = [:],
                relay: SignInRelay? = nil,
                readsFilesItself: Bool = false,
                authMethodBeforeContinuing: String? = nil) {
        self.runtimeID = runtimeID
        self.removed = removed
        self.kept = kept
        self.residue = residue
        self.lever = lever
        self.appToolSchemaDelivery = appToolSchemaDelivery
        self.environmentFiles = environmentFiles
        self.escalationTool = escalationTool
        self.preferredAuthMethods = preferredAuthMethods
        self.serverEnvironment = serverEnvironment
        self.relay = relay
        self.readsFilesItself = readsFilesItself
        self.authMethodBeforeContinuing = authMethodBeforeContinuing
    }

    /// What rides in `_meta` on `session/new`, `session/load` and `session/fork`.
    ///
    /// Two shapes, both fixed by `specs/015-runtime-tool-scoping/contracts/runtime-launch.md`:
    /// a deny list nests the removed names at its path, and an allow list nests the kept
    /// names at its path with `extra` beside them in that same object. A runtime scoped
    /// by flags or by words sends no `_meta` at all, exactly as it does today.
    public var sessionMeta: JSONValue? {
        switch lever {
        case .sessionMetaDenyList(let path):
            // Nothing to deny is not a message. An empty list says the client thought
            // about tools and had none to hide, which is a different thing from saying
            // nothing at all, and a runtime we have nothing to hide from gets the
            // nothing — as it always has.
            removed.isEmpty ? nil : Self.nesting(.array(removed.map { .string($0.name) }), at: path, beside: [:])
        case .sessionMetaAllowList(let path, let keep, let extra):
            Self.nesting(.array(keep.map(JSONValue.string)), at: path, beside: extra)
        case .launchArguments, .environmentJSON, .file, .words:
            nil
        }
    }

    /// What is added to the runtime's environment when the process is started: the
    /// `environmentJSON` lever's variable, its value as compact JSON with sorted keys, so
    /// the same policy is the same text every launch. Empty for every other lever.
    public var launchEnvironment: [String: String] {
        guard case .environmentJSON(let variable, let value) = lever else { return [:] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return [:] }
        return [variable: text]
    }

    /// Fold the path from the inside out: the value goes at the last key, `beside` joins
    /// it in that same object, and every key outwards wraps what has been built so far.
    private static func nesting(_ value: JSONValue, at path: [String],
                                beside extra: [String: JSONValue]) -> JSONValue? {
        guard let last = path.last else { return nil }
        var innermost = extra
        innermost[last] = value
        var built = JSONValue.object(innermost)
        for key in path.dropLast().reversed() { built = .object([key: built]) }
        return built
    }

    /// What is added to the runtime's own arguments when the process is started.
    public var launchArguments: [String] {
        guard case .launchArguments(let flag, let repeatsFlag, let extra) = lever else { return [] }
        let names = removed.map(\.name)
        guard !names.isEmpty else { return extra }
        return extra + (repeatsFlag ? names.flatMap { [flag, $0] } : [flag] + names)
    }

    /// The residual tool a given tool call is, if it is one.
    ///
    /// Matched on the end of the name and never whole, for the reason `AppService`
    /// already gives about its own tools: a runtime is free to prefix a tool's name —
    /// the Claude adapter shows ours as `mcp__agents__finish_turn` — and none
    /// of them changes what follows the prefix.
    public func residual(matching name: String) -> ResidualTool? {
        residue.first { name.hasSuffix($0.name) }
    }
}
