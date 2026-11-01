import Foundation
import Testing
@testable import AgentsKitCore

/// Work's lists (#3119), as `Web/test/work.test.mjs` has them on the web page: one row per ref
/// from every machine, lineage on top, the filters and the sorts.
@Suite("Work list")
struct WorkListTests {
    typealias Node = DaemonAPI.LineageNode
    let day = Date(timeIntervalSince1970: 1_793_000_000)

    func item(_ n: Int, title: String? = nil, state: String = "open", labels: [DaemonAPI.ForgeLabel] = [],
              assignees: [String] = [], repo: String = "alexec/Agents", kind: String = "issue", at: Date? = nil) -> DaemonAPI.ForgeItem {
        .init(node: Node(kind: kind, ref: "github:\(repo)#\(n)"), title: title ?? "Issue \(n)", state: state, labels: labels,
              assignees: assignees, updatedAt: at ?? day)
    }

    static func cost(_ usd: Decimal) -> DaemonAPI.LineageCost { .init(cost: usd == 0 ? [:] : ["USD": usd], turns: 1) }

    func node(_ n: Int, _ usd: Decimal, waste: Decimal = 0, lead: Double? = nil) -> DaemonAPI.ReportNode {
        .init(node: Node(kind: "issue", ref: "github:alexec/Agents#\(n)"),
              cost: .init(own: Self.cost(usd), total: Self.cost(usd), waste: Self.cost(waste)), sessions: 2,
              leadTimeSeconds: lead, lastAt: day)
    }

    @Test func oneRowPerRefTheLastUpdatedCopyWithItsLineage() {
        let rows = WorkList.merge([
            (host: .mac, items: [item(1), item(2, title: "Old")]),
            (host: MachineRef(rawValue: "box"), items: [item(2, title: "New", at: day.addingTimeInterval(3600))]),
        ], lineage: [node(2, 4.1)])
        #expect(rows.count == 2)
        let two = rows.first { $0.node.ref.hasSuffix("#2") }
        #expect(two?.title == "New")
        #expect(two?.host?.rawValue == "box")
        #expect(two?.lineage?.sessions == 2)
        #expect(rows.first { $0.node.ref.hasSuffix("#1") }?.lineage == nil)
    }

    @Test func aRowsLineageInWordsNoneWithout() {
        #expect(WorkList.lineageWords(nil) == nil)
        let words = WorkList.lineageWords(node(2, 4.1, waste: 0.6, lead: 86_400 + 4 * 3600))
        #expect(words?.hasPrefix("2 sessions · ") == true)
        #expect(words?.contains("waste ") == true)
        #expect(words?.hasSuffix("lead time 1d 4h") == true)
        var quiet = node(3, 0)
        quiet.sessions = 0
        #expect(WorkList.lineageWords(quiet) == nil)
    }

    @Test func filtersStateRepoLabelAssigneeAndWords() {
        let rows = WorkList.merge([(host: .mac, items: [
            item(1, labels: [.init(name: "bug", color: "d73a4a")], assignees: ["alexec"]),
            item(2, title: "Flaky test", state: "closed"),
            item(3, repo: "alexec/Other"),
        ])], lineage: [])
        func f(_ filter: WorkList.Filter) -> [Int] {
            WorkList.sort(WorkList.filter(rows, filter), by: .newest).map { WorkList.number($0.node.ref) }
        }
        #expect(f(.init()) == [3, 1])
        #expect(f(.init(state: .closed)) == [2])
        #expect(f(.init(state: .all, repo: "github:alexec/Other")) == [3])
        #expect(f(.init(label: "bug")) == [1])
        #expect(f(.init(assignee: "alexec")) == [1])
        #expect(f(.init(state: .all, text: "flaky")) == [2])
        #expect(WorkList.choices(rows).repos == ["github:alexec/Agents", "github:alexec/Other"])
    }

    @Test func aMergedPullRequestIsMergedNotClosed() {
        let pr = WorkList.Row(item(5, state: "merged", kind: "pr"), on: .mac)
        #expect(WorkList.matches(pr, state: .merged))
        #expect(!WorkList.matches(pr, state: .closed))
    }

    @Test func sortsUpdatedNewestAndCostWithNoLineageLast() {
        let rows = WorkList.merge([(host: .mac, items: [
            item(1, at: day.addingTimeInterval(86_400)), item(9), item(4, at: day.addingTimeInterval(-86_400)),
        ])], lineage: [node(4, 5), node(9, 1)])
        func order(_ s: WorkList.Sort) -> [Int] { WorkList.sort(rows, by: s).map { WorkList.number($0.node.ref) } }
        #expect(order(.updated) == [1, 9, 4])
        #expect(order(.newest) == [9, 4, 1])
        #expect(order(.cost) == [4, 9, 1])
    }

