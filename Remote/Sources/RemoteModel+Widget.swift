import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit
import WidgetKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: The Home-screen widget (068)

    /// Write the file the widget reads, and redraw it if what it says has changed.
    ///
    /// A widget cannot reach the daemon. WidgetKit loads the extension on demand and
    /// kills it without warning, so what it is given has to be something that is already
    /// on disk, and this is the only writer of it (FR-014). Built from the model the
    /// Remote already holds, so the number on the Home screen is the number the Dock
    /// badge shows: the same sum over the same live folders.
    ///
    /// A push is also what tells the app something moved, so this runs on those too
    /// rather than waiting for the person to open the app.
    ///
    /// Dated when the model was last live (#1163), not when it is written: with no link
    /// it is what the phone last heard, and a push the notification extension laid over
    /// the file since is newer, so it stays, and the badge shows it.
    func publishAttention() {
        guard let knownAt = isConnected ? Date() : liveUntil else {
            // Nothing heard since launch: whatever is on file is all there is.
            if let total = AttentionSnapshotStore.read()?.total { notifier.setBadgeCount(total) }
            return
        }
        let snapshot = AttentionSnapshot.make(model: work, at: knownAt)
        // Live, the model is the newest there is. Not, the file may be newer than what
        // was last written here: the extension writes it too.
        if AttentionSnapshotStore.write(snapshot, over: isConnected ? lastPublished : nil) {
            lastPublished = snapshot
            notifier.setBadgeCount(snapshot.total)
            WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
        } else {
            let total = isConnected ? snapshot.total : (AttentionSnapshotStore.read()?.total ?? snapshot.total)
            notifier.setBadgeCount(total)
        }
    }

    /// A tap on the widget: `agents://attention` for the body, `agents://agent/<id>` for
    /// a row.
    ///
    /// A body is showing one number over several folders, so it goes to the first
    /// folder with something waiting, and to the folders page when nothing is waiting
    /// or the app was launched cold and has not heard about any folders yet. A row
    /// names one agent, and `open(_:)` already knows how to get there.
    func openedFromTheWidget(_ url: URL) {
        switch AttentionLink.parse(url) {
        case .agent(let id):
            open(id)
            // A row drawn a few minutes ago can name a session that has gone since, and
            // a tap that names nothing left must not look like a tap that did nothing.
            // `open` has kept the id, so the conversation still opens if the agents are
            // merely late; a folder is shown until then.
            if work.agent(id) == nil { showTheFirstFolderNeedingYou() }
        case .need(let token):
            // A row a push drew without naming its session (#1046).
            if agentID(forNeedToken: token) == nil { showTheFirstFolderNeedingYou() }
            open(needToken: token)
        case .attention:
            showTheFirstFolderNeedingYou()
        case .start:
            lookForShared()
        case nil:
            break
        }
    }

    /// The folders page, with the first folder that has somebody waiting already open.
    func showTheFirstFolderNeedingYou() {
        openWorkflow = nil
        selection = nil
        selectedKey = work.liveFolders.first(where: needsYou)?.key
    }

    /// Whether anything in a folder is waiting on a person: the same sum the widget
    /// shows, asked of one folder. Counted from this model's own grouping, which is the
    /// one that knows whether a person has looked at an agent, and not the counts the
    /// daemon sent.
    func needsYou(_ summary: DaemonAPI.FolderSummary) -> Bool {
        work.attentionCount(in: summary.folder.folder) > 0
    }

    func identify() async {
        _ = try? await client.call(DaemonAPI.Method.surfaceIdentify,
                                   DaemonAPI.SurfaceIdentification(id: deviceID, name: UIDevice.current.name, kind: kind))
    }

    func startPresence() {
        guard presence == nil else { return }
        notifier.authorisationChanged = { [weak self] in self?.presence?.connected() }
        let reporter = PresenceReporter { [weak self] watching, active, mayNotify, showing, popped in
            guard let self else { return }
            // Every host hears whether the person is here; only the open chat's host hears
            // which it is, and that is where its entries and output come from (#203).
            // Sessions in scenes of their own go to their own hosts the same way (#888).
            let hostOf = { (id: UUID) in self.work.agent(id)?.host ?? .mac }
            let owner = showing.map(hostOf)
            let watcher = watching.map(hostOf)
            let poppedHosts = popped.sorted { $0.uuidString < $1.uuidString }.map { ($0, hostOf($0)) }
            func report(for host: MachineRef) -> DaemonAPI.PresenceReport {
                DaemonAPI.PresenceReport(watching: watcher == host ? watching : nil, active: active,
                                         mayNotify: mayNotify, showing: owner == host ? showing : nil,
                                         alsoShowing: poppedHosts.filter { $0.1 == host }.map(\.0))
            }
            _ = try? await self.client.call(DaemonAPI.Method.presenceReport, report(for: .mac))
            for (id, other) in self.otherHosts where self.reachableHosts.contains(id) {
                _ = try? await other.call(DaemonAPI.Method.presenceReport, report(for: id))
            }
        }
        // Scenes of their own restored at launch opened before there was a reporter (#888).
        reporter.popped(Set(popouts.keys), inFront: popoutInFront)
        presence = reporter
    }

    func refreshAttention() async {
        guard let pending = try? await client.call(DaemonAPI.Method.attentionPending,
                                                   Optional<String>.none,
                                                   returning: DaemonAPI.AttentionPending.self) else { return }
        work.replaceAttention(pending)
        toNotifier { [deviceID = self.deviceID] notifier in await notifier.sweep(keeping: pending, me: .device(deviceID)) }
    }

    /// The live agents only, the first page of them. Archived ones outnumber them many
    /// times over and are almost never looked at, so they come when a page asks for them
    /// — a folder's Archived section, a workflow's runs — and not on every connection.
    func refreshAgents() async {
        // Lean: no card or row reads the option and command lists, which were nearly all of
        // each record (#107). The open chat's come with `loadWholeAgent`.
        let page = DaemonAPI.CatchUpRequest.firstPage
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, page, returning: [Agent].self)
        else { return }
        takeLiveAgents(listed, page: page)
        if let selectedFolder { await fillFolder(selectedFolder) }
    }

    /// The first page of live agents, in place of what was held. Archived agents already
    /// fetched are kept only where a screen can still show them: the open folder, and an
    /// open archived chat (#175). One brought back while this phone was away is in the live
    /// list, and that copy wins.
    func takeLiveAgents(_ listed: [Agent], page: DaemonAPI.ListRequest) {
        moreLiveAgents = page.next(after: listed) != nil
        filledFolders = []
        let live = Set(listed.map(\.id))
        let letGo = Set(archivedToLetGo(work.agents, folders: archivedHeldFor, chat: selection))
        // Only this host's: another host's agents come from that host (058, US4).
        let kept = work.agents.filter {
            $0.host == .mac && $0.state == .archived && !live.contains($0.id) && !letGo.contains($0.id)
        }
        work.replaceAgents(listed + kept, from: .mac)
    }

    /// The rest of a folder's live agents, when the first page did not hold them all:
    /// asked as its page opens, once per connection.
    func fillFolder(_ folder: URL) async {
        guard moreLiveAgents, filledFolders.insert(folder).inserted else { return }
        let request = DaemonAPI.ListRequest(includeArchived: false, folder: folder, lean: true)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request, returning: [Agent].self)
        else {
            filledFolders.remove(folder)
            return
        }
        work.takeListed(listed)
    }

    /// A folder page has gone: what only it could show is let go (#175). Its archived
    /// agents, its label suggestions, and the live agents beyond the first page that it
    /// filled in.
    func letGoOfFolders(keeping folder: URL?) {
        work.forget(archivedToLetGo(work.agents, folders: archivedHeld(keeping: folder), chat: selection)
            .filter { !searched.contains($0) })
        labelVocabularies = labelVocabularies.filter { $0.key == folder.map(Folder.standardize) }
        if let folder { Task { await fillFolder(folder) } }
    }

    /// A chat has gone: what was read for it alone is let go (#175). Its earlier marks
    /// for Files, and an archived chat outside the open folder.
    func letGoOfChats(keeping agentID: UUID?) {
        touchedEarlier = touchedEarlier.filter { $0.key == agentID || popouts[$0.key] != nil }
        touchedHistoryAsked = touchedHistoryAsked.filter { $0 == agentID || popouts[$0] != nil }
        work.forget(archivedToLetGo(work.agents, folders: archivedHeldFor, chat: agentID)
            .filter { !searched.contains($0) })
    }

    /// The folders whose archived sessions a screen can show: the open folder, and
    /// every open Archived fold.
    var archivedHeldFor: Set<URL> { archivedHeld(keeping: selectedFolder) }

    func archivedHeld(keeping folder: URL?) -> Set<URL> {
        openArchivedFolds.union(folder.map { [Folder.standardize($0)] } ?? [])
    }

    /// A folder's Archived page has opened: a page of its newest archived sessions, from
    /// the folder's own host (#533). Answers whether the host did (#664).
    @discardableResult
    func loadArchived(in key: FolderKey, limit: Int = SidebarFolderFold.archivedShown) async -> Bool {
        openArchivedFolds.insert(Folder.standardize(key.folder))
        return await loadArchivedAgents(in: key, limit: limit)
    }

    /// The archived sessions of a folder that hold `words`, for the Archived Sessions page's
    /// filter (#4448), as the window asks, so one older than the page held is found too.
    /// Let go with the rest when the page closes. Answers whether the host did.
    @discardableResult
    func searchArchived(in key: FolderKey, words: String) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedCommands: false, archivedOnly: true, folder: key.folder,
                                            limit: Self.searchShown, lean: true, query: words)
        guard let target = hostClient(key.host),
              let listed = try? await target.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return false }
        work.takeListed(listed.map { var agent = $0; agent.host = key.host; return agent })
        return true
    }

    /// A folder's Archived fold has closed: what it held is let go, but for the chat open
    /// and whatever the open folder's pages still show.
    func letGoOfArchived(in folder: URL) {
        let folder = Folder.standardize(folder)
        guard openArchivedFolds.remove(folder) != nil else { return }
        work.forget(archivedToLetGo(work.agents, folders: archivedHeldFor, chat: selection)
            .filter { !searched.contains($0) })
    }

    /// Whether a host has more matches than it has sent: More matches… asks for them.
    var searchHasMore: Bool { !searchNext.isEmpty }

    /// The archived sessions matching `words`, a capped page from every host that answers,
    /// as the window asks (#533); nothing when it is empty.
    func searchSessions(_ words: String) async {
        let earlier = searched
        searched = []
        searchNext = [:]
        if !earlier.isEmpty {
            let unseen = Set(archivedToLetGo(work.agents, folders: archivedHeldFor, chat: selection))
            work.forget(earlier.filter { unseen.contains($0) })
        }
        work.saidLines = [:]
        work.issueSessions = [:]
        work.issueHeadings = []
        guard !words.isEmpty else { return }
        let request = DaemonAPI.ListRequest(archivedCommands: false, limit: Self.searchShown, lean: true, query: words)
        let hosts: [MachineRef] = [.mac] + reachableHosts.sorted { $0.rawValue < $1.rawValue }
        let issue = SessionLabelQuery.issue(in: words)
        for host in hosts {
            await search(request, on: host)
            // The sessions on the issue, its sub-issues and their PRs (#3899), from each host's
            // Lineage, as the window asks. A host too old to say matches the #<n> label only.
            if let issue, self.host(host, has: Capability.lineageSessions1), let target = hostClient(host),
               let on = try? await target.call(DaemonAPI.Method.lineageSessions,
                                               DaemonAPI.LineageSessionsRequest(number: issue),
                                               returning: DaemonAPI.LineageSessions.self),
               !Task.isCancelled {
                work.noteIssueSessions(on)
            }
            // What was said (#1585): the sessions whose prompts or replies hold the words. Not
            // asked of a host too old to say (#1748).
            if self.host(host, has: Capability.agentsSaid1), let target = hostClient(host),
               let said = try? await target.call(DaemonAPI.Method.agentsSaid, DaemonAPI.SaidSearchRequest(text: words),
                                                 returning: DaemonAPI.SaidSearchResult.self),
               !Task.isCancelled {
                for match in said.matches { work.saidLines[match.agentID] = match.line }
            }
        }
    }

    /// The next page from each host that has more, newest first as the host lists them.
    func searchMore() async {
        let next = searchNext
        searchNext = [:]
        for (host, request) in next { await search(request, on: host) }
    }

    func search(_ request: DaemonAPI.ListRequest, on host: MachineRef) async {
        guard let page = await ArchiveActions.searchArchived(request, on: host, fetch: {
            guard let target = self.hostClient(host) else { return nil }
            return try? await target.call(DaemonAPI.Method.agentsList, request, returning: [Agent].self)
        }) else { return }
        searched.formUnion(page.agents.filter { work.agent($0.id) == nil }.map(\.id))
        work.takeListed(page.agents)
        searchNext[host] = page.next
    }

    /// A folder's newest archived sessions, asked of the folder's own host and stamped
    /// as its own, as the window's (#533). Answers whether the host did (#664).
    @discardableResult
    func loadArchivedAgents(in key: FolderKey, limit: Int) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedCommands: false, archivedOnly: true,
                                            folder: key.folder, limit: limit, lean: true)
        guard let target = hostClient(key.host),
              let listed = try? await target.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return false }
        work.takeListed(listed.map { var agent = $0; agent.host = key.host; return agent })
        return true
    }

    /// The client for `host`: the Mac's own, or a server's while it answers.
    func hostClient(_ host: MachineRef) -> DaemonClient? {
        if host == .mac { return client }
        guard reachableHosts.contains(host) else { return nil }
        return otherHosts[host]
    }

    /// A workflow's newest `limit` runs, archived ones included, for its page. Answers
    /// whether there are more than that.
    func loadRuns(of workflowID: String, in folder: URL, limit: Int) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedCommands: false, folder: folder,
                                            startedByWorkflow: workflowID, limit: limit + 1, lean: true)
        guard let listed = try? await client.call(DaemonAPI.Method.agentsList, request,
                                                  returning: [Agent].self) else { return false }
        work.takeListed(Array(listed.prefix(limit)))
        return listed.count > limit
    }

    /// A folder pinned to the top of the sidebar, or not, through its own host.
    func setPinned(_ pinned: Bool, for summary: DaemonAPI.FolderSummary) async {
        let host = summary.host
        guard let target = host == .mac ? client : otherHosts[host] else { return }
        do {
            var changed = try await target.call(DaemonAPI.Method.foldersSetPinned,
                                                DaemonAPI.SetPinnedRequest(folder: summary.folder.folder, pinned: pinned),
                                                returning: DaemonAPI.FolderSummary.self)
            changed.host = host
            work.upsert(changed)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// A folder's helper limits and switches (#64), written into its `.agents/folder.json` by
    /// its own machine, as the window's Project Settings ▸ Work at Once and Sessions set them.
    func setHelperLimits(_ limits: HelperLimits, for key: FolderKey) async {
        guard let target = hostClient(key.host) else {
            problem = "\(hostLabel(key.host)) can't be reached now."
            return
        }
        do {
            var changed = try await target.call(DaemonAPI.Method.foldersSetHelperLimits,
                                                DaemonAPI.SetHelperLimitsRequest(folder: key.folder, limits: limits),
                                                returning: DaemonAPI.FolderSummary.self)
            changed.host = key.host
            work.upsert(changed)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// The machines a folder can be added to (#4036): this Mac first, then each other host
    /// of the control plane, as the sidebar heads them.
    var folderMachines: [HostSection] {
        let sections = hostSections
        return sections.isEmpty ? [HostSection(id: .mac, title: "This Mac", offline: false)] : sections
    }

    /// What is in a folder on `host` (#4036), for Add Folder's picker: `files/browse`, as
    /// the window's server folder sheet reads it.
    func browse(_ path: String, on host: MachineRef) async throws -> DirectoryListing {
        let request = DaemonAPI.FilesBrowseRequest(path: path)
        return try await client(for: request, on: host).call(DaemonAPI.Method.filesBrowse, request,
                                                             returning: DirectoryListing.self)
    }

    /// A folder on `host` added as a folder (#115, #4036), to its default project, and opened.
    /// Answers why not, or nil.
    func addFolder(_ folder: URL, on host: MachineRef) async -> String? {
        await takeNewFolder(on: host) { client in
            try await client.call(DaemonAPI.Method.foldersAdd, DaemonAPI.AddFolderRequest(folder: folder, project: nil),
                                  returning: DaemonAPI.FolderSummary.self)
        }
    }

    /// A Git URL cloned into `host`'s home folder and added as a folder (027, #4036), then
    /// opened. The daemon answers once the clone has finished. Answers why not, or nil.
    func cloneFolder(_ url: String, on host: MachineRef) async -> String? {
        await takeNewFolder(on: host) { client in
            try await client.call(DaemonAPI.Method.foldersClone, DaemonAPI.CloneRequest(url: url),
                                  returning: DaemonAPI.FolderSummary.self)
        }
    }

    func takeNewFolder(on host: MachineRef,
                               _ call: (DaemonClient) async throws -> DaemonAPI.FolderSummary) async -> String? {
        do {
            let target = try client(for: Optional<String>.none, on: host)
            var summary = try await call(target)
            summary.host = host
            work.upsert(summary)
            sidebarItem = .folder(summary.key)
            return nil
        } catch {
            return away(error, "the folder could not be added.") ?? sentence(for: error)
        }
    }

    /// What today has cost and what the reader will allow. The phone shows limits
    /// and never sets them. A daemon too old to know the method leaves this nil, and
    /// every surface shows what it showed before this feature.
    func refreshCostState() async {
        guard let state = try? await client.call(DaemonAPI.Method.costState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.CostState.self) else { return }
        work.replaceCostState(state)
    }

    /// Cancel the wait shown in Waiting now, on the agent's own host (#2068), then refresh
    /// the authoritative list. A failure says why.
    func cancelWait(of agentID: UUID) async {
        let host = work.agent(agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "the wait could not be stopped.")
            return
        }
        do {
            let request = DaemonAPI.CancelWaitRequest(agentID: agentID)
            _ = try await client(for: request).call(DaemonAPI.Method.eventsCancelWait, request,
                                                    returning: [DaemonAPI.WaitingAgent].self)
        } catch {
            problem = away(error, "the wait could not be stopped.") ?? sentence(for: error)
        }
        await refreshEvents()
    }
}
