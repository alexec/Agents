import Foundation
import Testing
@testable import AgentsKitCore

/// The sidebar's rules, which the Mac's window and the Remote both draw (#226): what goes
/// under which heading of a project's fold, in what order, what a search leaves, and
/// which folds start open.
@MainActor
@Suite("The sidebar's model")
struct SidebarModelTests {
    private let api = URL(filePath: "/tmp/work/api")
    private let web = URL(filePath: "/tmp/work/web")
    private let devbox = HostID(rawValue: "devbox01")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ folder: URL, _ state: AgentState, _ title: String, at offset: Double,
                       host: HostID = .mac) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: folder, title: title, state: state,
                          lastActivityAt: t0.addingTimeInterval(offset))
        agent.host = host
        if state == .finished { agent.endedReason = .endTurn }
        return agent
    }

    private func summary(_ folder: URL, host: HostID = .mac, archived: Int = 0) -> DaemonAPI.ProjectSummary {
        var summary = DaemonAPI.ProjectSummary(project: Project(folder: folder), name: folder.lastPathComponent,
                                               exists: true, lastActivityAt: t0,
                                               counts: archived > 0 ? [.archived: archived] : [:])
        summary.host = host
        return summary
    }

    private var key: ProjectKey { ProjectKey(host: .mac, folder: api) }

    @Test func aFoldedProjectFilesNothingButIsStillShown() {
        let model = AgentsModel()
        model.replaceAgents([agent(api, .running, "build", at: 1)])
        let fold = SidebarProjectFold(key, label: "api", in: model, isOpen: false)
        #expect(fold.isShown)
        #expect(fold.groups.isEmpty)
        #expect(fold.pinned.isEmpty)
    }

    /// A folded project holds no rows of any kind (#356): an Archived fold, pinned pages or
    /// "No sessions yet" coming and going under it left NSOutlineView's count of its
    /// children apart from SwiftUI's, and Apple Intelligence reading the list crashed.
    @Test func aFoldedProjectHasNothingUnderItsRow() {
        let model = AgentsModel()
        model.replaceAgents([agent(api, .archived, "old", at: 1)])
        model.replacePins([ProjectPins(folder: api, pins: [], sessions: [])])
        var held = summary(api, archived: 12)
        held.retiredCount = 3
        let folded = SidebarProjectFold(key, label: "api", in: model, isOpen: false)
        #expect(!folded.isUnfolded)
        #expect(!folded.showsArchivedFold(held))
        #expect(!folded.showsPinnedPages)
        #expect(!folded.showsNoSessions)
        #expect(folded.groups.isEmpty && folded.pinned.isEmpty && folded.archived.isEmpty)
        #expect(folded.workflows.isEmpty && folded.archivedWorkflows.isEmpty)

        let open = SidebarProjectFold(key, label: "api", in: model, isOpen: true)
        #expect(open.isUnfolded)
        #expect(open.showsArchivedFold(held))
        #expect(open.showsPinnedPages)
        #expect(open.showsNoSessions)

        // A search unfolds it, and the search is for sessions, not pages.
        let searched = SidebarProjectFold(key, label: "api", in: model, query: "old", isOpen: false)
        #expect(searched.isUnfolded)
        #expect(!searched.showsPinnedPages)
        #expect(!searched.showsNoSessions)
    }

    @Test func pinnedComeFirstInTheirOrderAndLeaveTheirGroups() {
        let model = AgentsModel()
        let working = agent(api, .running, "working", at: 1)
        let done = agent(api, .finished, "done", at: 2)
        let other = agent(api, .finished, "other", at: 3)
        let asking = agent(api, .waitingOnUser, "asking", at: 4)
        let gone = agent(api, .archived, "gone", at: 5)
        let elsewhere = agent(api, .running, "elsewhere", at: 6, host: devbox)
        model.replaceAgents([working, done, other, asking, gone, elsewhere])
        model.replacePins([ProjectPins(folder: api, pins: [], sessions: [done.id, gone.id, working.id, elsewhere.id])])

        let fold = SidebarProjectFold(key, label: "api", in: model, isOpen: true)
        // In the order they were put in; never an archived one, nor another host's.
        #expect(fold.pinned.map(\.id) == [done.id, working.id])
        #expect(fold.groups.map(\.group) == [.needsAttention, .finished])
        #expect(fold.groups.flatMap(\.agents).map(\.id) == [asking.id, other.id])
        #expect(fold.archived.map(\.id) == [gone.id])
        #expect(fold.hasLive)
    }

    @Test func groupsFollowTheLiveOrderAndCountUnread() {
        let model = AgentsModel()
        var unread = agent(api, .finished, "unread", at: 1)
        unread.isUnread = true
        var parked = agent(api, .finished, "parked", at: 2)
        parked.parking = .parked(at: t0)
        model.replaceAgents([parked, unread, agent(api, .running, "working", at: 3),
                             agent(api, .waitingOnUser, "asking", at: 4)])
        let fold = SidebarProjectFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.groups.map(\.group) == AgentGroup.live.filter { [.needsAttention, .running, .finished, .parked].contains($0) })
        #expect(fold.groups.first { $0.group == .finished }?.unread == 1)
    }

    @Test func aSearchKeepsWhatMatchesAndHidesAProjectWithNothing() {
        let model = AgentsModel()
        let match = agent(api, .running, "fix the login page", at: 1)
        model.replaceAgents([match, agent(api, .finished, "write docs", at: 2), agent(web, .running, "deploy", at: 3)])
        let found = SidebarProjectFold(key, label: "api", in: model, query: " login ", isOpen: false)
        #expect(found.isSearching)
        #expect(found.query == "login")
        #expect(found.groups.flatMap(\.agents).map(\.id) == [match.id])
        #expect(found.isShown)

        let none = SidebarProjectFold(ProjectKey(host: .mac, folder: web), label: "web", in: model,
                                      query: "login", isOpen: true)
        #expect(!none.isShown)
        let byName = SidebarProjectFold(ProjectKey(host: .mac, folder: web), label: "web", in: model,
                                        query: "WE", isOpen: false)
        #expect(byName.isShown, "the project's own name matches")
    }

    @Test func theArchivedFoldCountsWhatTheHostSaysUntilASearch() {
        let model = AgentsModel()
        let gone = agent(api, .archived, "old login work", at: 1)
        model.replaceAgents([gone])
        let held = summary(api, archived: 12)
        let fold = SidebarProjectFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.archivedCount(held) == 12)
        #expect(fold.showsArchivedFold(held))
        #expect(fold.showsArchivedFold(summary(api)), "one is held, so there is a fold")

        let empty = SidebarProjectFold(ProjectKey(host: .mac, folder: web), label: "web", in: model, isOpen: true)
        #expect(!empty.showsArchivedFold(summary(web)))
        // The host's count may not have arrived (#227): what is held still shows the fold.
        #expect(empty.archivedCount(nil) == 0)

        let searched = SidebarProjectFold(key, label: "api", in: model, query: "login", isOpen: false)
        #expect(searched.archivedCount(held) == 1)
        #expect(searched.retiredLine(held) == nil)
    }

    @Test func archivedMatchesShowAFewUntilShowAll() {
        let model = AgentsModel()
        model.replaceAgents((0..<15).map { agent(api, .archived, "login \($0)", at: Double($0)) })
        let searched = SidebarProjectFold(key, label: "api", in: model, query: "login", isOpen: false)
        #expect(searched.archivedShown(showingAll: false).count == SidebarProjectFold.matchesShown)
        #expect(searched.archivedShown(showingAll: true).count == 15)
        let open = SidebarProjectFold(key, label: "api", in: model, isOpen: true)
        #expect(open.archivedShown(showingAll: false).count == 15)
    }

    @Test func projectsAreThisMacsThenEachServersInHostOrder() {
        let gpu = HostID(rawValue: "gpu00001")
        let stray = HostID(rawValue: "stray001")
        let listed = [summary(api, host: gpu), summary(web), summary(api, host: devbox), summary(api),
                      summary(web, host: stray)]
        let ordered = SidebarOrder.projects(listed, servers: [devbox, gpu])
        #expect(ordered.map(\.key) == [ProjectKey(host: .mac, folder: web), ProjectKey(host: .mac, folder: api),
                                       ProjectKey(host: devbox, folder: api), ProjectKey(host: gpu, folder: api)])
        #expect(SidebarOrder.label(summary(api, host: devbox)) { $0 == devbox ? "devbox" : "?" } == "devbox:api")
        #expect(SidebarOrder.label(summary(api)) { _ in "?" } == "api")
    }

    @Test func foldsStartAsTheMacsDidAndAreKeptPerScope() throws {
        let defaults = try #require(UserDefaults(suiteName: "SidebarModelTests.\(UUID())"))
        let folds = SidebarFolds(defaults: defaults, scope: "")
        #expect(!folds.isOpen(key), "a project starts folded")
        #expect(!folds.isOpen(key, .archivedSessions))
        #expect(folds.isOpen(key, .group(.running)), "a group starts open")
        #expect(folds.isOpen(key, .pinned))
        #expect(folds.isOpen(key, .workflows))

        folds.set(key, open: true)
        folds.set(key, .archivedSessions, open: true)
        folds.set(key, .group(.finished), open: false)
        let again = SidebarFolds(defaults: defaults, scope: "")
        #expect(again.isOpen(key))
        #expect(!again.isOpen(key, .group(.finished)))
        #expect(again.openArchivedFolds == [key])
        // The keys the Mac has always kept them under, so nobody's folds are lost.
        #expect(defaults.stringArray(forKey: "sidebar.folds")?.contains(key.stored) == true)
        #expect(defaults.stringArray(forKey: "sidebar.folded") == ["group.finished:\(key.stored)"])

        let walk = SidebarFolds(defaults: defaults, scope: ".walk:w1")
        #expect(!walk.isOpen(key), "another scope's folds are its own")
    }
}
