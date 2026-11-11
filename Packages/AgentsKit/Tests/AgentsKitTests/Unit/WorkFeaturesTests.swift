import Foundation
import Testing
@testable import AgentsKitCore

/// Work ▸ Features (#3269), as `Web/test/work-features.test.mjs` has it on the web page.
@Suite("Work features")
struct WorkFeaturesTests {
    typealias Node = DaemonAPI.LineageNode
    let day = Date(timeIntervalSince1970: 1_793_000_000)

    func issue(_ n: Int, level: String? = nil, parent: Int? = nil, progress: (Int, Int)? = nil, state: String = "open",
               at: TimeInterval = 0) -> DaemonAPI.ForgeItem {
        var item = DaemonAPI.ForgeItem(node: Node(kind: "issue", ref: "github:alexec/Agents#\(n)"), title: "Issue \(n)",
                                       state: state, updatedAt: day.addingTimeInterval(at))
        item.level = level
        item.parent = parent.map { Node(kind: "issue", ref: "github:alexec/Agents#\($0)") }
        item.progress = progress.map { .init(done: $0.0, total: $0.1) }
        return item
    }

    func agent(_ labels: [String], state: AgentState, at: TimeInterval = 0) -> Agent {
        var a = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp/work"))
        a.labels = labels.map { SessionLabel(value: $0, owner: .agent) }
        a.state = state
        a.createdAt = day.addingTimeInterval(at)
        return a
    }

    @Test func aFeatureSaysItsNameAndCounts() {
        #expect(WorkFeatures.title("work") == "Work")
        #expect(WorkFeatures.title("") == "")
        #expect(WorkFeatures.countWords(.init(name: "work", epics: 3, open: 2)) == "3 epics · 2 open")
        #expect(WorkFeatures.countWords(.init(name: "hosted", epics: 1, open: 0)) == "1 epic · 0 open")
        #expect(WorkFeatures.countWords(.init(name: "work", epics: 1, open: 0, issues: 0)) == "1 epic · 0 open")
        #expect(WorkFeatures.countWords(.init(name: "work", epics: 1, open: 0, issues: 1)) == "1 epic · 0 open · 1 open issue")
        #expect(WorkFeatures.countWords(.init(name: "work", epics: 2, open: 1, issues: 4)) == "2 epics · 1 open · 4 open issues")
    }

    @Test func aFeatureWithNoOpenWorkIsFinished() throws {
        let features: [DaemonAPI.ForgeFeature] = [
            .init(name: "browser", epics: 1, open: 0, issues: 0),
            .init(name: "lineage", epics: 2, open: 1, issues: 0),
            .init(name: "old", epics: 1, open: 0),
            .init(name: "work", epics: 3, open: 0, issues: 2),
        ]
        let groups = WorkFeatures.groups(features)
        try #require(groups.map(\.group) == [.idle, .finished])
        #expect(groups[0].features.map(\.name) == ["lineage", "old", "work"])
        #expect(groups[1].features.map(\.name) == ["browser"])
        #expect(WorkFeatures.Group.finished.words == "Finished")
    }

