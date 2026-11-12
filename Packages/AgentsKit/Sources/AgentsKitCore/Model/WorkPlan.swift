import Foundation

/// The Plan section on an epic's Work page (#3268, spec 3265), as the web page's `model/epicPlan.ts`:
/// its children step by step (`forge/plan`), each with a mark, the PR and the sessions that work on
/// it (from lineage, `lineage/cost`'s parts) and its cost; a header with the lead, the children
/// done and running, and the total cost; and the new-session form that Start lead fills in.
public enum WorkPlan {
    /// A child's mark: closed; a lane runs or a PR is open; a question waits or a check failed;
    /// waiting for its step; blocked by an open issue outside the plan. In the Work look (#4416)
    /// it is a glyph in colour before line 2's words; the state icon says open or closed.
    public enum Mark: String, Sendable, CaseIterable {
        case done
        case working
        case attention
        case waiting
        case blocked

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

    /// A child's line 2 after its number (#4416, epic.md note 7): what works on it, by its mark.
    /// *Working · “Work look: epic page”* (the lane's title), *Working · P#4411 open*, *Needs you ·
    /// its lane asks a question*, *Needs you · 1 failed check*, *Waiting for #4329*, *Blocked by
    /// #4100, outside the plan*, *merged P#4390 · 6 h ago*; nil for an open child with nothing on it.
    public static func lineWords(_ child: DaemonAPI.ForgePlanChild, mark: Mark, pr: DaemonAPI.LineageCostNode?,
                                 states: [AgentState], lane: String?, in plan: DaemonAPI.ForgePlan,
                                 now: Date = Date()) -> String? {
        let prRef = pr.map { "P" + WorkList.shortRef($0.node.ref) }
        switch mark {
        case .done:
            guard let pr, let prRef, let outcome = pr.outcome else { return nil }
            let age = WorkLook.ageWords(now.timeIntervalSince(pr.lastAt))
            return "\(outcome) \(prRef) · \(age == "now" ? "now" : "\(age) ago")"
        case .attention:
            if states.contains(.waitingOnUser) { return "Needs you · its lane asks a question" }
            let failed = pr?.failedChecks ?? 0
            return "Needs you · \(failed == 1 ? "1 failed check" : "\(failed) failed checks")"
        case .working:
            if states.contains(where: \.holdsRuntime), let lane { return "Working · “\(lane)”" }
            return ["Working", prRef.map { "\($0) open" }].compactMap { $0 }.joined(separator: " · ")
        case .blocked:
            return blockedWords(child)
        case .waiting:
            let open = Set(plan.children.filter { $0.item.state != "closed" }.map(\.item.node))
            let waits = child.blockedBy.filter { open.contains($0) }
            guard !waits.isEmpty else { return nil }
            return "Waiting for \(waits.map { WorkList.shortRef($0.ref) }.joined(separator: ", "))"
        }
    }

    /// A child's line 2 on a phone (#4417, epic.md note 15): the words up to their first " · ",
    /// *Working*, *Needs you*, *merged P#4390*, *Waiting for #4329*, *Blocked by #4100*.
    public static func phoneWords(_ words: String?) -> String? {
        guard let words else { return nil }
        let head = words.components(separatedBy: " · ")[0]
        return head.hasSuffix(", outside the plan") ? String(head.dropLast(", outside the plan".count)) : head
    }

    /// The open issues outside the plan that block a child: "Blocked by #17, outside the plan"; nil with none.
    public static func blockedWords(_ child: DaemonAPI.ForgePlanChild) -> String? {
        guard child.item.state != "closed", let outside = child.blockedOutside, !outside.isEmpty else { return nil }
        return "Blocked by \(outside.map { WorkList.shortRef($0.ref) }.joined(separator: ", ")), outside the plan"
    }

