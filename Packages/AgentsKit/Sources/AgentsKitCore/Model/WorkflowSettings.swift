import Foundation

/// What a workflow says about how its agent should be started: a permission mode, a
/// runtime, a model.
///
/// The values are the runtime's own strings, passed through untouched. This app does
/// not define a vocabulary of modes and could not support the claim if it did — that
/// `plan` on one runtime is the same promise as `plan` on another is not something
/// anyone here has checked, and a translation layer would be asserting it on every
/// fire. A workflow belongs to a project, and a project's runtime is something the
/// person already chose.
///
/// All three are optional, and a workflow stating none of them starts exactly as every
/// workflow started before this feature.
///
/// The permission mode is the one that matters. An agent a person starts has them
/// sitting in front of it, watching what it asks for; a workflow's agent starts at nine
/// in the morning whether or not anybody is at the machine. The mode is the only thing
/// in the file that says how much it may do while nobody is looking.
public struct WorkflowSettings: Codable, Hashable, Sendable {
    /// The value of the runtime's own mode option, verbatim.
    public var permissionMode: String?
    /// A runtime id, as `RuntimeCatalog` knows them: `claude`, `grok`, `copilot`, `cursor`.
    public var runtimeID: String?
    /// The value of the runtime's own model option, verbatim.
    public var model: String?

    public init(permissionMode: String? = nil, runtimeID: String? = nil, model: String? = nil) {
        self.permissionMode = permissionMode
        self.runtimeID = runtimeID
        self.model = model
    }

    /// Whether this workflow says nothing about how it runs.
    ///
    /// What this decides is which start path the workflow takes. An empty settings
    /// takes the one this app has always taken — no session made ahead of the agent,
    /// nothing to check anything against, no extra process — which is what keeps the
    /// common case as quick as it was and is the whole of SC-006. Every workflow
    /// written before this feature lands here, and most written after it will too.
    public var isEmpty: Bool {
        permissionMode == nil && runtimeID == nil && model == nil
    }

    /// The clause `Workflow.summary` appends: `in plan mode, on Grok, using claude-opus-5`.
    /// `nil` when there is nothing to say.
    ///
    /// The runtime is left out when it is the default one. Naming it on every row
    /// would put the same four words on every workflow in the project, and a row that
    /// says something about all of them says nothing about any of them.
    public var summary: String? {
        guard !isEmpty else { return nil }
        var clauses: [String] = []
        if let permissionMode { clauses.append("in \(permissionMode) mode") }
        if let runtimeID, runtimeID != RuntimeCatalog.builtIn[0].id {
            clauses.append("on \(RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID)")
        }
        if let model { clauses.append("using \(model)") }
        return clauses.isEmpty ? nil : clauses.joined(separator: ", ")
    }

    /// The names these settings go by in the file, and the names a refusal is grouped
    /// by afterwards.
    ///
    /// One set of strings, because a refusal that says `permission-mode` and a file
    /// that says `permission_mode` would be the app and the document disagreeing about
    /// what the person wrote.
    public enum Setting {
        public static let permissionMode = "permission-mode"
        public static let runtime = "runtime"
        public static let model = "model"
    }

    /// What to start with, or why nothing may start.
    public enum Resolution: Sendable {
        case resolved(StartOptions)
        case refused(setting: String, value: String, offered: [String])
    }

    /// Turn what the file asked for into what the runtime will be sent — or say that it
    /// cannot be.
    ///
    /// Pure: no I/O, no actor, no clock. It is handed the options the runtime advertised
    /// in this session, and it either finds every named value among them or refuses.
    ///
    /// **There is no fallback branch, and adding one later would be adding the bug.**
    /// Every fallback available here is in the permissive direction: the mode a workflow
    /// names is the restrictive one — that is why somebody bothered to write it down —
    /// and the thing to fall back to is always the runtime's default, which allows more.
    /// An agent a person starts has them sitting in front of it and can afford a dropped
    /// option; this one starts at nine in the morning with nobody in the room. A
    /// workflow that does not run is a row that says why. A workflow that runs with a
    /// permission nobody granted is the thing this whole feature exists to prevent.
    public static func resolve(_ settings: WorkflowSettings,
                               against advertised: [ConfigOption]) -> Resolution {
        var values: [String: JSONValue] = [:]

        if let named = settings.permissionMode {
            // `ModeMemory`'s, and not a second opinion: the prompt bar and a workflow
            // must not be able to come to disagree about which advertised option is
            // *the* mode, because then a person would be setting one thing and a
            // workflow another under the same word.
            let option = ModeMemory.modeOption(in: advertised)
            guard let option, let choice = choice(named, in: option) else {
                return .refused(setting: Setting.permissionMode, value: named,
                                offered: offered(by: option))
            }
            // Keyed by the id the runtime advertised, never by the string "mode": a
            // runtime is free to call it `permission_mode`, and it is the one that
            // decides.
            values[option.id] = choice.value
        }

        if let named = settings.model {
            let option = modelOption(in: advertised)
            guard let option, let choice = choice(named, in: option) else {
                return .refused(setting: Setting.model, value: named,
                                offered: offered(by: option))
            }
            values[option.id] = choice.value
        }

        return .resolved(StartOptions(values: values))
    }

    /// The sentence a refusal carries, read by a person on the row and by an agent that
    /// asks how its workflow got on.
    ///
    /// It names what would have worked, because the reader's next move is to edit the
    /// file and the list is the whole of what they need to do it.
    public static func refusalDetail(setting: String, value: String,
                                     offered: [String], runtime: String) -> String {
        let phrase = phrase(for: setting)
        guard !offered.isEmpty else {
            return "\(runtime) does not offer \(phrase) here at all"
        }
        return "\"\(value)\" is not \(phrase) \(runtime) offers here — it offers \(offered.joined(separator: ", "))"
    }

    /// The option that carries the model, by the same rule `ModeMemory` uses for the
    /// mode: by `category` first, because that is what the rest of the app orders and
    /// reasons about, and by `id` second, because a runtime that sends no category
    /// still has to be usable.
    private static func modelOption(in options: [ConfigOption]) -> ConfigOption? {
        let selectable = options.filter { if case .select = $0.kind { return true } else { return false } }
        return selectable.first { $0.category == "model" } ?? selectable.first { $0.id == "model" }
    }

    /// The advertised choice a file's word names, if the runtime offers one. A file can
    /// only hold text, so the comparison is against the choice's own string value.
    private static func choice(_ named: String, in option: ConfigOption) -> ConfigChoice? {
        (option.options ?? []).first { $0.value.stringValue == named }
    }

    /// What the runtime does offer, in the order it sent them, so the refusal reads as
    /// a menu rather than a sorted set somebody has to search.
    private static func offered(by option: ConfigOption?) -> [String] {
        (option?.options ?? []).map { $0.value.stringValue ?? $0.name }
    }

    private static func phrase(for setting: String) -> String {
        switch setting {
        case Setting.permissionMode: return "a permission mode"
        case Setting.runtime: return "a runtime"
        case Setting.model: return "a model"
        default: return "a \(setting)"
        }
    }
}
