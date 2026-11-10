import Foundation
import Testing
@testable import AgentsKitCore

/// The Plan section on an epic's page (#3268), as `Web/test/epic-plan.test.mjs` has it on the web page.
@Suite("Work plan")
struct WorkPlanTests {
    typealias Node = DaemonAPI.LineageNode
    let day = Date(timeIntervalSince1970: 1_793_000_000)

    func issue(_ n: Int) -> Node { Node(kind: "issue", ref: "github:alexec/Agents#\(n)") }

    func child(_ n: Int, step: Int, state: String = "open", blockedBy: [Int] = [], outside: [Int]? = nil) -> DaemonAPI.ForgePlanChild {
        .init(item: .init(node: issue(n), title: "Issue \(n)", state: state, updatedAt: day),
              blockedBy: blockedBy.map(issue), blockedOutside: outside?.map(issue), step: step)
    }

    func pr(_ n: Int, outcome: String? = nil, failed: Int? = nil, at: TimeInterval = 0, sessions: [UUID] = []) -> DaemonAPI.LineageCostNode {
        .init(node: Node(kind: "pr", ref: "github:alexec/Agents#\(n)"), banked: .init(), fixes: nil, outcome: outcome,
              failedChecks: failed, lastAt: day.addingTimeInterval(at), sessions: sessions.map { "session:\($0.uuidString)" })
    }

    func rollup(_ n: Int, usd: Decimal = 0, parts: [DaemonAPI.LineageCostNode] = []) -> DaemonAPI.LineageCostRollup {
        .init(node: issue(n), total: .init(cost: usd == 0 ? [:] : ["USD": usd]), parts: parts)
    }

    @Test func anIssueWithSubIssuesOrLabelledEpicHasAPlan() {
        var item = DaemonAPI.ForgeItem(node: issue(1), title: "Epic", state: "open", updatedAt: day)
        #expect(!WorkPlan.hasPlan(item))
        item.progress = .init(done: 0, total: 2)
        #expect(WorkPlan.hasPlan(item))
        item.progress = nil
        item.level = "epic"
        #expect(WorkPlan.hasPlan(item))
        item.node = Node(kind: "pr", ref: "github:alexec/Agents#1")
        #expect(!WorkPlan.hasPlan(item))
    }

    @Test func thePROfAChildIsAnOpenOneFirstElseTheNewest() {
        let r = rollup(2, parts: [pr(10, outcome: "merged", at: 50), pr(11, at: 0), pr(12, outcome: "closed", at: 100)])
        #expect(WorkPlan.pr(r)?.node.ref == "github:alexec/Agents#11")
        let ended = rollup(2, parts: [pr(10, outcome: "merged", at: 50), pr(12, outcome: "closed", at: 100)])
        #expect(WorkPlan.pr(ended)?.node.ref == "github:alexec/Agents#12")
        #expect(WorkPlan.pr(rollup(2)) == nil)
    }