    /// An open child's estimate on its row, with no cost yet: "~$0.60", else "~2h 10m"; nil with no figures.
    public static func estimateWords(_ e: DaemonAPI.LineageEstimate) -> String? {
        if let money = moneyWords(e.cost.map { $0.mapValues(\.median) } ?? [:]) { return "~" + money }
        return e.workingSeconds.map { "~" + TimeChart.words($0.median) }
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

    /// The header's figures (epic.md note 3): "4 of 9 done · 2 running · $3.09 spent · about
    /// $4.70 to go". To go is the open children's estimates added up; it goes with none.
    public static func progressWords(_ plan: DaemonAPI.ForgePlan, running: Int,
                                     rollups: [DaemonAPI.LineageCostRollup],
                                     estimates: [DaemonAPI.LineageEstimate] = []) -> String {
        let done = plan.children.filter { $0.item.state == "closed" }.count
        var parts = ["\(done) of \(plan.children.count) done"]
        if running > 0 { parts.append("\(running) running") }
        let total = sum(rollups.map(\.total))
        if ReportValueWords.spent(total) { parts.append("\(ReportValueWords.cost(total)) spent") }
        let open = Set(plan.children.filter { $0.item.state != "closed" }.map(\.item.node))
        var toGo: [String: Double] = [:]
        for e in estimates where open.contains(e.node) {
            for (currency, range) in e.cost ?? [:] { toGo[currency, default: 0] += range.median }
        }
        if let money = moneyWords(toGo) { parts.append("about \(money) to go") }
        return parts.joined(separator: " · ")
    }

    /// A standing epic's header figures (#3662, epic.md note 17), with no end: "14 open · 1 running
    /// · $6.40 spent". The daemon reads at most 100 issues, so 100 is "100+ open"; a query with an
    /// error counts none.
    public static func standingWords(_ plan: DaemonAPI.ForgePlan, running: Int,
                                     rollups: [DaemonAPI.LineageCostRollup]) -> String {
        var parts: [String] = []
        let open = plan.children.filter { $0.item.state != "closed" }.count
        if plan.standing?.error == nil { parts.append(open >= standingLimit ? "\(standingLimit)+ open" : "\(open) open") }
        if running > 0 { parts.append("\(running) running") }
        let total = sum(rollups.map(\.total))
        if ReportValueWords.spent(total) { parts.append("\(ReportValueWords.cost(total)) spent") }
        return parts.joined(separator: " · ")
    }

    /// The share of the plan's bar (epic.md note 3): done (purple), running (green); the rest is grey.
    public static func bar(_ plan: DaemonAPI.ForgePlan, running: Int) -> (done: Double, running: Double) {
        let total = plan.children.count
        guard total > 0 else { return (0, 0) }
        let done = plan.children.filter { $0.item.state == "closed" }.count
        return (Double(done) / Double(total), Double(min(running, total - done)) / Double(total))
    }

    /// A step's band at its trailing end (epic.md note 5): "3 of 5 done"; a step that is all
    /// done adds what it cost, "1 of 1 done · $0.90".
    public static func stepWords(_ step: DaemonAPI.ForgePlanStep, in plan: DaemonAPI.ForgePlan,
                                 rollups: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup]) -> String {
        let children = plan.children.filter { $0.step == step.step }
        let done = children.filter { $0.item.state == "closed" }.count
        var words = "\(done) of \(children.count) done"
        if done == children.count {
            let total = sum(children.compactMap { rollups[$0.item.node]?.total })
            if ReportValueWords.spent(total) { words += " · \(ReportValueWords.cost(total))" }
        }
        return words
    }

    /// A step whose children are all closed starts folded (epic.md note 5).
    public static func startsFolded(_ step: DaemonAPI.ForgePlanStep, in plan: DaemonAPI.ForgePlan) -> Bool {
        let children = plan.children.filter { $0.step == step.step }
        return !children.isEmpty && children.allSatisfy { $0.item.state == "closed" }
    }

    /// The rows a standing epic shows before *9 more* (epic.md note 18).
    public static let standingShown = 10

    /// *9 more*: the rows of a standing epic's list past the first ten; nil with none.
    public static func moreWords(_ count: Int) -> String? {
        count > standingShown ? "\(count - standingShown) more" : nil
    }

    /// A child's `priority:` label, for a standing epic's row (epic.md note 18).
    public static func priority(_ item: DaemonAPI.ForgeItem) -> DaemonAPI.ForgeLabel? {
        item.labels.first { $0.name.lowercased().hasPrefix("priority:") }
    }

    /// The most issues `forge/plan` reads for a standing epic's query.
    static let standingLimit = 100

