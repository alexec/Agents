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
