import Foundation

/// What the workflow page says about each trigger, beyond its summary (#98): the
/// filters it narrows by, whose agents and events it listens to, and, for a
/// `triggering` workflow, which agent a run resumes.
///
/// Here rather than in a view so the Mac and the phone say it the same way, and so
/// the rules (which events are the Mac's, which carry an agent) are read from the
/// catalogue the daemon fires on rather than restated.
extension WorkflowTrigger {
    /// The details it is narrowed by, as the file writes them. `workflow-completed`
    /// with an `id:` is a `workflow` filter, which is what it is on the event log.
    public var filters: [String: DetailFilter] {
        switch self {
        case .event(let pattern): return pattern.filters
        case .workflowCompleted(let id): return id.map { ["workflow": DetailFilter($0)] } ?? [:]
        default: return [:]
        }
    }

    /// Whose agents and events it listens to: the project's, the host's as a whole
    /// (an event about the machine runs matching workflows in every project), or
    /// either. `nil` for a schedule, which is a clock, and for a trigger this version
    /// does not know, which listens to nothing.
    public var listensIn: EventScopeKind? {
        switch self {
        case .schedule, .unrecognised: return nil
        // A server's events are the project's: its servers are found by its folder.
        case .serverEvent: return .project
        case .agentFinished, .agentAskedPermission, .agentAskedForm, .agentStopped, .workflowCompleted:
            return .project
        case .event(let pattern):
            if EventCatalogue.isCustom(pattern.name) { return .project }
            if let subject = pattern.wholeSubject {
                if subject == .custom { return .project }
                let scopes = Set(EventCatalogue.kinds(in: subject).map(\.scope))
                return scopes.count == 1 ? scopes.first : .either
            }
            return EventCatalogue.kind(named: pattern.name)?.scope
        }
    }

    /// Which agent a `triggering` workflow's run resumes when this fires it, said as a
    /// sentence, or that there is none, in which case the trigger never runs it.
    public var resumedAgent: String {
        switch self {
        case .schedule:
            return "A clock has no agent to resume, so this never runs it"
        case .unrecognised:
            return "Never runs it"
        case .serverEvent:
            return "A server's events are about no agent, so this never runs it"
        case .agentFinished: return "Resumes the agent that finished"
        case .agentAskedPermission: return "Resumes the agent that asked"
        case .agentAskedForm: return "Resumes the agent that raised the form"
        case .agentStopped: return "Resumes the agent that stopped"
        case .workflowCompleted: return "Resumes the agent the finished run started"
        case .event(let pattern):
            if EventCatalogue.isCustom(pattern.name) || pattern.wholeSubject == .custom {
                return "Resumes the agent that published it"
            }
            let kinds = pattern.wholeSubject.map(EventCatalogue.kinds(in:))
                ?? EventCatalogue.kind(named: pattern.name).map { [$0] } ?? []
            let carrying = kinds.filter { $0.details.contains("agent") }
            if carrying.isEmpty { return "These events are about no agent, so this never runs it" }
            if carrying.count < kinds.count { return "Resumes the agent it is about, when there is one" }
            return "Resumes the agent it is about"
        }
    }
}

extension WorkflowCause {
    /// What set a run off, as it reads after "Last ran 2 hours ago": "by hand, with
    /// Run now", "on its schedule", "on branch.moved branch main".
    public var phrase: String {
        switch self {
        case .byHand: return "by hand, with Run now"
        case .trigger(let trigger):
            switch trigger {
            case .schedule: return "on its schedule"
            case .event(let pattern): return "on \(pattern.label)"
            case .serverEvent(let event): return "on \(event.event)"
            default: return WorkflowTrigger.lowercasedFirst(trigger.summary)
            }
        }
    }
}
