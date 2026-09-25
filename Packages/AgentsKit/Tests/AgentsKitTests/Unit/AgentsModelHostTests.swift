import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// One window, several daemons (037): what each sent is filed under where it came from.
@MainActor
@Suite("The model across hosts")
struct AgentsModelHostTests {
    private let devbox = HostID(rawValue: "devbox01")
    private let gpu = HostID(rawValue: "gpu00001")
    private let path = URL(filePath: "/home/alex/src/api")

    private func agent(_ cwd: URL, title: String = "t") -> Agent {
        Agent(runtimeID: "claude", cwd: cwd, title: title, state: .finished, endedReason: .endTurn)
    }

    private func summary(_ folder: URL) -> DaemonAPI.ProjectSummary {
        DaemonAPI.ProjectSummary(project: Project(folder: folder), name: folder.lastPathComponent, exists: true,
                                 lastActivityAt: Date(), counts: [:])
    }

    @Test func whatANotificationCarriesIsFiledUnderItsHost() throws {
        let model = AgentsModel()
        let one = agent(path)
        model.apply(DaemonAPI.Notification.agentChanged, try JSONValue.encoding(one), from: devbox)
        model.apply(DaemonAPI.Notification.projectChanged, try JSONValue.encoding(summary(path)), from: devbox)
        #expect(model.agent(one.id)?.host == devbox)
        #expect(model.project(ProjectKey(host: devbox, folder: path)) != nil)
        #expect(model.project(ProjectKey(host: .mac, folder: path)) == nil)
    }

    @Test func aHostIsNeverWrittenIntoTheRecord() throws {
        var one = agent(path)
        one.host = devbox
        var project = summary(path)
        project.host = devbox
        let agentJSON = String(decoding: try JSONEncoder().encode(one), as: UTF8.self)
        let projectJSON = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        #expect(!agentJSON.contains("devbox01"))
        #expect(!projectJSON.contains("devbox01"))
        #expect(try JSONDecoder().decode(Agent.self, from: Data(agentJSON.utf8)).host == .mac)
        #expect(try JSONDecoder().decode(DaemonAPI.ProjectSummary.self, from: Data(projectJSON.utf8)).host == .mac)
    }

    @Test func aHostReListingReplacesOnlyItsOwn() {
        let model = AgentsModel()
        let mine = agent(URL(filePath: "/Users/alex/app"))
        let theirs = agent(path)
        model.replaceAgents([mine], from: .mac)
        model.replaceProjects([summary(URL(filePath: "/Users/alex/app"))], from: .mac)
        model.replaceAgents([theirs], from: devbox)
        model.replaceProjects([summary(path)], from: devbox)
        #expect(model.agents.count == 2)
        #expect(model.projects.count == 2)

        model.replaceAgents([], from: devbox)
        model.replaceProjects([], from: devbox)
        #expect(model.agents.map(\.id) == [mine.id], "the Mac's are untouched by a server re-listing")
        #expect(model.projects.count == 1)
    }

    @Test func theSamePathOnTwoHostsIsTwoProjectsWithTheirOwnAgents() {
        let model = AgentsModel()
        let a = agent(path, title: "on devbox")
        let b = agent(path, title: "on gpu")
        model.replaceProjects([summary(path)], from: devbox)
        model.replaceProjects([summary(path)], from: gpu)
        model.replaceAgents([a], from: devbox)
        model.replaceAgents([b], from: gpu)
        #expect(model.projects.count == 2)
        let onDevbox = ProjectKey(host: devbox, folder: path)
        #expect(model.agents(in: onDevbox, group: .finished).map(\.id) == [a.id])
        #expect(model.counts(in: onDevbox)[.finished] == 1)
        #expect(model.counts(in: ProjectKey(host: gpu, folder: path))[.finished] == 1)
    }

    @Test func aProjectChangeUpdatesOnlyItsHostsCopy() throws {
        let model = AgentsModel()
        model.replaceProjects([summary(path)], from: devbox)
        model.replaceProjects([summary(path)], from: gpu)
        var renamed = summary(path)
        renamed.name = "renamed"
        model.apply(DaemonAPI.Notification.projectChanged, try JSONValue.encoding(renamed), from: gpu)
        #expect(model.project(ProjectKey(host: gpu, folder: path))?.name == "renamed")
        #expect(model.project(ProjectKey(host: devbox, folder: path))?.name == "api")
    }

    @Test func withoutAHostEverythingIsTheMacs() throws {
        let model = AgentsModel()
        let one = agent(path)
        model.apply(DaemonAPI.Notification.agentChanged, try JSONValue.encoding(one))
        model.replaceProjects([summary(path)])
        #expect(model.agent(one.id)?.host == .mac)
        #expect(model.project(ProjectKey(folder: path)) != nil)
        #expect(model.project(path) != nil, "the phone's calls read as they always did")
    }
}
