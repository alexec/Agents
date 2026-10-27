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
        #expect(fold.recentArchived.map(\.id) == archived.suffix(3).reversed().map(\.id))

        let empty = SidebarFolderFold(FolderKey(host: .mac, folder: web), label: "web", in: model, isOpen: true)
        #expect(empty.recentArchived.isEmpty)
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
        #expect(SidebarSmartRow.off(on: [.needsYou, .unread]) == "pinned,working")
        #expect(SidebarSmartRow.on(off: "pinned,working,gone") == [.needsYou, .unread])
        // Nothing kept (#979): Pinned and Needs You on.
        #expect(SidebarSmartRow.on(off: SidebarSmartRow.offAtFirst) == [.pinned, .needsYou])
    }
}