    /// A standing epic's query in words (#3662): "Open issues labelled bug · no milestone · 1 lane at a time".
    public static func queryWords(_ standing: DaemonAPI.ForgeStanding) -> String {
        var parts: [String] = []
        var first = "Open issues"
        if !standing.labels.isEmpty { first += " labelled \(standing.labels.joined(separator: " and "))" }
        if !standing.any.isEmpty {
            first += standing.labels.isEmpty ? " labelled " : ", and "
            first += standing.any.joined(separator: " or ")
        }
        parts.append(first)
        if !standing.not.isEmpty { parts.append("not \(standing.not.joined(separator: " or "))") }
        switch standing.milestone?.lowercased() {
        case nil, "": break
        case "none": parts.append("no milestone")
        case "any": parts.append("in a milestone")
        default: parts.append("milestone “\(standing.milestone ?? "")”")
        }
        if standing.parent?.lowercased() == "none" { parts.append("no parent") }
        parts.append(standing.lanes == 1 ? "1 lane at a time" : "\(standing.lanes) lanes at a time")
        return parts.joined(separator: " · ")
    }

    /// A standing epic's query after its labels, which show as chips (epic.md note 17): "· no
    /// milestone · no parent · 1 lane at a time", "· or polish, competitor · not wontfix · 2 lanes at a time".
    public static func queryRestWords(_ standing: DaemonAPI.ForgeStanding) -> String {
        var parts: [String] = []
        if !standing.any.isEmpty { parts.append((standing.labels.isEmpty ? "" : "and ") + standing.any.joined(separator: " or ")) }
        let words = queryWords(standing)
        // The words after the first part, the labels' (milestone, lanes and not), as queryWords says them.
        parts += words.components(separatedBy: " · ").dropFirst()
        return parts.map { "· " + $0 }.joined(separator: " ")
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

    /// The lead's state in words (epic.md note 4): working, needs you, waiting, stopped.
    public static func leadWords(_ state: AgentState) -> String {
        switch state {
        case .starting: return "starting"
        case .running: return "working"
        case .waitingOnUser: return "needs you"
        case .finished: return "waiting"
        case .stopped: return "stopped"
        case .queued: return "queued"
        case .archived: return "archived"
        }
    }

    /// Money per currency: "$4.70", "$4.70 + €1.00"; nil with none.
    static func moneyWords(_ cost: [String: Double]) -> String? {
        let priced = cost.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        guard !priced.isEmpty else { return nil }
        return priced.map { $0.value.formatted(.currency(code: $0.key).precision(.fractionLength(2))) }.joined(separator: " + ")
    }

    // MARK: Changing the plan (#3271)

    /// The levels a new child can have, as Add child's menu offers them; "" is none.
    public static let childLevels = ["story", "task", "spike", "bug", ""]

    /// Whether Add child's words name an issue that is there, not a new one's title: #12,
    /// owner/repo#12, an issue's URL, or a key such as ENG-4.
    public static func namesIssue(_ words: String) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.range(of: #"^([\w.-]+/[\w.-]+)?#[0-9]+$|^https?://\S+$|^[A-Za-z][A-Za-z0-9]{0,9}-[0-9]+$"#,
                          options: .regularExpression) != nil
    }

    /// Add child's request: the issue the words name, or a new child with them as its title.
    public static func addChild(_ epic: DaemonAPI.LineageNode, words: String, level: String) -> DaemonAPI.ForgeAddChildRequest {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if namesIssue(text) { return DaemonAPI.ForgeAddChildRequest(node: epic, issue: text) }
        return DaemonAPI.ForgeAddChildRequest(node: epic, title: text, level: level.isEmpty ? nil : level)
    }

    /// The children a child can be blocked by: the plan's others, each with whether it is now.
    public static func blockerChoices(_ child: DaemonAPI.ForgePlanChild, in plan: DaemonAPI.ForgePlan)
        -> [(child: DaemonAPI.ForgePlanChild, on: Bool)] {
        plan.children.filter { $0.item.node != child.item.node }.map { ($0, child.blockedBy.contains($0.item.node)) }
    }

    /// Blocked by's request: the other child added as a blocker, or taken off.
    public static func blockedBy(_ child: DaemonAPI.ForgePlanChild, _ blocker: DaemonAPI.LineageNode, on: Bool)
        -> DaemonAPI.ForgeBlockedByRequest {
        on ? DaemonAPI.ForgeBlockedByRequest(node: child.item.node, add: [blocker])
            : DaemonAPI.ForgeBlockedByRequest(node: child.item.node, remove: [blocker])
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