    /// #4115: each feature in the first group it matches, from the sessions labelled with its work.
    @Test func featuresAreInNeedsYouInFlightIdleAndFinished() throws {
        func feature(_ name: String, _ refs: [Int], waiting: [Int] = [], at: TimeInterval = 0, issues: Int = 1) -> DaemonAPI.ForgeFeature {
            .init(name: name, epics: 1, open: 1, issues: issues, refs: refs.map { "github:alexec/Agents#\($0)" },
                  waiting: waiting.map { "github:alexec/Agents#\($0)" }, updatedAt: day.addingTimeInterval(at))
        }
        let features = [
            feature("asked", [10]), feature("approval", [20]), feature("todo", [30], waiting: [30]),
            feature("busy", [40, 41]), feature("new", [50], at: 100), feature("old", [60], at: -100),
            feature("stale", [70]), .init(name: "done", epics: 1, open: 0, issues: 0),
        ]
        let agents = [
            agent(["#10"], state: .waitingOnUser), agent(["#20", "P#200"], state: .stopped),
            agent(["#40"], state: .running), agent(["#41", "lead"], state: .finished), agent(["#40"], state: .archived),
            agent(["#70"], state: .archived), agent(["#5"], state: .running),
        ]
        let groups = WorkFeatures.groups(features, agents: agents, approvals: ["github:alexec/Agents#200"])
        try #require(groups.map(\.group) == [.needsYou, .inFlight, .idle, .finished])
        #expect(groups[0].features.map(\.name) == ["asked", "approval", "todo"])
        #expect(groups[1].features.map(\.name) == ["busy"])
        #expect(groups[2].features.map(\.name) == ["old", "stale", "new"])
        #expect(groups[3].features.map(\.name) == ["done"])
        try #require(features.count == 8)
        #expect(WorkFeatures.sessions(of: features[3], in: agents).count == 2)
        #expect(WorkFeatures.sessionWords(1) == "1 session")
        #expect(WorkFeatures.sessionWords(3) == "3 sessions")
        // Without the approval, a stopped session that waits for it is still in flight.
        #expect(WorkFeatures.groups([features[1]], agents: agents).map(\.group) == [.inFlight])
        #expect(WorkFeatures.Group.allCases.map { $0.words } == ["Needs you", "In flight", "Idle", "Finished"])
    }

    @Test func severalMachinesFeaturesAddUpByName() throws {
        let merged = WorkFeatures.merge([
            [.init(name: "work", color: "#1d76db", epics: 2, open: 1), .init(name: "lineage", epics: 4, open: 0)],
            [.init(name: "Work", epics: 1, open: 1)],
        ])
        try #require(merged.map(\.name) == ["lineage", "work"])
        #expect(merged[1].epics == 3)
        #expect(merged[1].open == 2)
        #expect(merged[1].color == "#1d76db")
        let counted = WorkFeatures.merge([[.init(name: "work", epics: 1, open: 0, issues: 1)], [.init(name: "work", epics: 1, open: 0, issues: 2)],
                                          [.init(name: "docs", epics: 1, open: 0, issues: 0)], [.init(name: "docs", epics: 1, open: 0)]])
        #expect(counted.map(\.issues) == [nil, 3])
        let refs = WorkFeatures.merge([[.init(name: "work", epics: 1, open: 1, refs: ["a#1", "a#2"], waiting: ["a#2"], updatedAt: day)],
                                       [.init(name: "work", epics: 1, open: 1, refs: ["a#2", "b#3"], updatedAt: day.addingTimeInterval(9))]])
        try #require(refs.count == 1)
        #expect(refs[0].refs == ["a#1", "a#2", "b#3"])
        #expect(refs[0].waiting == ["a#2"])
        #expect(refs[0].updatedAt == day.addingTimeInterval(9))
    }

    @Test func anOpenedFeatureShowsItsEpicsAndItsLooseIssues() throws {
        let shown = WorkFeatures.opened([
            issue(3265, level: "epic", progress: (1, 6), at: 10),
            issue(3269, level: "story", parent: 3265, at: 20),
            issue(3100, progress: (5, 7), at: 30),
            issue(3131, at: 5),
            issue(3000, level: "epic", state: "closed"),
            issue(3265, level: "epic", progress: (1, 6), at: 10),
        ])
        try #require(shown.epics.map(\.node.ref) == ["github:alexec/Agents#3100", "github:alexec/Agents#3265"])
        #expect(shown.loose.map(\.node.ref) == ["github:alexec/Agents#3131"])
        #expect(WorkFeatures.progressWords(shown.epics[1]) == "1 of 6")
        #expect(WorkFeatures.progressWords(issue(1, level: "epic")) == "0 of 0")
    }

    @Test func theLeadIsTheLiveSessionLabelledLeadAndTheEpic() {
        let epic = Node(kind: "issue", ref: "github:alexec/Agents#3265")
        let ended = agent(["#3265", "lead"], state: .stopped, at: 100)
        let live = agent(["#3265", "lead"], state: .running)
        let lane = agent(["#3265"], state: .running, at: 200)
        let other = agent(["#3100", "lead"], state: .running, at: 300)
        let archived = agent(["#3265", "lead"], state: .archived, at: 400)
        #expect(WorkFeatures.lead(of: epic, in: [ended, live, lane, other, archived])?.id == live.id)
        #expect(WorkFeatures.lead(of: epic, in: [ended, lane])?.id == ended.id)
        #expect(WorkFeatures.lead(of: epic, in: [lane, other]) == nil)
        let linear = Node(kind: "issue", ref: "linear:ENG-5")
        #expect(WorkFeatures.lead(of: linear, in: [agent(["ENG-5", "lead"], state: .finished)]) != nil)
    }

