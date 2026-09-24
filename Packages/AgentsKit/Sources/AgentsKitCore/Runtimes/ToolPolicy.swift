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
// four ways of *asking* — a deny list in the session, an allow list in the session,
// flags at launch, or nothing at all — and the runtime id appears exactly once, as the
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
            "Use `\(AppTool.finishTurn)` at the end of the turn."
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
/// before the process starts, pointed at by an environment variable, and rebuilt every
/// launch from the policy above it (Research R11).
public struct EnvironmentFile: Codable, Hashable, Sendable {
    /// The file's name under `<root>/runtimes/`.
    public var name: String
    public var contents: String
    /// The environment variable pointed at it.
    public var variable: String

    public init(name: String, contents: String, variable: String) {
        self.name = name
        self.contents = contents
        self.variable = variable
    }
}

/// How a removal is asked for.
///
/// Four ways of asking, not four runtimes. Nothing downstream switches on a runtime id:
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
    /// No mechanism at all. Everything conflicting is residue.
    case words
}

/// One runtime's policy: what goes, what deliberately stays, and what we could not move.
public struct ToolPolicy: Hashable, Sendable {
    public var runtimeID: String
    public var removed: [RemovedTool] = []
    public var kept: [KeptTool] = []
    public var residue: [ResidualTool] = []
    public var lever: Lever
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

    public init(runtimeID: String,
                removed: [RemovedTool] = [],
                kept: [KeptTool] = [],
                residue: [ResidualTool] = [],
                lever: Lever,
                environmentFiles: [EnvironmentFile] = [],
                escalationTool: String? = nil) {
        self.runtimeID = runtimeID
        self.removed = removed
        self.kept = kept
        self.residue = residue
        self.lever = lever
        self.environmentFiles = environmentFiles
        self.escalationTool = escalationTool
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
            Self.nesting(.array(removed.map { .string($0.name) }), at: path, beside: [:])
        case .sessionMetaAllowList(let path, let keep, let extra):
            Self.nesting(.array(keep.map(JSONValue.string)), at: path, beside: extra)
        case .launchArguments, .words:
            nil
        }
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
    /// the Claude adapter shows ours as `mcp__agents__suggest_next_prompts` — and none
    /// of them changes what follows the prefix.
    public func residual(matching name: String) -> ResidualTool? {
        residue.first { name.hasSuffix($0.name) }
    }
}
