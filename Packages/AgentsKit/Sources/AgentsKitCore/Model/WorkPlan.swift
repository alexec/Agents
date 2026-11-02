import Foundation

/// The Plan section on an epic's Work page (#3268, spec 3265), as the web page's `model/epicPlan.ts`:
/// its children step by step (`forge/plan`), each with a mark, the PR and the sessions that work on
/// it (from lineage, `lineage/cost`'s parts) and its cost; a header with the lead, the children
/// done and running, and the total cost; and the new-session form that Start lead fills in.
public enum WorkPlan {
    /// A child's mark: closed; a lane runs or a PR is open; a question waits or a check failed;
    /// waiting for its step; blocked by an open issue outside the plan.
    public enum Mark: String, Sendable, CaseIterable {
        case done = "✓"
        case working = "◐"
        case attention = "⚠"
        case waiting = "○"
        case blocked = "⊘"

        public var words: String {
            switch self {
            case .done: return "Done"
            case .working: return "Working"
            case .attention: return "Needs you"
            case .waiting: return "Waiting"
            case .blocked: return "Blocked outside the plan"
            }
        }
    }

    /// Whether an issue's page shows a plan: it has sub-issues, or it is labelled epic.
    public static func hasPlan(_ item: DaemonAPI.ForgeItem) -> Bool {
        item.node.kind == "issue" && ((item.progress?.total ?? 0) > 0 || item.level == "epic")
    }

    /// The pull request that works on a child: an open one first, else the newest.
    public static func pr(_ rollup: DaemonAPI.LineageCostRollup?) -> DaemonAPI.LineageCostNode? {
        let prs = (rollup?.parts ?? []).filter { $0.node.kind == "pr" }
        return prs.filter { $0.outcome == nil }.max { $0.lastAt < $1.lastAt } ?? prs.max { $0.lastAt < $1.lastAt }
    }