    @Test func theLeadSaysItsState() {
        #expect(WorkFeatures.leadWords(nil) == "No lead")
        #expect(WorkFeatures.leadWords(.running) == "● lead working")
        #expect(WorkFeatures.leadWords(.waitingOnUser) == "● lead needs you")
        #expect(WorkFeatures.leadWords(.stopped) == "lead stopped")
    }

    @Test func aFeaturesBarIsItsEpicsDone() {
        let work = DaemonAPI.ForgeFeature(name: "work", epics: 2, open: 1)
        #expect(WorkFeatures.epicsDone(work) == 0.5)
        #expect(WorkFeatures.epicsDoneWords(work) == "1 of 2 epics done")
        #expect(WorkFeatures.epicsDoneWords(.init(name: "runtimes", epics: 1, open: 1)) == "0 of 1 epic done")
        #expect(WorkFeatures.epicsDone(.init(name: "none", epics: 0, open: 0)) == nil)
    }

    @Test func aNeedsYouFeatureSaysWhatWaits() {
        let work = DaemonAPI.ForgeFeature(name: "work", epics: 2, open: 1, waiting: ["github:alexec/Agents#4290"])
        let lane = agent(["#4333", "P#4405"], state: .finished)
        #expect(WorkFeatures.needsWords(work, sessions: [lane], approvals: ["github:alexec/Agents#4405"]) == "P#4405 waits for your approval")
        #expect(WorkFeatures.needsWords(work, sessions: [lane], approvals: []) == "#4290 waits for you")
        var asking = agent(["#4333"], state: .waitingOnUser)
        asking.title = "Work look: epic page"
        let idle = DaemonAPI.ForgeFeature(name: "work", epics: 2, open: 1)
        #expect(WorkFeatures.needsWords(idle, sessions: [asking], approvals: []) == "“Work look: epic page” needs you")
        #expect(WorkFeatures.needsWords(idle, sessions: [lane], approvals: []) == nil)
    }

    @Test func featuresIsAListOfItsOwnAndNoLineagePage() {
        #expect(WorkList.Kind.allCases.map(\.title) == ["Issues", "Pull requests", "Features", "Releases", "Timeline"])
        #expect(!WorkList.Kind.feature.fromForge)
        #expect(WorkList.kind(of: Node(kind: "feature", ref: "work")) == nil)
    }

    // MARK: The delivery view (#4587)

    func pull(_ n: Int, checks: String? = nil, review: String? = nil) -> DaemonAPI.ForgeItem {
        DaemonAPI.ForgeItem(node: Node(kind: "pr", ref: "github:alexec/Agents#\(n)"), title: "PR \(n)", state: "open",
                            updatedAt: day, checks: checks, review: review)
    }

    @Test func featuresInNeedsYouAndInFlightStartOpen() {
        let all: [WorkFeatures.Group] = [.needsYou, .inFlight, .idle, .finished]
        #expect(WorkFeatures.startsOpen(.needsYou, in: all))
        #expect(WorkFeatures.startsOpen(.inFlight, in: all))
        #expect(!WorkFeatures.startsOpen(.idle, in: all))
        #expect(!WorkFeatures.startsOpen(.finished, in: all))
        // Everything idle (state 14): Idle starts open.
        #expect(WorkFeatures.startsOpen(.idle, in: [.idle, .finished]))
        #expect(!WorkFeatures.startsOpen(.finished, in: [.finished]))
    }

