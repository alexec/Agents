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

    @Test func aJiraIssuesRowHasItsStatusAndTheTrackerJira() {
        let row = WorkList.Row(.init(node: Node(kind: "issue", ref: "jira:PROJ-7"), title: "Export", state: "open", updatedAt: day,
                                     status: "In Review"), on: .mac)
        #expect(row.status == "In Review")
        #expect(row.state == "open")
        #expect(row.repo == "jira")
        #expect(WorkList.repoName(row.repo) == "Jira")
        #expect(WorkList.repoName("github:alexec/Agents") == "alexec/Agents")
    }

    @Test func anAzureBoardsWorkItemsRowHasItsStatesNameItsProjectAndOpenOnAzureBoards() {
        let row = WorkList.Row(.init(node: Node(kind: "issue", ref: "azureboards:acme/web app#12"), title: "Export", state: "open",
                                     updatedAt: day, status: "Active"), on: .mac)
        #expect(row.status == "Active")
        #expect(row.repo == "azureboards:acme/web app")
        #expect(WorkList.repoName(row.repo) == "Azure Boards · acme/web app")
        #expect(WorkList.shortRef(row.node.ref) == "#12")
        #expect(WorkList.openOnWords(row.node.ref) == "Open on Azure Boards")
    }

    @Test func aForgejoPullRequestsRowHasItsRepoAndOpenOnForgejo() {
        let row = WorkList.Row(.init(node: Node(kind: "pr", ref: "forgejo:walkalex/app#8"), title: "Add hello", state: "open",
                                     updatedAt: day), on: .mac)
        #expect(row.repo == "forgejo:walkalex/app")
        #expect(WorkList.repoName(row.repo) == "walkalex/app")
        #expect(WorkList.shortRef(row.node.ref) == "#8")
        #expect(WorkList.openOnWords(row.node.ref) == "Open on Forgejo")
        #expect(WorkList.forgeName("bitbucket:a/b#1") == "the forge")
        #expect(WorkList.failureWords(JSONRPCError(code: -32602, message: "forge/rerun: open the check on Forgejo")) ==
            "forge/rerun: open the check on Forgejo")
        #expect(WorkList.errorWords(.init(forge: "forgejo", message: "not connected"), machine: "Studio") == "Forgejo on Studio: not connected")
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

    /// #3282: each machine's boards once by url, the first name kept; a board's name in the menu.
    @Test func boardsAreMergedByURL() {
        let web = DaemonAPI.ProjectBoard(name: "Web", url: "https://github.com/orgs/acme/projects/7")
        let renamed = DaemonAPI.ProjectBoard(name: "Web team", url: web.url)
        let plat = DaemonAPI.ProjectBoard(name: "Platform", url: "https://linear.app/acme/team/PLAT")
        let merged = WorkList.mergeBoards([[web], [renamed, plat]])
        #expect(merged.map(\.name) == ["Web", "Platform"])
        #expect(WorkList.boardName(plat.url, in: merged) == "Platform")
        #expect(WorkList.boardName("https://elsewhere", in: merged) == "https://elsewhere")
        #expect(WorkList.Filter().board.isEmpty)
    }

    @Test func aProjectHasTheReposItsFoldersReadOnEveryMachine() throws {
        let box = MachineRef(rawValue: "box")
        func read(_ n: Int, _ repo: String, _ folder: String) -> DaemonAPI.ForgeItem {
            var i = item(n, repo: repo)
            i.folder = folder
            return i
        }
        let agents = WorkList.Project(id: "p1", name: "Agents", folders: [
            WorkList.folderKey(host: .mac, path: "/Users/a/Agents/"), WorkList.folderKey(host: box, path: "/home/a/Agents"),
        ])
        let www = WorkList.Project(id: "p2", name: "www", folders: [WorkList.folderKey(host: .mac, path: "/Users/a/www")])
        let quiet = WorkList.Project(id: "p3", name: "quiet", folders: [WorkList.folderKey(host: .mac, path: "/Users/a/quiet")])
        let lists: [(host: MachineRef, items: [DaemonAPI.ForgeItem])] = [
            (host: .mac, items: [read(1, "alexec/Agents", "/Users/a/Agents"), read(2, "alexec/www", "/Users/a/www")]),
            (host: box, items: [read(3, "alexec/docs", "/home/a/Agents")]),
        ]
        let projects = WorkList.projectRepos([agents, www, quiet], lists: lists)
        // A project whose folders read nothing is not offered.
        #expect(projects.map(\.project.name) == ["Agents", "www"])
        #expect(try #require(projects.first).repos == ["github:alexec/Agents", "github:alexec/docs"])

        let rows = WorkList.merge(lists, lineage: [])
        #expect(Set(WorkList.filter(rows, .init(project: "p1"), projects: projects).map(\.node.ref))
            == ["github:alexec/Agents#1", "github:alexec/docs#3"])
        #expect(WorkList.filter(rows, .init(project: "p2"), projects: projects).map(\.node.ref) == ["github:alexec/www#2"])
        #expect(WorkList.filter(rows, .init(project: "p3"), projects: projects).isEmpty)
        #expect(WorkList.filter(rows, .init(), projects: projects).count == 3)

        #expect(WorkList.project(ofFolder: "/home/a/Agents", on: box, in: [agents, www])?.name == "Agents")
        #expect(WorkList.project(ofFolder: "/home/a/Agents", on: .mac, in: [agents, www]) == nil)
        #expect(WorkList.project(ofFolder: nil, on: .mac, in: [agents]) == nil)
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
        // #3311: a Linear issue's repo is its team, a choice of the Repo filter of its own.
        #expect(WorkList.repo(of: "linear:ENG-4") == "linear:ENG")
        #expect(WorkList.repoName("linear:ENG") == "Linear · ENG")
        var linear = node(0, 0)
        linear.node = Node(kind: "issue", ref: "linear:OPS-2")
        linear.repo = "linear"
        #expect(WorkList.Row(linear).repo == "linear:OPS")
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

    @Test func aNodesPageIsInItsKindsList() {
        #expect(WorkList.kind(of: milestone) == .milestone)
        #expect(WorkList.kind(of: session) == nil)
    }

    @Test func checksReviewAndPeopleInWords() {
        let checks: [DaemonAPI.ForgeCheck] = [.init(name: "a", state: "passing"), .init(name: "b", state: "passing"),
                                              .init(name: "c", state: "failing")]
        #expect(WorkList.checksWords(checks) == "Checks: 2 passing, 1 failing")
        #expect(WorkList.checksWords([], summary: "none") == nil)
        #expect(WorkList.reviewWords("changes_requested") == "Review: Changes requested")
        let item = DaemonAPI.ForgeItem(node: pr, title: "T", state: "open", author: "alexec", assignees: ["bob"],
                                       milestone: "0.14", updatedAt: at)
        #expect(WorkList.peopleWords(item) == "by alexec · assigned to bob · milestone 0.14")
    }

    /// #3130: the page's actions say what each does, as the web page's do.
    @Test func theActionsSayWhatTheyDo() {
        #expect(WorkList.mergeButton(.squash, waits: false) == "Squash and merge")
        #expect(WorkList.mergeButton(nil, waits: true) == "Merge when checks pass")
        let item = DaemonAPI.ForgeItem(node: pr, title: "T", state: "open", updatedAt: at, checks: "passing")
        let running = DaemonAPI.ForgeItemDetail(item: item, checks: [.init(name: "a", state: "running"), .init(name: "b", state: "failing")])
        #expect(WorkList.mergeWaits(running))
        #expect(!WorkList.mergeWaits(DaemonAPI.ForgeItemDetail(item: item, checks: [.init(name: "a", state: "passing")])))
        #expect(WorkList.failedChecks(running).map(\.name) == ["b"])
        #expect(WorkList.doneWords(DaemonAPI.Method.forgeMerge, .init(auto: true)) == "Auto-merge is on: it merges when its checks pass.")
        #expect(WorkList.doneWords(DaemonAPI.Method.forgeRerun, .init(reran: 2)) == "2 runs started again.")
        #expect(WorkList.doneWords(DaemonAPI.Method.forgeClose, .init(), reopened: true) == "Reopened.")
        #expect(WorkList.doneWords(DaemonAPI.Method.forgeClose, .init(), moved: true) == "Status changed.")
        #expect(WorkList.closeTitle("open") == "Close")
        #expect(WorkList.closeTitle("closed") == "Reopen")
    }

    /// #3130: a pull request's diff from the forge is the diff a view gives the app's diff page.
    @Test func aForgeDiffIsTheViewsDiff() throws {
        let diff = DaemonAPI.ForgeDiff(url: "https://github.com/o/r/pull/1/files", files: [
            .init(path: "a.go", additions: 1, hunks: [.init(oldStart: 0, newStart: 3, lines: [DiffLine(kind: .added, text: "x")])]),
            .init(path: "b.png", note: "binary"),
        ], cut: true)
        let page = diff.appViewDiff(title: "#1 T")
        #expect(page.title == "#1 T" && page.cut && page.url?.host == "github.com")
        try #require(page.files.map(\.path) == ["a.go", "b.png"])
        #expect(page.files[0].hunks.first?.oldStart == 1 && page.files[0].hunks.first?.lines.first?.kind == .added)
        #expect(page.files[1].note == "binary")
    }

    @Test func aPlaceIsAListOrAPage() {
        #expect(WorkPlace(kind: .pr).node == nil)
        #expect(WorkPlace(kind: .pr, ref: pr.ref).node == pr)
    }

    @Test func previousAndNextAreTheRowsAboveAndBelowInTheListShown() throws {
        let items: [DaemonAPI.ForgeItem] = (1 ... 3).map { n in
            .init(node: Node(kind: "issue", ref: "github:alexec/Agents#\(n)"), title: "Issue \(n)", state: "open", labels: [],
                  assignees: [], updatedAt: at)
        }
        let rows: [WorkList.Row] = WorkList.sort(WorkList.merge([(host: MachineRef.mac, items: items)], lineage: []), by: .newest)
        let refs: [String] = rows.map { $0.node.ref }
        try #require(refs.count == 3)
        let first = WorkList.neighbours(of: refs[0], in: rows)
        #expect(first?.previous == nil && first?.next == refs[1] && first?.position == 1 && first?.count == 3)
        let middle = WorkList.neighbours(of: refs[1], in: rows)
        #expect(middle?.previous == refs[0] && middle?.next == refs[2])
        let last = WorkList.neighbours(of: refs[2], in: rows)
        #expect(last?.next == nil && last?.position == 3)
        #expect(last.map { WorkList.positionWords($0, more: true) } == "3 of 3+")
        #expect(middle.map { WorkList.positionWords($0, more: false) } == "2 of 3")
        // A row the filters leave out has no place in the list.
        #expect(WorkList.neighbours(of: refs[1], in: WorkList.filter(rows, .init(text: "Issue 3"))) == nil)
    }

    @Test func onlyAPageOpenedFromItsListGoesThroughIt() {
        #expect(WorkPlace(kind: .pr, ref: pr.ref, fromList: true).fromList)
        #expect(!WorkPlace(kind: .pr, ref: pr.ref).fromList)
        #expect(!WorkPlace(kind: .pr, fromList: true).fromList)
    }

    @Test func previousAndNextReplaceThePlaceSoBackGoesToTheList() {
        var h = LineageHistory<WorkPlace>()
        h.go(WorkPlace(kind: .issue))
        h.go(WorkPlace(kind: .issue, ref: "a", fromList: true))
        h.replace(WorkPlace(kind: .issue, ref: "b", fromList: true))
        h.replace(WorkPlace(kind: .issue, ref: "c", fromList: true))
        #expect(h.places.count == 2 && h.current?.ref == "c")
        h.back()
        #expect(h.current == WorkPlace(kind: .issue))
        #expect(h.canGoForward)
    }
}