    @Test func refsRepoShortNameAndForge() {
        #expect(WorkList.repo(of: "github:alexec/Agents#12") == "github:alexec/Agents")
        #expect(WorkList.repo(of: "gitlab:group/repo!45") == "gitlab:group/repo")
        #expect(WorkList.repo(of: "linear:ENG-4") == "linear")
        #expect(WorkList.repo(of: "github:alexec/Agents/milestone/15") == "github:alexec/Agents")
        #expect(WorkList.shortRef("github:alexec/Agents#12") == "#12")
        #expect(WorkList.shortRef("linear:ENG-4") == "ENG-4")
        #expect(WorkList.openOnWords("gitlab:g/r!4") == "Open on GitLab")
    }

    @Test func aMilestoneLineageAloneKnows() {
        var n = node(0, 2)
        n.node = Node(kind: "milestone", ref: "github:alexec/Agents/milestone/15")
        n.resolved = .init(title: "0.14 Lineage")
        let row = WorkList.Row(n)
        #expect(row.title == "0.14 Lineage")
        #expect(row.url?.absoluteString == "https://github.com/alexec/Agents/milestone/15")
    }

    @Test func aLabelsInkReadsOnItsColour() {
        #expect(WorkList.isLight("ffffff"))
        #expect(!WorkList.isLight("#0e1f8a"))
        #expect(WorkList.rgb(nil) == nil)
    }
}

/// The page of one item (#3119), as `Web/test/work.test.mjs` has it.
@Suite("Work page")
struct WorkPageTests {
    typealias Node = DaemonAPI.LineageNode
    let issue = Node(kind: "issue", ref: "github:alexec/Agents#12")
    let pr = Node(kind: "pr", ref: "github:alexec/Agents#34")
    let milestone = Node(kind: "milestone", ref: "github:alexec/Agents/milestone/15")
    let session = Node(kind: "session", ref: "session:S1")
    let at = Date(timeIntervalSince1970: 0)

    @Test func linksByRelationFromItsOwnSideEachNodeOnce() throws {
        let links: [DaemonAPI.LineageLink] = [
            .init(from: session, to: issue, rel: "works-on", source: "branch", at: at, endedAt: at),
            .init(from: session, to: issue, rel: "works-on", source: "start", at: at),
            .init(from: pr, to: issue, rel: "fixes", source: "pr-body", at: at),
            .init(from: issue, to: milestone, rel: "part-of", source: "forge", at: at),
            .init(from: pr, to: milestone, rel: "part-of", source: "forge", at: at),
        ]
        let groups = WorkList.linkGroups(issue, links)
        try #require(groups.map(\.title) == ["Fixed by", "Part of", "Worked on by"])
        #expect(groups[2].rows.count == 1) // index-ok: the #require above
        #expect(groups[2].rows.first?.ended == false) // index-ok: the #require above
        #expect(WorkList.linkGroups(pr, links).map(\.title) == ["Fixes", "Part of"])
        #expect(WorkList.kind(of: milestone) == .milestone)
        #expect(WorkList.kind(of: session) == nil)
    }

    @Test func checksReviewCostAndPeopleInWords() {
        let checks: [DaemonAPI.ForgeCheck] = [.init(name: "a", state: "passing"), .init(name: "b", state: "passing"),
                                              .init(name: "c", state: "failing")]
        #expect(WorkList.checksWords(checks) == "Checks: 2 passing, 1 failing")
        #expect(WorkList.checksWords([], summary: "none") == nil)
        #expect(WorkList.reviewWords("changes_requested") == "Review: Changes requested")
        let item = DaemonAPI.ForgeItem(node: pr, title: "T", state: "open", author: "alexec", assignees: ["bob"],
                                       milestone: "0.14", updatedAt: at)
        #expect(WorkList.peopleWords(item) == "by alexec · assigned to bob · milestone 0.14")
        let none = DaemonAPI.LineageCostRollup(node: pr)
        #expect(WorkList.pageCostWords(none) == nil)
    }

    @Test func aPlaceIsAListOrAPage() {
        #expect(WorkPlace(kind: .pr).node == nil)
        #expect(WorkPlace(kind: .pr, ref: pr.ref).node == pr)
    }
}
