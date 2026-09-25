import Foundation

/// What a workflow says about how its agent should be started: a permission mode, a
/// runtime, a model, an effort, and any other option the runtime advertises.
///
/// The values are the runtime's own strings, passed through untouched. This app does
/// not define a vocabulary of modes and could not support the claim if it did — that
/// `plan` on one runtime is the same promise as `plan` on another is not something
/// anyone here has checked, and a translation layer would be asserting it on every
/// fire. A workflow belongs to a project, and a project's runtime is something the
/// person already chose.
///
/// All of them are optional, and a workflow stating none of them starts exactly as every
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
    /// The value of the runtime's thinking-level option, verbatim: `high`, `max`. Named
    /// by what it is rather than by the runtime's id for it, because the one thing every
    /// runtime here offers under a different id (`effort`, `reasoning_effort`) is this.
    public var effort: String?
    /// Every other option the runtime advertises, keyed by its advertised id and written
    /// as the file wrote it: `fast: true`, `allow_all: on`. What the text means — a
    /// choice, or a boolean — is the runtime's to say, and is only known once it has.
    public var options: [String: String]

    public init(permissionMode: String? = nil, runtimeID: String? = nil, model: String? = nil,
                effort: String? = nil, options: [String: String] = [:]) {
        self.permissionMode = permissionMode
        self.runtimeID = runtimeID
        self.model = model
        self.effort = effort
        self.options = options
    }

    /// Read leniently, because a phone or window a version behind sends settings
    /// without the two later keys.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        runtimeID = try c.decodeIfPresent(String.self, forKey: .runtimeID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        options = try c.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }

    /// Whether this workflow says nothing about how it runs.
    ///
    /// What this decides is which start path the workflow takes. An empty settings
    /// takes the one this app has always taken — no session made ahead of the agent,
    /// nothing to check anything against, no extra process — which is what keeps the
    /// common case as quick as it was and is the whole of SC-006. Every workflow
    /// written before this feature lands here, and most written after it will too.
    public var isEmpty: Bool {
        permissionMode == nil && runtimeID == nil && model == nil && effort == nil && options.isEmpty
    }

    /// The clause `Workflow.summary` appends:
    /// `in plan mode, on Grok, using claude-opus-5, at high effort, with fast`.
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
        if let effort { clauses.append("at \(effort) effort") }
        // A boolean reads as one — `with fast`, `without fast` — whatever word the
        // file used for it; anything else is its value.
        for (id, value) in options.sorted(by: { $0.key < $1.key }) {
            switch Self.boolean(value) {
            case true?: clauses.append("with \(id)")
            case false?: clauses.append("without \(id)")
            case nil: clauses.append("with \(id) \(value)")
            }
        }
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
        public static let effort = "effort"
        /// The block the rest go under. A refusal of one of them is grouped by the
        /// option's own id, which is what the file says under this.
        public static let options = "options"
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

        if let named = settings.effort {
            let option = effortOption(in: advertised)
            guard let option, let choice = choice(named, in: option) else {
                return .refused(setting: Setting.effort, value: named,
                                offered: offered(by: option))
            }
            values[option.id] = choice.value
        }

        // In id order, so the same file always refuses on the same option.
        for (id, named) in settings.options.sorted(by: { $0.key < $1.key }) {
            let option = advertised.first { $0.id == id }
            let value: JSONValue?
            switch option?.kind {
            case .select: value = option.flatMap { choice(named, in: $0) }?.value
            case .boolean: value = boolean(named).map(JSONValue.bool)
            case .unsupported, nil: value = nil
            }
            // Named twice — once by its own key, once under `options:` — and to two
            // different things. Which one was meant is not something to pick.
            guard let value, values[id] == nil || values[id] == value else {
                return .refused(setting: id, value: named, offered: offered(by: option))
            }
            values[id] = value
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
            let what = [Setting.permissionMode, Setting.runtime, Setting.model, Setting.effort]
                .contains(setting) ? phrase : "an option called `\(setting)`"
            return "\(runtime) does not offer \(what) here at all"
        }
        return "\"\(value)\" is not \(phrase) \(runtime) offers here — it offers \(offered.joined(separator: ", "))"
    }

    /// The option that carries the model, by the same rule `ModeMemory` uses for the
    /// mode: by `category` first, because that is what the rest of the app orders and
    /// reasons about, and by `id` second, because a runtime that sends no category
    /// still has to be usable. Public for the same reason `ModeMemory.modeOption` is:
    /// the page that draws the menu and the start path that checks the file must not
    /// be able to disagree about which option is *the* model.
    public static func modelOption(in options: [ConfigOption]) -> ConfigOption? {
        let selectable = options.filter { if case .select = $0.kind { return true } else { return false } }
        return selectable.first { $0.category == "model" } ?? selectable.first { $0.id == "model" }
    }

    /// The option that carries the thinking level, by the same rule: `thought_level` is
    /// the category every runtime here sends it under, and the ids are the ones they
    /// have been seen to use when a category is missing.
    public static func effortOption(in options: [ConfigOption]) -> ConfigOption? {
        let selectable = options.filter { if case .select = $0.kind { return true } else { return false } }
        return selectable.first { $0.category == "thought_level" }
            ?? selectable.first { ["effort", "reasoning_effort", "thought_level"].contains($0.id) }
    }

    /// Whether an option is one of the three the file names by what it is rather than
    /// under `options:`. Only selects: a boolean in the mode's category is still a
    /// boolean, and goes under `options:` like any other.
    public static func isNamedOnItsOwn(_ option: ConfigOption, in options: [ConfigOption]) -> Bool {
        [ModeMemory.modeOption(in: options), modelOption(in: options), effortOption(in: options)]
            .contains { $0?.id == option.id }
    }

    /// A boolean as a file writes one. YAML's own words, and nothing looser: `1` or
    /// `enabled` is a guess at what somebody meant.
    public static func boolean(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }

    /// The advertised choice a file's word names, if the runtime offers one. A file can
    /// only hold text, so the comparison is against the choice's own string value.
    private static func choice(_ named: String, in option: ConfigOption) -> ConfigChoice? {
        (option.options ?? []).first { $0.value.stringValue == named }
    }

    /// What the runtime does offer, in the order it sent them, so the refusal reads as
    /// a menu rather than a sorted set somebody has to search.
    public static func offered(by option: ConfigOption?) -> [String] {
        if option?.isBoolean == true { return ["true", "false"] }
        return (option?.options ?? []).map { $0.value.stringValue ?? $0.name }
    }

    private static func phrase(for setting: String) -> String {
        switch setting {
        case Setting.permissionMode: return "a permission mode"
        case Setting.runtime: return "a runtime"
        case Setting.model: return "a model"
        case Setting.effort: return "an effort"
        default: return "a value for `\(setting)` that"
        }
    }
}
