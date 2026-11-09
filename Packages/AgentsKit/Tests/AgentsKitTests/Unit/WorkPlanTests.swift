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

    @Test func whatWorksOnAChild() {
        #expect(WorkPlan.workWords(pr: pr(10), states: [.running]) == "● lane running · PR #10 open")
        #expect(WorkPlan.workWords(pr: pr(10, failed: 2), states: [.waitingOnUser, .running])
            == "● lane needs you · PR #10 open · 2 failed checks")
        #expect(WorkPlan.workWords(pr: pr(10, outcome: "merged"), states: [.finished]) == "PR #10 merged")
        #expect(WorkPlan.workWords(pr: nil, states: []) == nil)
    }

    @Test func aChildBlockedOutsideThePlanSaysByWhat() {
        #expect(WorkPlan.blockedWords(child(1, step: 1, outside: [17])) == "blocked by #17")
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
        #expect(words.hasPrefix("1/3 done · 1 running · "))
        #expect(words.hasSuffix("5.30"))
        #expect(WorkPlan.progressWords(plan, running: 0, rollups: []) == "1/3 done")
    }

    @Test func aStandingEpicsHeaderHasNoEnd() {
        let plan = DaemonAPI.ForgePlan(item: .init(node: issue(1), title: "Bug lane", state: "open", updatedAt: day),
                                       children: [child(2, step: 1), child(3, step: 1)], standing: .init(labels: ["bug"]))
        let words = WorkPlan.standingWords(plan, running: 1, rollups: [rollup(2, usd: 4.1)])
        #expect(words.hasPrefix("Standing · 1 running · 2 open · "))
        #expect(words.hasSuffix("4.10"))
        #expect(WorkPlan.standingWords(plan, running: 0, rollups: []) == "Standing · 2 open")
        let full = DaemonAPI.ForgePlan(item: plan.item, children: (2...101).map { child($0, step: 1) }, standing: plan.standing)
        #expect(WorkPlan.standingWords(full, running: 0, rollups: []) == "Standing · 100+ open")
        let bad = DaemonAPI.ForgePlan(item: plan.item, standing: .init(error: "no standing block"))
        #expect(WorkPlan.standingWords(bad, running: 0, rollups: []) == "Standing")
    }

    @Test func aStandingEpicsQueryInWords() {
        #expect(WorkPlan.queryWords(.init(labels: ["bug"], milestone: "none"))
            == "Open issues labelled bug · no milestone · 1 lane at a time")
        #expect(WorkPlan.queryWords(.init(any: ["polish", "competitor"], not: ["wontfix"], milestone: "1.0", lanes: 2))
            == "Open issues labelled polish or competitor · not wontfix · milestone “1.0” · 2 lanes at a time")
        #expect(WorkPlan.queryWords(.init(labels: ["ui"], any: ["bug", "polish"], milestone: "any"))
            == "Open issues labelled ui, and bug or polish · in a milestone · 1 lane at a time")
        #expect(WorkPlan.queryWords(.init()) == "Open issues · 1 lane at a time")
    }

    @Test func theLeadsWords() {
        let lead = DaemonAPI.ForgeLead(session: UUID(), title: "Work pages lead", state: .running)
        #expect(WorkPlan.leadWords(lead, title: nil) == "Lead: “Work pages lead” (working)")
        #expect(WorkPlan.leadWords(lead, title: "Renamed") == "Lead: “Renamed” (working)")
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