    @Test func aChildIsInFlightWithALaneOrAPullRequest() throws {
        let pulls = WorkFeatures.pullsByLabel([pull(44, checks: "running"), pull(45), pull(46, checks: "passing", review: "approved")])
        let lane = { (labels: [String], state: AgentState) -> Agent in
            var a = self.agent(labels, state: state)
            a.title = "Gift card part-payment"
            return a
        }
        let agents = [lane(["#12", "P#44"], .running), lane(["#13", "P#45"], .finished), agent(["#33"], state: .waitingOnUser),
                      agent(["#40"], state: .archived), lane(["#14", "P#46"], .stopped)]
        let approvals: Set<String> = ["P#45"]
        func line(_ item: DaemonAPI.ForgeItem) -> WorkFeatures.Line? {
            WorkFeatures.line(item, work: WorkFeatures.work(of: item, agents: agents, pulls: pulls), approvals: approvals)
        }
        let working = try #require(line(issue(12)))
        #expect(working.flight == .working)
        #expect(working.words == "Working · “Gift card part-payment” · checks running")
        #expect(working.pr.map { WorkList.shortRef($0.node.ref) } == "#44")
        #expect(line(issue(13))?.words == "P#45 waits for your approval")
        #expect(line(issue(13))?.flight == .needsYou)
        #expect(line(issue(33))?.words == "Needs you · the lane asks a question")
        #expect(line(issue(14))?.words == "Working · “Gift card part-payment” · approved")
        var todo = issue(50)
        todo.labels = [.init(name: "alex-todo")]
        #expect(line(todo)?.words == "waits for you (alex-todo)")
        // An archived lane, nothing on it, or closed: not in flight.
        #expect(line(issue(40)) == nil)
        #expect(line(issue(41)) == nil)
        #expect(line(issue(12, state: "closed")) == nil)
        // A pull request with no lane this app knows says itself.
        #expect(WorkFeatures.line(issue(60), work: .init(pr: pull(47, checks: "failing")), approvals: [])?.words
            == "P#47 open · checks failed")

