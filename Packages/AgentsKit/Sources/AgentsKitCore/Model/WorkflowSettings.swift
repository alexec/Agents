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
}