    @Test func theSessionsOfAChildAreItsLinksThenItsCostsEachOnce() {
        let a = UUID(), b = UUID(), c = UUID()
        let link = DaemonAPI.LineageLink(from: Node(kind: "session", ref: "session:\(c.uuidString)"), to: issue(2), rel: "works-on",
                                         source: "label", at: day)
        let other = DaemonAPI.LineageLink(from: Node(kind: "session", ref: "session:\(UUID().uuidString)"), to: issue(3),
                                          rel: "works-on", source: "label", at: day)
        #expect(WorkPlan.sessions(issue(2), links: [link, other], rollup: rollup(2, parts: [pr(10, sessions: [a, b]), pr(11, sessions: [a])]))
            == [c, a, b])
        #expect(WorkPlan.sessions(issue(2), rollup: nil).isEmpty)
    }

    @Test func theMarks() {
        #expect(WorkPlan.mark(child(1, step: 1, state: "closed"), pr: nil, states: [.running]) == .done)
        #expect(WorkPlan.mark(child(1, step: 1), pr: nil, states: [.waitingOnUser]) == .attention)
        #expect(WorkPlan.mark(child(1, step: 1), pr: pr(10, failed: 1), states: []) == .attention)
        #expect(WorkPlan.mark(child(1, step: 1), pr: pr(10), states: []) == .working)
        #expect(WorkPlan.mark(child(1, step: 1), pr: nil, states: [.running]) == .working)
        #expect(WorkPlan.mark(child(1, step: 1, outside: [99]), pr: nil, states: [.finished]) == .blocked)
        #expect(WorkPlan.mark(child(1, step: 2), pr: pr(10, outcome: "closed"), states: [.stopped]) == .waiting)
    }

    @Test func aChildsLineSaysWhatWorksOnIt() {
        let plan = DaemonAPI.ForgePlan(item: .init(node: issue(1), title: "Epic", state: "open", updatedAt: day), children: [
            child(2, step: 1, state: "closed"), child(3, step: 1), child(4, step: 2, blockedBy: [2, 3]),
        ])
        func line(_ c: DaemonAPI.ForgePlanChild, pr: DaemonAPI.LineageCostNode? = nil, states: [AgentState] = [],
                  lane: String? = nil) -> String? {
            WorkPlan.lineWords(c, mark: WorkPlan.mark(c, pr: pr, states: states), pr: pr, states: states, lane: lane, in: plan,
                               now: day.addingTimeInterval(6 * 3600))
        }
        #expect(line(child(3, step: 1), states: [.running], lane: "Work look: epic page") == "Working · “Work look: epic page”")
        #expect(line(child(3, step: 1), pr: pr(11)) == "Working · P#11 open")
        #expect(line(child(3, step: 1), pr: pr(11), states: [.waitingOnUser]) == "Needs you · its lane asks a question")
        #expect(line(child(3, step: 1), pr: pr(11, failed: 1)) == "Needs you · 1 failed check")
        #expect(line(child(3, step: 1), pr: pr(11, failed: 2)) == "Needs you · 2 failed checks")
        #expect(line(child(4, step: 2, blockedBy: [2, 3])) == "Waiting for #3")
        #expect(line(child(4, step: 2, blockedBy: [2])) == nil)
        #expect(line(child(5, step: 1, outside: [100])) == "Blocked by #100, outside the plan")
        #expect(line(child(2, step: 1, state: "closed"), pr: pr(10, outcome: "merged")) == "merged P#10 · 6 h ago")
        #expect(line(child(2, step: 1, state: "closed")) == nil)
    }

    @Test func anOpenChildsEstimateIsShort() {
        var e = DaemonAPI.LineageEstimate(node: issue(2), matchedBy: "level", matches: 3)
        #expect(WorkPlan.estimateWords(e) == nil)
        e.workingSeconds = .init(median: 7200, p10: 3600, p90: 9000)
        #expect(WorkPlan.estimateWords(e)?.hasPrefix("~") == true)
        e.cost = ["USD": .init(median: 0.6, p10: 0.2, p90: 1)]
        #expect(WorkPlan.estimateWords(e) == "~$0.60")
    }

    @Test func aChildBlockedOutsideThePlanSaysByWhat() {
        #expect(WorkPlan.blockedWords(child(1, step: 1, outside: [17])) == "Blocked by #17, outside the plan")
        #expect(WorkPlan.blockedWords(child(1, step: 1, state: "closed", outside: [17])) == nil)
        #expect(WorkPlan.blockedWords(child(1, step: 1)) == nil)
    }

    @Test func aStepSaysTheOpenChildrenItWaitsFor() throws {
        let plan = DaemonAPI.ForgePlan(item: .init(node: issue(1), title: "Epic", state: "open", updatedAt: day), children: [
            child(2, step: 1, state: "closed"), child(3, step: 1),
            child(4, step: 2, blockedBy: [2, 3]), child(5, step: 2, blockedBy: [3]),
        ], steps: [.init(step: 1, nodes: [issue(2), issue(3)]), .init(step: 2, nodes: [issue(4), issue(5)])])
        let first = try #require(plan.steps.first), second = try #require(plan.steps.last)
        #expect(WorkPlan.stepTitle(first, in: plan) == "Step 1")
        #expect(WorkPlan.stepTitle(second, in: plan) == "Step 2 · waits for #3")
    }

    @Test func theHeaderCountsAndAddsUp() {
        let plan = DaemonAPI.ForgePlan(item: .init(node: issue(1), title: "Epic", state: "open", updatedAt: day), children: [
            child(2, step: 1, state: "closed"), child(3, step: 1), child(4, step: 2),
        ])
        let words = WorkPlan.progressWords(plan, running: 1, rollups: [rollup(2, usd: 4.1), rollup(3, usd: 1.2)])
        #expect(words.hasPrefix("1 of 3 done · 1 running · "))
        #expect(words.hasSuffix("5.30 spent"))
        #expect(WorkPlan.progressWords(plan, running: 0, rollups: []) == "1 of 3 done")
        func estimate(_ n: Int, _ usd: Double) -> DaemonAPI.LineageEstimate {
            var e = DaemonAPI.LineageEstimate(node: issue(n), matchedBy: "level", matches: 3)
            e.cost = ["USD": .init(median: usd, p10: usd / 2, p90: usd * 2)]
            return e
        }
        // A closed child's estimate is not to go.
        #expect(WorkPlan.progressWords(plan, running: 0, rollups: [], estimates: [estimate(2, 9), estimate(3, 1.5), estimate(4, 3.2)])
            == "1 of 3 done · about $4.70 to go")
        let bar = WorkPlan.bar(plan, running: 1)
        #expect(bar.done == 1.0 / 3 && bar.running == 1.0 / 3)
        #expect(WorkPlan.bar(.init(item: plan.item), running: 0) == (0, 0))
    }

    @Test func aStepSaysItsCountsAndFoldsWhenDone() throws {
        let plan = DaemonAPI.ForgePlan(item: .init(node: issue(1), title: "Epic", state: "open", updatedAt: day), children: [
            child(2, step: 1, state: "closed"), child(3, step: 2, state: "closed"), child(4, step: 2),
        ], steps: [.init(step: 1, nodes: [issue(2)]), .init(step: 2, nodes: [issue(3), issue(4)])])
        let first = try #require(plan.steps.first), second = try #require(plan.steps.last)
        #expect(WorkPlan.startsFolded(first, in: plan))
        #expect(!WorkPlan.startsFolded(second, in: plan))
        #expect(WorkPlan.stepWords(first, in: plan, rollups: [issue(2): rollup(2, usd: 0.9)]) == "1 of 1 done · $0.90")
        #expect(WorkPlan.stepWords(first, in: plan, rollups: [:]) == "1 of 1 done")
        #expect(WorkPlan.stepWords(second, in: plan, rollups: [issue(3): rollup(3, usd: 0.9)]) == "1 of 2 done")
    }

    @Test func aStandingEpicsHeaderHasNoEnd() {
        let plan = DaemonAPI.ForgePlan(item: .init(node: issue(1), title: "Bug lane", state: "open", updatedAt: day),
                                       children: [child(2, step: 1), child(3, step: 1)], standing: .init(labels: ["bug"]))
        let words = WorkPlan.standingWords(plan, running: 1, rollups: [rollup(2, usd: 4.1)])
        #expect(words.hasPrefix("2 open · 1 running · "))
        #expect(words.hasSuffix("4.10 spent"))
        #expect(WorkPlan.standingWords(plan, running: 0, rollups: []) == "2 open")
        let full = DaemonAPI.ForgePlan(item: plan.item, children: (2...101).map { child($0, step: 1) }, standing: plan.standing)
        #expect(WorkPlan.standingWords(full, running: 0, rollups: []) == "100+ open")
        let bad = DaemonAPI.ForgePlan(item: plan.item, standing: .init(error: "no standing block"))
        #expect(WorkPlan.standingWords(bad, running: 0, rollups: []) == "")
        #expect(WorkPlan.moreWords(19) == "9 more")
        #expect(WorkPlan.moreWords(10) == nil)
    }

    @Test func aStandingEpicsQueryInWords() {
        #expect(WorkPlan.queryWords(.init(labels: ["bug"], milestone: "none"))
            == "Open issues labelled bug · no milestone · 1 lane at a time")
        #expect(WorkPlan.queryWords(.init(any: ["polish", "competitor"], not: ["wontfix"], milestone: "1.0", lanes: 2))
            == "Open issues labelled polish or competitor · not wontfix · milestone “1.0” · 2 lanes at a time")
        #expect(WorkPlan.queryWords(.init(labels: ["ui"], any: ["bug", "polish"], milestone: "any"))
            == "Open issues labelled ui, and bug or polish · in a milestone · 1 lane at a time")
        #expect(WorkPlan.queryWords(.init()) == "Open issues · 1 lane at a time")
        #expect(WorkPlan.queryRestWords(.init(labels: ["bug"], milestone: "none")) == "· no milestone · 1 lane at a time")
        #expect(WorkPlan.queryRestWords(.init(any: ["polish", "competitor"], not: ["wontfix"], lanes: 2))
            == "· polish or competitor · not wontfix · 2 lanes at a time")
    }

    @Test func theLeadsWords() {
        #expect(WorkPlan.leadWords(.running) == "working")
        #expect(WorkPlan.leadWords(.waitingOnUser) == "needs you")
        #expect(WorkPlan.leadWords(.finished) == "waiting")
        #expect(WorkPlan.leadWords(.stopped) == "stopped")
    }

    @Test func startLeadFillsTheLeadSkillsForm() {
        let start = DaemonAPI.ForgeStart(prompt: "#3100: Work pages\n\nWork on this GitHub issue.", labels: ["#3100"],
                                         worktree: "3100 Work pages")
        let lead = WorkPlan.leadStart(start, url: "https://github.com/alexec/Agents/issues/3100")
        #expect(lead.prompt == """
            #3100: Work pages

            Lead this epic with the `lead` skill (`.agents/skills/lead/SKILL.md`): https://github.com/alexec/Agents/issues/3100
            """)
        #expect(lead.labels == ["#3100", "lead"])
        #expect(lead.worktree == nil)
    }

    // MARK: Changing the plan (#3271)

    @Test func addChildNamesAnIssueThereOrOpensANewOne() {
        for there in ["#12", " alexec/Agents#12 ", "https://github.com/alexec/Agents/issues/12", "ENG-4"] {
            #expect(WorkPlan.namesIssue(there), "\(there)")
            #expect(WorkPlan.addChild(issue(1), words: there, level: "task") ==
                .init(node: issue(1), issue: there.trimmingCharacters(in: .whitespaces)))
        }
        for title in ["Retire the rows", "Fix #12 in the list", "ENG-4 follow-up"] {
            #expect(!WorkPlan.namesIssue(title), "\(title)")
        }
        #expect(WorkPlan.addChild(issue(1), words: " Retire the rows ", level: "story") ==
            .init(node: issue(1), title: "Retire the rows", level: "story"))
        #expect(WorkPlan.addChild(issue(1), words: "Retire", level: "").level == nil)
    }

    @Test func blockedByOffersTheOtherChildrenWithATickOnTheBlockers() {
        let fourth = child(4, step: 2, blockedBy: [2])
        let plan = DaemonAPI.ForgePlan(item: .init(node: issue(1), title: "Epic", state: "open", updatedAt: day),
                                       children: [child(2, step: 1), child(3, step: 1), fourth], steps: [])
        let choices = WorkPlan.blockerChoices(fourth, in: plan)
        #expect(choices.map(\.child.item.node) == [issue(2), issue(3)])
        #expect(choices.map(\.on) == [true, false])
        #expect(WorkPlan.blockedBy(fourth, issue(3), on: true) == .init(node: issue(4), add: [issue(3)]))
        #expect(WorkPlan.blockedBy(fourth, issue(2), on: false) == .init(node: issue(4), remove: [issue(2)]))
    }
}
