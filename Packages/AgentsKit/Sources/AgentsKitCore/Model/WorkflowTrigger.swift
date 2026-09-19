import Foundation

/// What makes a workflow run.
///
/// Closed, with one open case. `unrecognised` is what lets the format grow: a file
/// written against a later version, or by hand against next year's documentation, is
/// listed and inert rather than rejected. The triggers this version defers — file and
/// glob changes, git events, GitHub pull requests and CI — arrive as new cases here and
/// change nothing about a file already on disk.
///
/// Running a workflow by hand is deliberately not in here. Run now is offered on every
/// workflow whatever its triggers, including one whose triggers this version cannot
/// act on, so modelling it as a trigger would make it conditional on the very thing it
/// exists to work around.
public enum WorkflowTrigger: Codable, Hashable, Sendable {
    /// On a clock.
    case schedule(WorkflowSchedule)
    /// An agent in this project ended a turn having completed its work.
    case agentFinished
    /// An agent in this project asked for permission. Fires while the question is
    /// still outstanding, which is the only time an answer to it is any use.
    case agentAskedPermission
    /// An agent in this project raised a form to be filled in.
    case agentAskedForm
    /// An agent in this project stopped or failed without finishing.
    case agentStopped
    /// Another workflow's run completed. `nil` means any workflow in this project.
    case workflowCompleted(id: String?)
    /// Understood to be a trigger, and not one this version knows. Kept whole so that
    /// writing the file back does not quietly delete it.
    case unrecognised(name: String, keys: [String: JSONValue])

    /// The name this trigger goes by in a file.
    public var name: String {
        switch self {
        case .schedule: return "schedule"
        case .agentFinished: return "agent-finished"
        case .agentAskedPermission: return "agent-asked-permission"
        case .agentAskedForm: return "agent-asked-form"
        case .agentStopped: return "agent-stopped"
        case .workflowCompleted: return "workflow-completed"
        case .unrecognised(let name, _): return name
        }
    }

    /// Whether this version can act on it at all.
    public var isSupported: Bool {
        if case .unrecognised = self { return false }
        return true
    }

    /// The schedule this carries, if it is one.
    public var schedule: WorkflowSchedule? {
        if case .schedule(let schedule) = self { return schedule }
        return nil
    }

    /// The trigger in the words the project page uses.
    public var summary: String {
        switch self {
        case .schedule(let schedule): return schedule.summary
        case .agentFinished: return "When an agent finishes"
        case .agentAskedPermission: return "When an agent asks for permission"
        case .agentAskedForm: return "When an agent raises a form"
        case .agentStopped: return "When an agent stops without finishing"
        case .workflowCompleted(let id):
            return id.map { "When \($0) finishes" } ?? "When any workflow finishes"
        case .unrecognised(let name, _):
            return "Waits for \"\(name)\", which this version does not know about yet"
        }
    }

    /// Whether an agent event of this kind should fire this trigger.
    public func matches(_ event: WorkflowAgentEvent) -> Bool {
        switch (self, event) {
        case (.agentFinished, .finished), (.agentAskedPermission, .askedPermission),
             (.agentAskedForm, .askedForm), (.agentStopped, .stopped):
            return true
        default:
            return false
        }
    }
}

/// The agent events a workflow can watch, which are a subset of everything that happens
/// to an agent — the ones worth reacting to.
public enum WorkflowAgentEvent: String, Codable, Hashable, Sendable, CaseIterable {
    case finished
    case askedPermission
    case askedForm
    case stopped
}

/// Which agent a fired workflow's prompt goes to.
public enum WorkflowMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// A fresh agent, every fire.
    case new
    /// One long-lived agent belonging to this workflow, resumed each time so it
    /// accumulates context. A standing agent that has gone is replaced, and the
    /// replacement adopted.
    case standing
    /// The agent whose event fired this workflow. When there is no such agent, or it
    /// can no longer take a prompt, the fire is refused rather than sent somewhere else:
    /// substituting would send words meant for one conversation into another.
    case triggering

    public var summary: String {
        switch self {
        case .new: return "in a new agent"
        case .standing: return "in its own standing agent"
        case .triggering: return "in the agent that triggered it"
        }
    }
}
