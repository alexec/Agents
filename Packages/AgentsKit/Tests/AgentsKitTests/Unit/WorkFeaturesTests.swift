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
        #expect(WorkFeatures.finishedWords(7) == "Finished (7)")
        #expect(WorkFeatures.Group.finished.words(7) == "Finished (7)")
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
        #expect(WorkFeatures.Group.allCases.map { $0.words(2) } == ["Needs you", "In flight", "Idle", "Finished (2)"])
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
        #expect(WorkFeatures.progressWords(shown.epics[1]) == "1/6")
        #expect(WorkFeatures.progressWords(issue(1, level: "epic")) == "0/0")
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
        #expect(WorkFeatures.leadWords(nil) == "—")
        #expect(WorkFeatures.leadWords(.running) == "● lead running")
        #expect(WorkFeatures.leadWords(.waitingOnUser) == "● lead needs you")
        #expect(WorkFeatures.leadWords(.stopped) == "lead stopped")
    }

    @Test func featuresIsAListOfItsOwnAndNoLineagePage() {
        #expect(WorkList.Kind.allCases.map(\.title) == ["Issues", "Pull requests", "Features", "Milestones", "Releases"])
        #expect(!WorkList.Kind.feature.fromForge)
        #expect(WorkList.kind(of: Node(kind: "feature", ref: "work")) == nil)
    }
}