    /// The sessions that work on a child, by id: those linked to it (`lineage/walk`), at once,
    /// and those that banked a turn on it or its pull requests (`lineage/cost`'s parts).
    public static func sessions(_ child: DaemonAPI.LineageNode, links: [DaemonAPI.LineageLink] = [],
                                rollup: DaemonAPI.LineageCostRollup?) -> [UUID] {
        var refs: [String] = []
        for l in links {
            if l.to == child, l.from.kind == "session" { refs.append(l.from.ref) }
            if l.from == child, l.to.kind == "session" { refs.append(l.to.ref) }
        }
        refs += (rollup?.parts ?? []).flatMap { $0.sessions ?? [] }
        var seen: [UUID] = []
        for ref in refs {
            if let id = UUID(uuidString: String(ref.dropFirst("session:".count))), !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    /// A child's mark, from its state, its PR and the states of its sessions this app knows.
    public static func mark(_ child: DaemonAPI.ForgePlanChild, pr: DaemonAPI.LineageCostNode?,
                            states: [AgentState]) -> Mark {
        if child.item.state == "closed" { return .done }
        if states.contains(.waitingOnUser) || pr.map({ $0.outcome == nil && ($0.failedChecks ?? 0) > 0 }) == true {
            return .attention
        }
        if states.contains(where: \.holdsRuntime) || pr.map({ $0.outcome == nil }) == true { return .working }
        if !(child.blockedOutside ?? []).isEmpty { return .blocked }
        return .waiting
    }

    /// What works on a child: "● lane running · PR #3266 open"; nil with nothing.
    public static func workWords(pr: DaemonAPI.LineageCostNode?, states: [AgentState]) -> String? {
        var parts: [String] = []
        if states.contains(.waitingOnUser) {
            parts.append("● lane needs you")
        } else if states.contains(where: \.holdsRuntime) {
            parts.append("● lane running")
        }
        if let pr {
            var words = "PR \(WorkList.shortRef(pr.node.ref)) \(pr.outcome ?? "open")"
            if pr.outcome == nil, let failed = pr.failedChecks, failed > 0 {
                words += failed == 1 ? " · 1 failed check" : " · \(failed) failed checks"
            }
            parts.append(words)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The open issues outside the plan that block a child: "blocked by #17"; nil with none.
    public static func blockedWords(_ child: DaemonAPI.ForgePlanChild) -> String? {
        guard child.item.state != "closed", let outside = child.blockedOutside, !outside.isEmpty else { return nil }
        return "blocked by \(outside.map { WorkList.shortRef($0.ref) }.joined(separator: ", "))"
    }

    /// A child's cost, or nil with nothing spent.
    public static func costWords(_ rollup: DaemonAPI.LineageCostRollup?) -> String? {
        guard let total = rollup?.total, ReportValueWords.spent(total) else { return nil }
        return ReportValueWords.cost(total)
    }

    /// A step's title: "Step 4 · waits for #3088" while a child of an earlier step is open.
    public static func stepTitle(_ step: DaemonAPI.ForgePlanStep, in plan: DaemonAPI.ForgePlan) -> String {
        let open = Set(plan.children.filter { $0.item.state != "closed" }.map(\.item.node))
        var waits: [DaemonAPI.LineageNode] = []
        for child in plan.children where child.step == step.step && child.item.state != "closed" {
            for b in child.blockedBy where open.contains(b) && !waits.contains(b) { waits.append(b) }
        }
        guard !waits.isEmpty else { return "Step \(step.step)" }
        return "Step \(step.step) · waits for \(waits.map { WorkList.shortRef($0.ref) }.joined(separator: ", "))"
    }

    /// The header's figures: "5/7 done · 1 running · $41.20".
    public static func progressWords(_ plan: DaemonAPI.ForgePlan, running: Int,
                                     rollups: [DaemonAPI.LineageCostRollup]) -> String {
        let done = plan.children.filter { $0.item.state == "closed" }.count
        var parts = ["\(done)/\(plan.children.count) done"]
        if running > 0 { parts.append("\(running) running") }
        let total = sum(rollups.map(\.total))
        if ReportValueWords.spent(total) { parts.append(ReportValueWords.cost(total)) }
        return parts.joined(separator: " · ")
    }

    /// The costs added up, per currency.
    static func sum(_ costs: [DaemonAPI.LineageCost]) -> DaemonAPI.LineageCost {
        var out = DaemonAPI.LineageCost()
        for c in costs {
            out.cost.merge(c.cost, uniquingKeysWith: +)
            out.inputTokens += c.inputTokens
            out.outputTokens += c.outputTokens
            out.turns += c.turns
            out.workingSeconds += c.workingSeconds
            out.waitingSeconds += c.waitingSeconds
        }
        return out
    }

    /// The lead in the header: "Lead: “Work pages lead” (working)".
    public static func leadWords(_ lead: DaemonAPI.ForgeLead, title: String?) -> String {
        let state: String
        switch lead.state {
        case .starting: state = "starting"
        case .running: state = "working"
        case .waitingOnUser: state = "needs you"
        case .finished: state = "waiting"
        case .stopped: state = "stopped"
        case .queued: state = "queued"
        case .archived: state = "archived"
        }
        return "Lead: “\(title ?? lead.title ?? "A session")” (\(state))"
    }

    /// Start lead's form (the `lead` skill's "Starting a lead"): the issue's own first line, the
    /// skill and the epic's address, its labels and `lead`, and no worktree.
    public static func leadStart(_ start: DaemonAPI.ForgeStart, url: String?) -> DaemonAPI.ForgeStart {
        let first = start.prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? start.prompt
        let skill = "Lead this epic with the `lead` skill (`.agents/skills/lead/SKILL.md`)"
        let prompt = "\(first)\n\n\(skill)" + (url.map { ": \($0)" } ?? ".")
        return DaemonAPI.ForgeStart(prompt: prompt, labels: start.labels + (start.labels.contains("lead") ? [] : ["lead"]))
    }
}
