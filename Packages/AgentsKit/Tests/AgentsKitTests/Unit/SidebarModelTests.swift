import Foundation
import Testing
@testable import AgentsKitCore

/// The sidebar's rules, which the Mac's window and the Remote both draw (#226): what goes
/// under which heading of a folder's fold, in what order, what a search leaves, and
/// which folds start open.
@MainActor
@Suite("The sidebar's model")
struct SidebarModelTests {
    private let api = URL(filePath: "/tmp/work/api")
    private let web = URL(filePath: "/tmp/work/web")
    private let devbox = MachineRef(rawValue: "devbox01")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ folder: URL, _ state: AgentState, _ title: String, at offset: Double,
                       host: MachineRef = .mac) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: folder, title: title, state: state,
                          lastActivityAt: t0.addingTimeInterval(offset))
        agent.host = host
        if state == .finished { agent.endedReason = .endTurn }
        return agent
    }

    private func summary(_ folder: URL, host: MachineRef = .mac, archived: Int = 0) -> DaemonAPI.FolderSummary {
        var summary = DaemonAPI.FolderSummary(folder: Folder(folder: folder), name: folder.lastPathComponent,
                                               exists: true, lastActivityAt: t0,
                                               counts: archived > 0 ? [.archived: archived] : [:])
        summary.host = host
        return summary
    }

    private var key: FolderKey { FolderKey(host: .mac, folder: api) }

    @Test func aFoldedFolderFilesNothingButIsStillShown() {
        let model = AgentsModel()
        model.replaceAgents([agent(api, .running, "build", at: 1)])
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: false)
        #expect(fold.isShown)
        #expect(fold.groups.isEmpty)
        #expect(fold.pinned.isEmpty)
    }

    /// A folded folder holds no rows of any kind (#356): an Archived fold, pinned pages or
    /// "No sessions yet" coming and going under it left NSOutlineView's count of its
    /// children apart from SwiftUI's, and Apple Intelligence reading the list crashed.
    /// #2032: a server's list views come with the pins, apart from them, and a Hide is
    /// shown at once; a selected row finds a view as it finds a pin.
    @Test func aServersListViewsAreHeldApartFromThePins() {
        let model = AgentsModel()
        let server = PinnerView(kind: .server, id: "github", name: "GitHub")
        let pulls = PinView(path: "ui://github/pulls", title: "GitHub · Pull requests", kind: .view, missing: false,
                            pinnedBy: server, view: ViewPin(server: "github", uri: "ui://github/pulls", tool: "show_pull_requests"))
        let issues = PinView(path: "ui://github/issues", title: "GitHub · Issues", kind: .view, missing: false,
                             pinnedBy: server, view: ViewPin(server: "github", uri: "ui://github/issues", tool: "show_issues"),
                             hidden: true)
        model.replacePins([FolderPins(folder: api, pins: [], views: [pulls, issues])])
        #expect(model.pins(in: api).isEmpty)
        #expect(model.serverViews(in: api).map(\.title) == ["GitHub · Pull requests", "GitHub · Issues"])
        #expect(model.pinOrView("ui://github/pulls", in: api)?.isServerView == true)
        model.setViewHidden("ui://github/pulls", true, in: api)
        model.setViewHidden("ui://github/issues", false, in: api)
        #expect(model.serverViews(in: api).map(\.hidden) == [true, nil])
    }

    /// #2033: a view row's count and when it was read, decoded from the host's answer.
    @Test func aViewRowsCountIsDecodedWithItsTime() throws {
        let json = #"{"path":"ui://github/issues","title":"GitHub · Issues","kind":"view","missing":false,"#
            + #""pinnedBy":{"kind":"server","id":"github","name":"GitHub"},"count":23,"attention":1,"#
            + #""countAt":800000000,"countStale":true}"#
        let view = try JSONDecoder().decode(PinView.self, from: Data(json.utf8))
        #expect(view.count == 23 && view.attention == 1 && view.countStale == true)
        #expect(view.countHelp?.contains("did not answer") == true)
    }

    @Test func aFoldedFolderHasNothingUnderItsRow() {
        let model = AgentsModel()
        model.replaceAgents([agent(api, .archived, "old", at: 1)])
        model.replacePins([FolderPins(folder: api, pins: [], sessions: [])])
        let held = summary(api, archived: 12)
        let folded = SidebarFolderFold(key, label: "api", in: model, isOpen: false)
        #expect(!folded.isUnfolded)
        #expect(!folded.showsArchivedFold(held))
        #expect(!folded.showsPinnedPages)
        #expect(!folded.showsNoSessions)
        #expect(folded.groups.isEmpty && folded.pinned.isEmpty && folded.archived.isEmpty)
        #expect(folded.workflows.isEmpty && folded.archivedWorkflows.isEmpty)

        let open = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(open.isUnfolded)
        #expect(open.showsArchivedFold(held))
        #expect(open.showsPinnedPages)
        #expect(open.showsNoSessions)

        // A search unfolds it, and the search is for sessions, not pages.
        let searched = SidebarFolderFold(key, label: "api", in: model, query: "old", isOpen: false)
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
        model.replacePins([FolderPins(folder: api, pins: [], sessions: [done.id, gone.id, working.id, elsewhere.id])])

        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
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
        var asking = agent(api, .finished, "asking", at: 2)
        asking.archiveRequest = .requested(at: t0)
        model.replaceAgents([asking, unread, agent(api, .running, "working", at: 3),
                             agent(api, .waitingOnUser, "asking", at: 4)])
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.groups.map(\.group) == AgentGroup.live.filter { [.needsAttention, .running, .finished].contains($0) })
        #expect(fold.groups.first { $0.group == .finished }?.unread == 1)
    }

    @Test func aSearchKeepsWhatMatchesAndHidesAFolderWithNothing() {
        let model = AgentsModel()
        let match = agent(api, .running, "fix the login page", at: 1)
        model.replaceAgents([match, agent(api, .finished, "write docs", at: 2), agent(web, .running, "deploy", at: 3)])
        let found = SidebarFolderFold(key, label: "api", in: model, query: " login ", isOpen: false)
        #expect(found.isSearching)
        #expect(found.query == "login")
        #expect(found.groups.flatMap(\.agents).map(\.id) == [match.id])
        #expect(found.isShown)

        let none = SidebarFolderFold(FolderKey(host: .mac, folder: web), label: "web", in: model,
                                      query: "login", isOpen: true)
        #expect(!none.isShown)
        let byName = SidebarFolderFold(FolderKey(host: .mac, folder: web), label: "web", in: model,
                                        query: "WE", isOpen: false)
        #expect(byName.isShown, "the folder's own name matches")
    }

    @Test func theArchivedFoldCountsWhatTheHostSaysUntilASearch() {
        let model = AgentsModel()
        let gone = agent(api, .archived, "old login work", at: 1)
        model.replaceAgents([gone])
        let held = summary(api, archived: 12)
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.archivedCount(held) == 12)
        #expect(fold.showsArchivedFold(held))
        #expect(fold.showsArchivedFold(summary(api)), "one is held, so there is a fold")

        let empty = SidebarFolderFold(FolderKey(host: .mac, folder: web), label: "web", in: model, isOpen: true)
        #expect(!empty.showsArchivedFold(summary(web)))
        // The host's count may not have arrived (#227): what is held still shows the fold.
        #expect(empty.archivedCount(nil) == 0)

        let searched = SidebarFolderFold(key, label: "api", in: model, query: "login", isOpen: false)
        #expect(searched.archivedCount(held) == 1)
    }

    @Test func archivedMatchesShowAFewUntilShowAll() {
        let model = AgentsModel()
        model.replaceAgents((0..<15).map { agent(api, .archived, "login \($0)", at: Double($0)) })
        let searched = SidebarFolderFold(key, label: "api", in: model, query: "login", isOpen: false)
        #expect(searched.archivedShown(showingAll: false).count == SidebarFolderFold.matchesShown)
        #expect(searched.archivedShown(showingAll: true).count == 15)
        let open = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(open.archivedShown(showingAll: false).count == 15)
    }

    @Test func sessionsFoldKeepsTheThreeNewestArchivedSessions() {
        let model = AgentsModel()
        let archived = (0..<5).map { agent(api, .archived, "archived \($0)", at: Double($0)) }
        model.replaceAgents(archived + [agent(api, .running, "live", at: 10)])
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.recentArchived(now: t0).map(\.id) == archived.suffix(3).reversed().map(\.id))

        let empty = SidebarFolderFold(FolderKey(host: .mac, folder: web), label: "web", in: model, isOpen: true)
        #expect(empty.recentArchived.isEmpty)
    }

    @Test func recentlyArchivedHoldsOnlyTheLastDaysArchived() {
        let model = AgentsModel()
        let day = SidebarFolderFold.recentArchivedWithin
        let archived = [-day - 60, -day + 60, -10].map { agent(api, .archived, "archived \($0)", at: $0) }
        model.replaceAgents(archived)
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.recentArchived(now: t0).map(\.id) == [archived[2].id, archived[1].id])
        #expect(fold.recentArchived(now: t0.addingTimeInterval(day)).isEmpty)
    }

    @Test func aSearchListsArchivedMatchesOnceNotInTheRecentFold() {
        let model = AgentsModel()
        model.replaceAgents((0..<5).map { agent(api, .archived, "login \($0)", at: Double($0)) })
        let searched = SidebarFolderFold(key, label: "api", in: model, query: "login", isOpen: false)
        #expect(searched.recentArchived.isEmpty)
        #expect(searched.archivedShown(showingAll: false).count == 5)
    }

    @Test func foldersAreThisMacsThenEachServersInHostOrder() {
        let gpu = MachineRef(rawValue: "gpu00001")
        let stray = MachineRef(rawValue: "stray001")
        let listed = [summary(api, host: gpu), summary(web), summary(api, host: devbox), summary(api),
                      summary(web, host: stray)]
        let ordered = SidebarOrder.folders(listed, servers: [devbox, gpu])
        #expect(ordered.map(\.key) == [FolderKey(host: .mac, folder: web), FolderKey(host: .mac, folder: api),
                                       FolderKey(host: devbox, folder: api), FolderKey(host: gpu, folder: api)])
        #expect(SidebarOrder.label(summary(api, host: devbox)) { $0 == devbox ? "devbox" : "?" } == "devbox:api")
        #expect(SidebarOrder.label(summary(api)) { _ in "?" } == "api")
    }

    @Test func pinnedFoldersComeFirstFromEveryHost() {
        func pinned(_ summary: DaemonAPI.FolderSummary) -> DaemonAPI.FolderSummary {
            var summary = summary
            summary.folder.pinned = true
            return summary
        }
        let listed = [summary(api), pinned(summary(api, host: devbox)), pinned(summary(web))]
        let ordered = SidebarOrder.folders(listed, servers: [devbox])
        #expect(ordered.map(\.key) == [FolderKey(host: .mac, folder: web), FolderKey(host: devbox, folder: api),
                                       FolderKey(host: .mac, folder: api)])
    }

    @Test func foldersStayInTheOrderTheyWereAddedHoweverBusy() {
        let docs = URL(filePath: "/tmp/work/docs")
        func added(_ folder: URL, at offset: Double, active: Double = 0, host: MachineRef = .mac) -> DaemonAPI.FolderSummary {
            var summary = DaemonAPI.FolderSummary(
                folder: Folder(folder: folder, addedAt: t0.addingTimeInterval(offset)),
                name: folder.lastPathComponent, exists: true, lastActivityAt: t0.addingTimeInterval(active), counts: [:])
            summary.host = host
            return summary
        }
        let model = AgentsModel()
        model.replaceFolders([added(web, at: 20), added(api, at: 10)])
        #expect(model.folders.map(\.folder.folder) == [api, web], "oldest added first")

        // Activity on the newer folder leaves it where it is (#357).
        model.upsert(added(web, at: 20, active: 999))
        #expect(model.folders.map(\.folder.folder) == [api, web])

        model.upsert(added(docs, at: 30))
        #expect(model.folders.map(\.folder.folder) == [api, web, docs], "a new folder lands at the end")

        // A server re-listing keeps the same rule, and the same moment falls back to the folder.
        model.replaceFolders([added(web, at: 5, host: devbox), added(api, at: 5, host: devbox)], from: devbox)
        #expect(model.folders.filter { $0.host == devbox }.map(\.folder.folder) == [api, web])
        #expect(SidebarOrder.folders(model.liveFolders, servers: [devbox]).map(\.key)
                == [api, web, docs].map { FolderKey(host: .mac, folder: $0) }
                + [api, web].map { FolderKey(host: devbox, folder: $0) })
    }

    @Test func foldsStartAsTheMacsDidAndAreKeptPerScope() throws {
        let defaults = MemoryDefaults()
        let folds = SidebarFolds(defaults: defaults, scope: "")
        #expect(!folds.isOpen(key), "a folder starts folded")
        #expect(!folds.isOpen(key, .archivedSessions))
        #expect(folds.isOpen(key, .group(.running)), "a group starts open")
        #expect(folds.isOpen(key, .pinned))
        #expect(!folds.isOpen(key, .workflows), "a folder's Workflows starts folded (#885)")
        #expect(folds.isOpen(key, .sessions), "a folder's Sessions starts open (#2312)")

        folds.set(key, open: true)
        folds.set(key, .archivedSessions, open: true)
        folds.set(key, .group(.finished), open: false)
        folds.set(key, .workflows, open: true)
        folds.set(key, .sessions, open: false)
        let again = SidebarFolds(defaults: defaults, scope: "")
        #expect(again.isOpen(key))
        #expect(!again.isOpen(key, .group(.finished)))
        #expect(again.isOpen(key, .workflows), "each folder's Workflows fold is kept")
        #expect(!again.isOpen(key, .sessions), "each folder's Sessions fold is kept")
        #expect(again.openArchivedFolds == [key])
        // The keys the Mac has always kept them under, so nobody's folds are lost.
        #expect(defaults.stringArray(forKey: "sidebar.folds")?.contains(key.stored) == true)
        #expect(defaults.stringArray(forKey: "sidebar.folded") == ["group.finished:\(key.stored)", "sessions:\(key.stored)"])

        let walk = SidebarFolds(defaults: defaults, scope: ".walk:w1")
        #expect(!walk.isOpen(key), "another scope's folds are its own")
    }

    private func started(_ folder: URL, _ state: AgentState, _ title: String, at offset: Double,
                         unread: Bool = false) -> Agent {
        var made = Agent(runtimeID: "claude", cwd: folder, title: title, state: state,
                         createdAt: t0.addingTimeInterval(offset), lastActivityAt: t0.addingTimeInterval(offset),
                         isUnread: unread)
        if state == .finished { made.endedReason = .endTurn }
        return made
    }

    /// A folder folds open straight onto its sessions (#495): every live one no smart
    /// group lists (#587), newest started first, whatever its state.
    @Test func aFoldersSessionsAreOneListNewestStartedFirst() {
        let model = AgentsModel()
        let asking = started(api, .waitingOnUser, "asking", at: 1)
        let working = started(api, .running, "working", at: 3)
        let done = started(api, .finished, "done", at: 2)
        let pinned = started(api, .finished, "pinned", at: 4)
        let gone = started(api, .archived, "gone", at: 5)
        model.replaceAgents([asking, working, done, pinned, gone])
        model.replacePins([FolderPins(folder: api, pins: [], sessions: [pinned.id])])

        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.sessions.map(\.id) == [done.id])
        #expect(fold.pinned.map(\.id) == [pinned.id])
        #expect(SidebarFolderFold(key, label: "api", in: model, isOpen: false).sessions.isEmpty)
    }

    /// #3900: a search for an epic lists what it found under each issue, the epic's own
    /// first, then the children in the epic's order; live before archived; a session no
    /// host placed (found by its title) under the epic; no smart row takes one.
    @Test func aSearchForAnEpicGroupsItsSessionsUnderEachIssue() {
        let model = AgentsModel()
        let lead = started(api, .running, "lead", at: 1)
        let lane = started(api, .finished, "lane", at: 2)
        let merged = started(api, .archived, "merged", at: 3)
        let named = started(api, .finished, "Work on #40", at: 4)
        let other = started(api, .finished, "other", at: 5)
        model.replaceAgents([lead, lane, merged, named, other])
        let node = { (n: Int) in DaemonAPI.LineageNode(kind: "issue", ref: "github:o/r#\(n)") }
        model.noteIssueSessions(DaemonAPI.LineageSessions(
            matches: [.init(agentID: lead.id, on: node(40)), .init(agentID: lane.id, on: node(42)),
                      .init(agentID: merged.id, on: node(41))],
            issues: [.init(node: node(40), title: "Epic"), .init(node: node(41)), .init(node: node(42), title: "Second")]))

        let fold = SidebarFolderFold(key, label: "api", in: model, query: "#40", isOpen: false)
        #expect(fold.issueGroups.map(\.title) == ["#40 Epic", "#41", "#42 Second"])
        #expect(fold.issueGroups.map { $0.sessions.map(\.id) } == [[named.id, lead.id], [merged.id], [lane.id]])
        #expect(fold.sessions.isEmpty && fold.archived.isEmpty)
        #expect(SidebarSmartRow.working.agents(in: model, folders: [key], query: "#40").isEmpty)
        #expect(SidebarSmartRow.working.agents(in: model, folders: [key]).map(\.id) == [lead.id])

        // An issue with no sub-issues, or another search, keeps one list.
        model.issueHeadings = [.init(node: node(40))]
        #expect(SidebarFolderFold(key, label: "api", in: model, query: "#40", isOpen: false).issueGroups.isEmpty)
    }

    /// The smart rows gather across every folder (#495), by what each session wants.
    @Test func smartRowsGatherAcrossFolders() {
        let model = AgentsModel()
        let askingAPI = started(api, .waitingOnUser, "asking api", at: 1)
        let askingWeb = started(web, .waitingOnUser, "asking web", at: 2)
        let working = started(web, .running, "working", at: 3)
        let unread = started(api, .finished, "unread", at: 4, unread: true)
        let read = started(api, .finished, "read", at: 5)
        model.replaceAgents([askingAPI, askingWeb, working, unread, read])
        let folders = [key, FolderKey(host: .mac, folder: web)]

        #expect(SidebarSmartRow.needsYou.count(in: model, folders: folders) == 2)
        #expect(SidebarSmartRow.needsYou.agents(in: model, folders: folders).map(\.id) == [askingWeb.id, askingAPI.id])
        #expect(SidebarSmartRow.working.agents(in: model, folders: folders).map(\.id) == [working.id])
        #expect(SidebarSmartRow.unread.agents(in: model, folders: folders).map(\.id) == [unread.id])
        #expect(SidebarSmartRow.needsYou.agents(in: model, folders: folders, query: "web").map(\.id) == [askingWeb.id])
    }

    /// Needs You lists a row per request (#3864): its asker is not a session row too, and the
    /// count and the badge count requests, so two requests from one session are two, and a
    /// request that ended leaves at once.
    @Test func needsYouListsARowPerRequest() {
        let model = AgentsModel()
        let asking = started(api, .waitingOnUser, "asking", at: 1)
        let other = started(api, .waitingOnUser, "other", at: 2)
        model.replaceAgents([asking, other])
        func request(_ title: String, at: TimeInterval) -> NeedRequest {
            NeedRequest(id: UUID(), kind: .decide, source: "question", title: title, folder: api, askedBy: asking.id,
                        waiters: [.init(agent: asking.id, since: Date(timeIntervalSince1970: at)),
                                  .init(agent: other.id, since: Date(timeIntervalSince1970: at))],
                        askedAt: Date(timeIntervalSince1970: at))
        }
        let first = request("Which port?", at: 10)
        let second = request("Which name?", at: 20)
        model.replaceRequests([second, first])

        #expect(SidebarSmartRow.needsYou.requests(in: model, folders: [key]).map(\.request.id) == [first.id, second.id])
        #expect(SidebarSmartRow.needsYou.agents(in: model, folders: [key]).map(\.id) == [other.id])
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: [key]) == 3)
        #expect(model.attentionCount(in: key) + model.requestBadgeShift(in: api) == 3)
        #expect(first.line(asker: "asking") == "Question · asking · blocks 2 sessions")
        #expect(SidebarSmartRow.needsYou.requests(in: model, folders: [key], query: "port").map(\.request.id) == [first.id])

        var answered = first
        answered.state = .answered
        model.apply(.requestChanged(answered))
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: [key]) == 2)
    }

    /// Later (#4234): a deferred request leaves Needs You's rows, its count and the badge,
    /// and its asker is not a session row there either; it is a row of Later, which keeps
    /// Needs You drawn on its own. Bring back now puts it back.
    @Test func aDeferredRequestIsInLaterAndInNoCount() {
        let model = AgentsModel()
        let asking = started(api, .waitingOnUser, "asking", at: 1)
        model.replaceAgents([asking])
        var request = NeedRequest(id: UUID(), kind: .decide, source: "question", title: "Which port?", folder: api,
                                  askedBy: asking.id, waiters: [.init(agent: asking.id, since: t0)], askedAt: t0)
        model.replaceRequests([request])
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: [key]) == 1)

        request.deferred = .init(atMac: true, at: t0)
        model.apply(.requestChanged(request))
        #expect(SidebarSmartRow.needsYou.requests(in: model, folders: [key]).isEmpty)
        #expect(SidebarSmartRow.needsYou.agents(in: model, folders: [key]).isEmpty)
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: [key]) == 0)
        #expect(model.attentionCount(in: key) + model.requestBadgeShift(in: api) == 0)
        #expect(SidebarSmartRow.needsYou.laterRequests(in: model, folders: [key]).map(\.request.id) == [request.id])
        #expect(SidebarSmartRow.needsYou.isShown(in: model, folders: [key]))
        #expect(SidebarSmartRow.needsYou.isShown(in: model, folders: [key], query: "port"))

        request.deferred = nil
        model.apply(.requestChanged(request))
        #expect(SidebarSmartRow.needsYou.laterRequests(in: model, folders: [key]).isEmpty)
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: [key]) == 1)
    }

    /// Later's choices (#4234): 1h, 4h, 8h and 1d on from now; At my Mac, no time. Its row
    /// says when it comes back.
    @Test func laterChoicesAndWhenItComesBack() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        let noon = at(10, 12)
        #expect(NeedRequest.Later.timed.map(\.short) == ["1h", "4h", "8h", "1d"])
        #expect(NeedRequest.Later.hour.until(from: noon) == at(10, 13))
        #expect(NeedRequest.Later.fourHours.until(from: noon) == at(10, 16))
        #expect(NeedRequest.Later.eightHours.until(from: noon) == at(10, 20))
        #expect(NeedRequest.Later.day.until(from: noon) == at(11, 12))
        #expect(NeedRequest.Later.atMac.until(from: noon) == nil)
        #expect(NeedRequest.Later.atMac.params(id: UUID(), now: noon).atMac == true)

        #expect(NeedRequest.Deferral(atMac: true, at: noon).back(now: noon, calendar: calendar) == "At my Mac")
        #expect(NeedRequest.Deferral(until: at(10, 18), at: noon).back(now: noon, calendar: calendar).hasPrefix("Back at "))
        #expect(NeedRequest.Deferral(until: at(11, 9), atMac: true, at: noon).back(now: noon, calendar: calendar)
            .hasPrefix("Back tomorrow at "))
        #expect(NeedRequest.Deferral(until: at(11, 9), atMac: true, at: noon).back(now: noon, calendar: calendar)
            .hasSuffix(" or at my Mac"))
        #expect(NeedRequest.Deferral(until: at(14, 9), at: noon).back(now: noon, calendar: calendar).hasPrefix("Back on "))
    }

    /// A request read off the wire keeps its deferral (#4233).
    @Test func aRequestDecodesItsDeferral() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"decide","source":"question","state":"open","title":"t","detail":{},"folder":"file:///tmp/a/","waiters":[],"askedAt":784468800,"deferred":{"atMac":true,"at":784468800,"by":{"user":"alex"}}}"#
        let request = try JSONValue.parse(Data(json.utf8)).decode(NeedRequest.self)
        #expect(request.deferred?.atMac == true)
        #expect(request.deferred?.by?.user == "alex")
    }

    /// A terminal's agents-secret (#4179) has no session and no folder of the sidebar: Needs
    /// You lists it and counts it anyway, and a search finds it by its title.
    @Test func needsYouListsATerminalsRequest() throws {
        let model = AgentsModel()
        let terminal = NeedRequest(id: UUID(), kind: .approve, source: "secretUse", title: "Print PLAIN_KEY in a terminal (zsh)",
                                   detail: try JSONValue.parse(Data(#"{"secretUse":{"name":"PLAIN_KEY","use":"terminal","place":"zsh"}}"#.utf8)),
                                   folder: URL(filePath: "/Users/someone/", directoryHint: .isDirectory), askedBy: nil,
                                   askedAt: Date(timeIntervalSince1970: 10))
        model.replaceRequests([terminal])

        #expect(terminal.isTerminal)
        #expect(SidebarSmartRow.needsYou.requests(in: model, folders: [key]).map(\.request.id) == [terminal.id])
        #expect(SidebarSmartRow.needsYou.requests(in: model, folders: []).map(\.request.id) == [terminal.id])
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: [key]) == 1)
        #expect(SidebarSmartRow.needsYou.isShown(in: model, folders: [key], query: "PLAIN_KEY"))
        #expect(SidebarSmartRow.needsYou.requests(in: model, folders: [key], query: "port").isEmpty)
    }

    /// Needs You holds everything waiting for an OK (#773): a session asking to be archived
    /// as its own row (Approve Archiving is gone), and every other kind of approval as a row
    /// of its own, counted with the sessions and found by a search.
    @Test func needsYouListsEveryApproval() {
        let model = AgentsModel()
        let asking = started(api, .waitingOnUser, "asking", at: 1)
        var done = started(api, .finished, "done", at: 2)
        done.archiveRequest = .requested(at: t0)
        model.replaceAgents([asking, done])
        var api = summary(self.api)
        api.approvals = [
            Approval(kind: .mcpServer, key: "ci", title: "ci", digest: "d1", line: "New MCP server",
                     since: t0.addingTimeInterval(5), actions: [.approve, .deny]),
            Approval(kind: .workflow, key: "nightly", title: "Nightly", digest: "d2", line: "Changed with the last pull",
                     since: t0.addingTimeInterval(1), actions: [.approve, .deny]),
            Approval(kind: .archive, key: done.id.uuidString, title: "done", digest: nil, line: "Asks to be archived",
                     actions: [.approve, .deny], agentID: done.id),
        ]
        model.replaceFolders([api, summary(web)])
        let folders = [key, FolderKey(host: .mac, folder: web)]

        #expect(!SidebarSmartRow.allCases.map(\.title).contains("Approve Archiving"))
        #expect(SidebarSmartRow.home(of: done, in: model.group(of: done), isPinned: false) == .needsYou)
        #expect(Set(SidebarSmartRow.needsYou.agents(in: model, folders: folders).map(\.id)) == [asking.id, done.id])
        // The archive request is the session's row, not one of its own; oldest first.
        #expect(SidebarSmartRow.needsYou.approvals(in: model, folders: folders).map(\.approval.key) == ["nightly", "ci"])
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: folders) == 4)
        #expect(SidebarSmartRow.working.approvals(in: model, folders: folders).isEmpty)
        #expect(SidebarSmartRow.needsYou.approvals(in: model, folders: folders, query: "mcp").map(\.approval.key) == ["ci"])
        #expect(SidebarSmartRow.needsYou.isShown(in: model, folders: folders, query: "pull"))
        #expect(SidebarSmartRow.unread.agents(in: model, folders: folders).isEmpty)
    }

    /// A failed workflow is a row of Needs You (#989), and its run's agent is that row, not a
    /// session row as well: listed once, and counted once.
    @Test func aFailedWorkflowStandsForItsRunsAgent() {
        let model = AgentsModel()
        let asking = started(api, .waitingOnUser, "asking", at: 1)
        var failed = started(api, .stopped, "nightly run", at: 2)
        failed.endedReason = .runtimeError
        model.replaceAgents([asking, failed])
        var api = summary(self.api)
        api.approvals = [Approval(kind: .workflowFailed, key: "nightly", title: "Nightly", digest: "ran:x",
                                  line: "Run failed — No network", since: t0, actions: [.dismiss], agentID: failed.id)]
        model.replaceFolders([api])
        let folders = [key]

        #expect(SidebarSmartRow.needsYou.agents(in: model, folders: folders).map(\.id) == [asking.id])
        #expect(SidebarSmartRow.needsYou.approvals(in: model, folders: folders).map(\.approval.key) == ["nightly"])
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: folders) == 2)
        #expect(api.hasFailedWorkflow)
        // With Working off, the pass over every session leaves it out the same way (#846).
        let on = SidebarSmartRow.all.subtracting([.working])
        #expect(SidebarSmartRow.needsYou.count(in: model, folders: folders, on: on) == 2)
    }

    /// Pinned gathers every folder's pinned sessions in pin order, never an archived one
    /// (#495), and they are not among their folder's own sessions.
    @Test func pinnedGathersEveryFoldersPinsInTheirOrder() {
        let model = AgentsModel()
        let first = started(api, .finished, "first", at: 1)
        let second = started(api, .running, "second", at: 2)
        let other = started(web, .finished, "other", at: 3)
        let gone = started(web, .archived, "gone", at: 4)
        model.replaceAgents([first, second, other, gone])
        model.replacePins([FolderPins(folder: api, pins: [], sessions: [second.id, first.id]),
                           FolderPins(folder: web, pins: [], sessions: [gone.id, other.id])])
        let folders = [key, FolderKey(host: .mac, folder: web)]

        #expect(SidebarSmartRow.pinned.agents(in: model, folders: folders).map(\.id) == [second.id, first.id, other.id])
        #expect(SidebarSmartRow.pinned.count(in: model, folders: folders) == 3)
        #expect(SidebarFolderFold(key, label: "api", in: model, isOpen: true).sessions.isEmpty)
    }

    /// A smart row with nothing in it is not drawn, nor one a search finds nothing in
    /// (#507).
    @Test func anEmptySmartRowIsNotShown() {
        let model = AgentsModel()
        let asking = started(api, .waitingOnUser, "asking api", at: 1)
        model.replaceAgents([asking])
        let folders = [key, FolderKey(host: .mac, folder: web)]

        #expect(SidebarSmartRow.needsYou.isShown(in: model, folders: folders))
        #expect(!SidebarSmartRow.working.isShown(in: model, folders: folders))
        #expect(!SidebarSmartRow.unread.isShown(in: model, folders: folders))
        #expect(!SidebarSmartRow.pinned.isShown(in: model, folders: folders))
        #expect(SidebarSmartRow.needsYou.isShown(in: model, folders: folders, query: "asking"))
        #expect(!SidebarSmartRow.needsYou.isShown(in: model, folders: folders, query: "nothing like it"))
    }

    /// Each live session is listed once (#587): in Pinned, else Needs You, else Working,
    /// else Unread, else under its folder; and every count says what its group lists.
    @Test func aSessionIsListedOnceInItsFirstGroup() {
        let model = AgentsModel()
        let pinnedAsking = started(api, .waitingOnUser, "pinned asking", at: 1)
        let asking = started(api, .waitingOnUser, "asking", at: 2)
        let pinnedWorking = started(api, .running, "pinned working", at: 3)
        let working = started(api, .running, "working", at: 4)
        let pinnedUnread = started(api, .finished, "pinned unread", at: 5, unread: true)
        let unread = started(api, .finished, "unread", at: 6, unread: true)
        let read = started(api, .finished, "read", at: 7)
        model.replaceAgents([pinnedAsking, asking, pinnedWorking, working, pinnedUnread, unread, read])
        model.replacePins([FolderPins(folder: api, pins: [],
                                       sessions: [pinnedAsking.id, pinnedWorking.id, pinnedUnread.id])])
        let folders = [key]

        let listed: [SidebarSmartRow: [UUID]] = Dictionary(uniqueKeysWithValues: SidebarSmartRow.allCases.map {
            ($0, $0.agents(in: model, folders: folders).map(\.id))
        })
        #expect(listed[.pinned] == [pinnedAsking.id, pinnedWorking.id, pinnedUnread.id])
        #expect(listed[.needsYou] == [asking.id])
        #expect(listed[.working] == [working.id])
        #expect(listed[.unread] == [unread.id])
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.sessions.map(\.id) == [read.id])

        for row in SidebarSmartRow.allCases {
            #expect(row.count(in: model, folders: folders) == listed[row]?.count, "\(row)")
        }
        let everyRow = listed.values.flatMap { $0 } + fold.sessions.map(\.id)
        #expect(everyRow.count == Set(everyRow).count, "nothing is listed twice")
        #expect(Set(everyRow).count == 7, "nothing is left out")
    }

    /// The session opened from Unread, read now, stays in Unread alone until another is
    /// opened (#689): not under its folder too.
    @Test func theSessionUnreadKeepsIsNotUnderItsFolderToo() {
        let model = AgentsModel()
        let opened = started(api, .finished, "opened", at: 2)
        let read = started(api, .finished, "read", at: 1)
        let working = started(api, .running, "working", at: 3)
        let pinned = started(api, .finished, "pinned", at: 4)
        model.replaceAgents([opened, read, working, pinned])
        model.replacePins([FolderPins(folder: api, pins: [], sessions: [pinned.id])])

        #expect(SidebarSmartRow.keptInUnread(opened.id, in: model)?.id == opened.id)
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true, keptInUnread: opened.id)
        #expect(fold.sessions.map(\.id) == [read.id])
        // Let go, it is under its folder.
        #expect(SidebarFolderFold(key, label: "api", in: model, isOpen: true).sessions.map(\.id) == [opened.id, read.id])
        // A search, or a home elsewhere, lets it go too.
        #expect(SidebarSmartRow.keptInUnread(opened.id, in: model, query: "opened") == nil)
        #expect(SidebarSmartRow.keptInUnread(working.id, in: model) == nil)
        #expect(SidebarSmartRow.keptInUnread(pinned.id, in: model) == nil)
    }

    /// For Review (#3194) lists a session done with a file nobody has opened, not Unread;
    /// one asking to be archived stays in Needs You, and a working one in Working. Opened, For
    /// Review keeps it in its place until another is opened, as Unread does (#495).
    @Test func forReviewListsDoneSessionsWithAFileToSee() {
        let model = AgentsModel()
        var report = started(api, .finished, "report", at: 1, unread: true)
        report.fileToSee = ShownFile(path: "/tmp/summary.md")
        var archiving = started(api, .finished, "archiving", at: 2, unread: true)
        archiving.fileToSee = ShownFile(path: "/tmp/a.md")
        archiving.archiveRequest = .requested(at: t0)
        var working = started(api, .running, "working", at: 3)
        working.fileToSee = ShownFile(path: "/tmp/w.md")
        let unread = started(api, .finished, "unread", at: 4, unread: true)
        var pinned = started(api, .finished, "pinned", at: 5, unread: true)
        pinned.fileToSee = ShownFile(path: "/tmp/p.md")
        model.replaceAgents([report, archiving, working, unread, pinned])
        model.replacePins([FolderPins(folder: api, pins: [], sessions: [pinned.id])])
        let folders = [key]

        #expect(SidebarSmartRow.forReview.agents(in: model, folders: folders).map(\.id) == [report.id])
        #expect(SidebarSmartRow.forReview.count(in: model, folders: folders) == 1)
        #expect(SidebarSmartRow.unread.agents(in: model, folders: folders).map(\.id) == [unread.id])
        #expect(SidebarSmartRow.unread.count(in: model, folders: folders) == 1)
        #expect(SidebarSmartRow.needsYou.agents(in: model, folders: folders).map(\.id) == [archiving.id])
        #expect(SidebarSmartRow.working.agents(in: model, folders: folders).map(\.id) == [working.id])
        #expect(SidebarSmartRow.forReview.startsOpen)

        // Off, it goes to Unread, which counts it then.
        let noReview = SidebarSmartRow.all.subtracting([.forReview])
        #expect(Set(SidebarSmartRow.unread.agents(in: model, folders: folders, on: noReview).map(\.id)) == [report.id, unread.id])

        // Opened and read (the host clears the file), For Review keeps it, not its folder.
        var read = report
        read.isUnread = false
        read.fileToSee = nil
        model.replaceAgents([read, archiving, working, unread, pinned])
        #expect(SidebarSmartRow.keeper(fileToSee: true) == .forReview)
        #expect(SidebarSmartRow.keeper(fileToSee: true, on: noReview) == .unread)
        #expect(SidebarSmartRow.keeper(fileToSee: false) == .unread)
        #expect(SidebarSmartRow.keptInUnread(read.id, in: model, keptBy: .forReview)?.id == read.id)
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true, keptInUnread: read.id, keptBy: .forReview)
        #expect(!fold.sessions.contains { $0.id == read.id })
        #expect(SidebarSmartRow.keptInUnread(read.id, in: model, on: noReview, keptBy: .forReview) == nil)
    }

    /// The daily summary's sessions are the Summary row's (#3721): done with its page unread,
    /// one is in neither For Review, Unread nor its folder's list; asking, it is in Needs You.
    @Test func dailySummarySessionsLeaveTheLists() {
        let model = AgentsModel()
        var written = started(api, .finished, "Daily summary, Fri 6 Nov", at: 1, unread: true)
        written.startedByWorkflow = "daily-summary"
        written.fileToSee = ShownFile(path: "/home/.agents/summaries/2026-11-06-1810.md")
        var asking = started(api, .waitingOnUser, "asking", at: 2)
        asking.startedByWorkflow = "daily-summary"
        var done = started(api, .finished, "done", at: 3)
        done.startedByWorkflow = "daily-summary"
        model.replaceAgents([written, asking, done])
        let folders = [key]

        #expect(SidebarSmartRow.forReview.agents(in: model, folders: folders).isEmpty)
        #expect(SidebarSmartRow.forReview.count(in: model, folders: folders) == 0)
        #expect(SidebarSmartRow.unread.agents(in: model, folders: folders).isEmpty)
        #expect(SidebarSmartRow.unread.count(in: model, folders: folders) == 0)
        #expect(SidebarSmartRow.needsYou.agents(in: model, folders: folders).map(\.id) == [asking.id])
        let fold = SidebarFolderFold(key, label: "api", in: model, isOpen: true)
        #expect(fold.sessions.isEmpty)
    }

    /// For Review lists, after its sessions, each folder's pull requests waiting for the
    /// person's approval (#3330), newest first, and counts them; a search matches their
    /// title, repo and number; Dismiss takes one out at once.
    @Test func forReviewListsPullRequestsWaitingForApproval() {
        let model = AgentsModel()
        let older = ReviewPull(url: URL(string: "https://github.com/alexec/agents/pull/1")!, number: 1,
                               title: "Sidebar: For Review", repo: "alexec/agents", updatedAt: t0)
        let newer = ReviewPull(url: URL(string: "https://github.com/alexec/agents/pull/2")!, number: 2,
                               title: "Chat: a new prompt bar", repo: "alexec/agents", updatedAt: t0.addingTimeInterval(60))
        model.replacePins([FolderPins(folder: api, pins: [], reviews: [older, newer])])
        let folders = [key]

        #expect(SidebarSmartRow.forReview.pulls(in: model, folders: folders).map(\.pull.number) == [2, 1])
        #expect(SidebarSmartRow.forReview.count(in: model, folders: folders) == 2)
        #expect(SidebarSmartRow.forReview.isShown(in: model, folders: folders))
        #expect(SidebarSmartRow.needsYou.pulls(in: model, folders: folders).isEmpty)
        #expect(SidebarSmartRow.forReview.pulls(in: model, folders: folders, query: "prompt").map(\.pull.number) == [2])
        #expect(SidebarSmartRow.forReview.pulls(in: model, folders: folders, query: "#1").map(\.pull.number) == [1])

        model.dismissReview(newer.url, in: api)
        #expect(SidebarSmartRow.forReview.pulls(in: model, folders: folders).map(\.pull.number) == [1])
        #expect(SidebarSmartRow.forReview.count(in: model, folders: folders) == 1)

        // #3464: unread until opened; opened, it is drawn read at once.
        #expect(model.reviewPulls(in: api).first?.isUnread == true)
        model.openReview(older.url, in: api)
        #expect(model.reviewPulls(in: api).first?.isUnread == false)
        #expect(SidebarSmartRow.forReview.count(in: model, folders: folders) == 1)
    }

    /// For Review lists, after its pull requests, the read-only daily checks' suggestions
    /// (#3331), the urgent first, then newest first, and counts them; a search matches the
    /// title and the prompt; Start or Dismiss takes one out at once.
    @Test func forReviewListsTheChecksSuggestions() {
        let model = AgentsModel()
        let older = CheckSuggestion(id: "a", title: "CI fails on main", prompt: "Fix CI on a branch.", at: t0)
        let newer = CheckSuggestion(id: "b", title: "PR #12 is in conflict", prompt: "Rebase it.", at: t0.addingTimeInterval(60))
        let urgent = CheckSuggestion(id: "c", title: "Nightly missed", prompt: "Run it.", urgent: true, at: t0.addingTimeInterval(-60))
        model.replacePins([FolderPins(folder: api, pins: [], suggestions: [older, newer, urgent])])
        let folders = [key]

        #expect(SidebarSmartRow.forReview.suggestions(in: model, folders: folders).map(\.suggestion.id) == ["c", "b", "a"])
        #expect(SidebarSmartRow.forReview.count(in: model, folders: folders) == 3)
        #expect(SidebarSmartRow.forReview.isShown(in: model, folders: folders))
        #expect(SidebarSmartRow.needsYou.suggestions(in: model, folders: folders).isEmpty)
        #expect(SidebarSmartRow.forReview.suggestions(in: model, folders: folders, query: "rebase").map(\.suggestion.id) == ["b"])

        model.dropSuggestion("b", in: api)
        #expect(SidebarSmartRow.forReview.suggestions(in: model, folders: folders).map(\.suggestion.id) == ["c", "a"])
        #expect(SidebarSmartRow.forReview.count(in: model, folders: folders) == 2)
    }

    /// A smart group turned off (#846) is not drawn, and its sessions go to the next group
    /// they fit, or under their folder: still listed once, none left out.
    @Test func aGroupTurnedOffPassesItsSessionsOn() {
        let model = AgentsModel()
        let pinnedAsking = started(api, .waitingOnUser, "pinned asking", at: 1)
        let asking = started(api, .waitingOnUser, "asking", at: 2)
        let working = started(api, .running, "working", at: 3)
        var archiving = started(api, .finished, "archiving", at: 4, unread: true)
        archiving.archiveRequest = .requested(at: t0)
        let unread = started(api, .finished, "unread", at: 5, unread: true)
        let read = started(api, .finished, "read", at: 6)
        var readArchiving = started(api, .finished, "read archiving", at: 7)
        readArchiving.archiveRequest = .requested(at: t0)
        model.replaceAgents([pinnedAsking, asking, working, archiving, unread, read, readArchiving])
        model.replacePins([FolderPins(folder: api, pins: [], sessions: [pinnedAsking.id])])
        let folders = [key]

        func listing(_ on: Set<SidebarSmartRow>) -> (rows: [SidebarSmartRow: [UUID]], own: [UUID]) {
            let rows = Dictionary(uniqueKeysWithValues: SidebarSmartRow.allCases.map {
                ($0, $0.agents(in: model, folders: folders, on: on).map(\.id))
            })
            for row in SidebarSmartRow.allCases where on.contains(row) {
                #expect(row.count(in: model, folders: folders, on: on) == rows[row]?.count, "\(row) \(on)")
            }
            let own = SidebarFolderFold(key, label: "api", in: model, isOpen: true, on: on).sessions.map(\.id)
            let every = rows.values.flatMap { $0 } + own
            #expect(every.count == Set(every).count && Set(every).count == 7, "\(on): once each, none left out")
            return (rows, own)
        }

        // All on: those asking to be archived are in Needs You, not counted under their
        // folder too (#937).
        let all = listing(SidebarSmartRow.all)
        #expect(all.own == [read.id])

        // Pinned off: the pinned session that asks is in Needs You.
        let noPins = listing(SidebarSmartRow.all.subtracting([.pinned]))
        #expect(noPins.rows[.pinned] == [])
        #expect(Set(noPins.rows[.needsYou] ?? []) == [pinnedAsking.id, asking.id, archiving.id, readArchiving.id])
        #expect(!SidebarSmartRow.pinned.isShown(in: model, folders: folders, on: SidebarSmartRow.all.subtracting([.pinned])))

        // Needs You off: the unread one asking to be archived goes to Unread, the one
        // asking a question under its folder.
        let noNeeds = listing(SidebarSmartRow.all.subtracting([.needsYou]))
        #expect(Set(noNeeds.rows[.unread] ?? []) == [archiving.id, unread.id])
        #expect(noNeeds.own.contains(asking.id))

        // Working off: the working session goes under its folder.
        let noWorking = listing(SidebarSmartRow.all.subtracting([.working]))
        #expect(noWorking.own.contains(working.id))

        // Every group off: all seven under the folder, the pinned one too.
        let none = listing([])
        #expect(Set(none.own) == Set([pinnedAsking, asking, working, archiving, unread, read, readArchiving].map(\.id)))
        #expect(SidebarSmartRow.keptInUnread(read.id, in: model, on: []) == nil)
    }

    /// What a device keeps: the groups turned off, so a new group would start on.
    @Test func theGroupsOnRoundTripThroughDefaults() {
        #expect(SidebarSmartRow.on(off: "") == SidebarSmartRow.all)
        #expect(SidebarSmartRow.off(on: SidebarSmartRow.all) == "")
        #expect(SidebarSmartRow.off(on: [.needsYou, .unread]) == "pinned,forReview,working")
        #expect(SidebarSmartRow.on(off: "pinned,working,gone") == [.needsYou, .forReview, .unread])
        // Nothing kept (#979): Pinned, Needs You and For Review (#3194) on.
        #expect(SidebarSmartRow.on(off: SidebarSmartRow.offAtFirst) == [.pinned, .needsYou, .forReview])
    }

    // MARK: One group per project (#3278)

    private func inProject(_ summary: DaemonAPI.FolderSummary, _ project: String?) -> DaemonAPI.FolderSummary {
        var summary = summary
        summary.project = project
        return summary
    }

    @Test func aProjectWithOneFolderIsThatFoldersGroupAsBefore() throws {
        let ordered = [inProject(summary(api), "p-api"), summary(web), inProject(summary(api, host: devbox), "p-other")]
        let groups = SidebarProjects.groups(ordered)
        try #require(groups.map(\.id) == ordered.map(\.key))
        #expect(groups.allSatisfy { $0.others.isEmpty })
        let label = SidebarProjects.label(groups[2], projectName: "Other") { _ in "devbox" }
        #expect(label == "devbox:api", "one folder keeps its own name, not the project's")
        #expect(SidebarProjects.sharedProjects(groups).isEmpty)
    }

    @Test func aProjectsFoldersOnEveryMachineAreOneGroupWhereItsFirstFolderStood() throws {
        // A server's folder first in the order (pinned), this Mac's later: one group, in the
        // first one's place, with this Mac's folder as its main one.
        let ordered = [inProject(summary(api, host: devbox), "p"), summary(web), inProject(summary(api), "p")]
        let groups = SidebarProjects.groups(ordered)
        try #require(groups.count == 2)
        #expect(groups[0].main.key == FolderKey(host: .mac, folder: api))
        #expect(groups[0].others.map(\.key) == [FolderKey(host: devbox, folder: api)])
        #expect(groups[0].spansMachines)
        #expect(groups[0].holds(FolderKey(host: devbox, folder: api)))
        #expect(groups[1].main.key == FolderKey(host: .mac, folder: web))
        #expect(SidebarProjects.label(groups[0], projectName: "Agents") { _ in "devbox" } == "Agents")
        #expect(SidebarProjects.label(groups[0], projectName: nil) { _ in "devbox" } == "api",
                "the main folder's name until the project's is read")
        #expect(SidebarProjects.sharedProjects(groups) == ["p"])
    }

    @Test func aSessionOnAnotherMachineOfTheProjectSaysWhich() {
        let model = AgentsModel()
        let here = agent(api, .finished, "here", at: 1)
        let there = agent(api, .finished, "there", at: 2, host: devbox)
        model.replaceAgents([here])
        model.replaceAgents([there], from: devbox)
        let group = SidebarProjects.Group(main: summary(api), others: [summary(api, host: devbox)])
        let fold = SidebarFolderFold(key, label: "Agents", in: model, isOpen: true, on: [],
                                      alsoIn: group.otherKeys)
        #expect(Set(fold.sessions.map(\.title)) == ["here", "there"], "both folders' sessions in the one group")
        let mark: (Agent) -> String? = { SidebarProjects.machineMark(of: $0, in: group) { _ in "devbox" } }
        #expect(fold.sessions.map(mark).compactMap { $0 } == ["devbox"])
        // Two folders on this one machine: no machine to say.
        let local = SidebarProjects.Group(main: summary(api), others: [summary(web)])
        #expect(SidebarProjects.machineMark(of: there, in: local) { _ in "devbox" } == nil)
    }

    @Test func theFoldersListSaysEachFoldersMachineAndState() {
        #expect(SidebarProjects.state(offline: false, workspaceState: nil) == .online)
        #expect(SidebarProjects.state(offline: true, workspaceState: nil) == .offline)
        #expect(SidebarProjects.state(offline: true, workspaceState: "stopped") == .stopped)
        #expect(SidebarProjects.folderLine(summary(api), machine: "devbox", state: .online) == "api — devbox, online")
    }

    // MARK: The project's Connectors row (#3407)

    @Test func theProjectsConnectorsAreThisMachinesFolderElseTheFirstOnline() {
        let elsewhere = MachineRef(rawValue: "cloud001")
        let mac = SidebarProjects.Group(main: summary(api), others: [summary(api, host: devbox)])
        #expect(SidebarProjects.connectorsFolder(mac) { _ in true }.host == .mac)
        let servers = SidebarProjects.Group(main: summary(api, host: devbox), others: [summary(api, host: elsewhere)])
        #expect(SidebarProjects.connectorsFolder(servers) { $0 != devbox }.host == elsewhere,
                "the first folder whose machine answers")
        #expect(SidebarProjects.connectorsFolder(servers) { _ in false }.host == devbox, "none answers: the main one")
    }
}
