import Foundation

/// A workflow that has stopped working, as Needs You lists it (#989): its last run's agent
/// failed or is blocked on the person, or it refuses every fire until somebody acts.
///
/// Only the kinds that do not clear by themselves. A cooldown, the day's limit, the app
/// closed, a run in flight or queued sort themselves out; waiting for an OK is listed as
/// an approval (#773). A row orange on its folder's page was easy to miss: a workflow
/// runs with nobody watching, so its failure has to reach the person where they look.
public struct WorkflowFailure: Hashable, Sendable {
    /// Which failure this is: the run or the refusal. Dismiss keeps it on the workflow's
    /// record, and the row comes back when the key is a new one.
    public var key: String
    /// What went wrong, in the row's grey line.
    public var line: String
    /// When it went wrong, where that is known.
    public var since: Date?
    /// The agent of the run that failed: the row opens it, and it is not listed in Needs
    /// You as a session too.
    public var agentID: UUID?

    public init(key: String, line: String, since: Date? = nil, agentID: UUID? = nil) {
        self.key = key
        self.line = line
        self.since = since
        self.agentID = agentID
    }

    /// From what the daemon holds without reading any file: the workflow, its last outcome
    /// and the agent that outcome started. Nil when nothing is wrong that a person must
    /// fix. `WorkflowSummary.failure` adds what the summary knows besides.
    public static func of(_ workflow: Workflow, lastOutcome: WorkflowOutcome?, ranAgent: Agent?) -> WorkflowFailure? {
        if workflow.isArchived { return nil }
        if let problem = workflow.problem, problem.needsAPerson {
            return WorkflowFailure(key: "problem:\(problem.message)", line: "Cannot be read — \(problem.message)")
        }
        switch lastOutcome {
        case .refused(let refusal, let at, _)? where refusal.needsAPerson && refusal != .awaitingApproval:
            // The file read well again since: a refusal for it is history now.
            if case .unreadable = refusal, workflow.problem == nil { return nil }
            return WorkflowFailure(key: "refused:\(refusal.code)", line: lastOutcome?.summary ?? refusal.message, since: at)
        case .ran(let id, let at)?:
            guard let agent = ranAgent, agent.id == id, let line = runFailure(of: agent) else { return nil }
            return WorkflowFailure(key: "ran:\(id.uuidString):\(at.timeIntervalSince1970)", line: line,
                                   since: agent.report?.at ?? at, agentID: id)
        default:
            return nil
        }
    }

    /// How a run's agent ended, when it failed: stopped short (a crash, an error, a
    /// refusal, a limit). A finished run is never a failure (#1916). A question is the agent's own row in Needs You, not a failure; an agent
    /// archived is one the person has put away.
    public static func runFailure(of agent: Agent) -> String? {
        switch agent.state {
        case .stopped:
            guard agent.group() == .needsAttention else { return nil }
            return "Run failed — " + (agent.endedReason?.summary ?? "it stopped")
        // A finished run is never a failure: only a question wants the person (#1916).
        default:
            return nil
        }
    }
}

extension WorkflowSummary {
    /// What Needs You says about it (#989), or nil when nothing is wrong that a person must
    /// fix. Waiting for an OK, or denied here, is not a failure: Needs You lists the first
    /// as an approval, and the second is the person's own answer.
    public func failure(ranAgent: Agent?) -> WorkflowFailure? {
        if isArchived || awaitingApproval != nil || deniedHere != nil { return nil }
        // Over the limit no more: the refusal is history, and the next fire runs.
        if case .refused(.overLimit, _, _)? = lastOutcome, overLimit == nil { return nil }
        return WorkflowFailure.of(workflow, lastOutcome: lastOutcome, ranAgent: ranAgent)
    }
}

extension DaemonAPI.FolderSummary {
    /// Whether a workflow here has stopped working (#989): the folder's row says "Needs
    /// you" for it, as for a session waiting.
    public var hasFailedWorkflow: Bool {
        approvals?.contains { $0.kind == .workflowFailed } == true
    }
}