        let items = [issue(12, at: 10), issue(13, at: 1), issue(33, at: 5), issue(41), issue(42, state: "closed")]
        let lines = WorkFeatures.inFlight(items, work: { WorkFeatures.work(of: $0, agents: agents, pulls: pulls) }, approvals: approvals)
        #expect(lines.map { WorkList.shortRef($0.item.node.ref) } == ["#33", "#13", "#12"])
        let tally = WorkFeatures.tally(items, work: { WorkFeatures.work(of: $0, agents: agents, pulls: pulls) }, approvals: approvals)
        #expect(tally == .init(done: 1, inFlight: 3, notStarted: 1))
        #expect(tally.words == "1 of 5 done")
        #expect(tally.epicWords == "1 of 5")
        #expect(tally.shares.done == 0.2)
        #expect(WorkFeatures.restWords(tally) == "1 more not started · 1 done")
        #expect(WorkFeatures.restWords(tally, afterLines: false) == "1 not started · 1 done")
        #expect(WorkFeatures.restWords(.init()) == nil)
        #expect(WorkFeatures.phoneRestWords(tally, moreInFlight: 1) == "1 more in flight · 1 not started · 1 done")
        #expect(WorkFeatures.moreInFlightWords(2) == "2 more in flight")
        #expect(WorkFeatures.tally(progress: issue(1, progress: (4, 9))) == .init(done: 4, notStarted: 5))
    }

    @Test func anEpicSaysWhereItIsInItsPlan() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func child(_ n: Int, step: Int, state: String = "open", outside: [Int] = []) -> DaemonAPI.ForgePlanChild {
            .init(item: issue(n, state: state), blockedOutside: outside.map { Node(kind: "issue", ref: "github:alexec/Agents#\($0)") },
                  step: step)
        }
        let steps = (1 ... 3).map { DaemonAPI.ForgePlanStep(step: $0, nodes: []) }
        let plan = DaemonAPI.ForgePlan(item: issue(10, level: "epic"),
                                       children: [child(1, step: 1, state: "closed"), child(2, step: 2, outside: [99]),
                                                  child(3, step: 3)], steps: steps)
        #expect(WorkFeatures.whereWords(WorkFeatures.place(plan, closes: nil)) == "step 2 of 3 · waits for #99")
        let thursday = day.addingTimeInterval(3 * 86400)
        let words = try #require(WorkFeatures.whereWords(WorkFeatures.place(plan, closes: thursday), now: day, calendar: calendar))
        #expect(words.hasPrefix("step 2 of 3 · waits for #99 · closes about "))
        #expect(!words.hasSuffix("today") && !words.hasSuffix("tomorrow"))
        #expect(WorkFeatures.dayWords(day, now: day, calendar: calendar) == "today")
        #expect(WorkFeatures.dayWords(day.addingTimeInterval(86400), now: day, calendar: calendar) == "tomorrow")
        let done = DaemonAPI.ForgePlan(item: issue(10), children: [child(1, step: 1, state: "closed")], steps: [.init(step: 1, nodes: [])])
        #expect(WorkFeatures.whereWords(WorkFeatures.place(done, closes: nil)) == nil)
        // From work/features (#4586): the forecast that waits says so in place of a day.
        let epic = DaemonAPI.WorkFeatureEpic(item: issue(10, level: "epic"), step: 3, steps: 3,
                                             forecast: .init(low: day, mid: thursday, high: thursday, waits: true),
                                             children: [.init(item: issue(3), createdAt: day)])
        #expect(WorkFeatures.place(epic).flatMap { WorkFeatures.whereWords($0) } == "step 3 of 3 · waits for you")
        #expect(WorkFeatures.place(DaemonAPI.WorkFeatureEpic(item: issue(10), steps: 1)) == nil)
    }

    @Test func aFeatureSaysWhatIsInFlight() {
        let feature = DaemonAPI.ForgeFeature(name: "checkout", epics: 3, open: 2, issues: 1, updatedAt: day)
        #expect(WorkFeatures.deliveryWords(feature, inFlight: 4, sessions: nil, now: day) == "2 epics · 4 in flight")
        #expect(WorkFeatures.deliveryWords(feature, inFlight: 2, sessions: 2, now: day) == "2 epics · 2 in flight · 2 sessions")
        #expect(WorkFeatures.deliveryWords(feature, inFlight: nil, sessions: nil, now: day) == "2 epics")
        #expect(WorkFeatures.deliveryWords(.init(name: "accounts", epics: 1, open: 1, updatedAt: day), inFlight: 0, sessions: nil,
                                           now: day.addingTimeInterval(3 * 86400)).hasPrefix("1 epic · nothing in flight · updated 3"))
        #expect(WorkFeatures.deliveryWords(.init(name: "done", epics: 2, open: 0, issues: 0), inFlight: 0, sessions: nil)
            == "2 epics · nothing in flight")
        #expect(WorkFeatures.deliveryWords(.init(name: "loose", epics: 0, open: 0, issues: 3), inFlight: 1, sessions: nil)
            == "3 open issues · 1 in flight")
    }

    /// #4586: one read gives the features, their epics' places, and what waits for the person.
    @Test func workFeaturesGivesEpicsAndChildrenInOneRead() throws {
        let child = DaemonAPI.WorkTimelineChild(item: issue(12, parent: 10), createdAt: day, waitsForPerson: true)
        let one = DaemonAPI.WorkFeatures(features: [
            .init(feature: .init(name: "Checkout", epics: 2, open: 2, issues: 1),
                  epics: [.init(item: issue(10, level: "epic"), step: 1, steps: 2, children: [child]),
                          .init(item: issue(20, level: "epic"), steps: 0)],
                  loose: [.init(item: issue(31), createdAt: day)]),
        ])
        let two = DaemonAPI.WorkFeatures(features: [.init(feature: .init(name: "checkout", epics: 1, open: 1, issues: 0))])
        let read = WorkFeatures.read([one, two])
        try #require(read.features.count == 1)
        #expect(read.features[0].epics == 3)
        #expect(read.items["checkout"]?.map { WorkList.shortRef($0.node.ref) } == ["#10", "#20", "#31"])
        #expect(read.places["github:alexec/Agents#10"]?.children.count == 1)
        #expect(read.unread == ["github:alexec/Agents#20"])
        #expect(read.waiting == ["github:alexec/Agents#12"])
        let work = WorkFeatures.work(of: child.item, agents: [], pulls: [:], waiting: read.waiting)
        #expect(WorkFeatures.line(child.item, work: work, approvals: [])?.words == "waits for you (alex-todo)")
    }
}
