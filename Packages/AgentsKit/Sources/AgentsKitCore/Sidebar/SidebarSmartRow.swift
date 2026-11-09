import Foundation

/// One of the rows at the top of the sidebar that gather sessions across every folder
/// and host (#495): Pinned, then by what they want — Needs You, For Review, Working,
/// Unread. Mail's Favorites and smart mailboxes, Things' Inbox and Today.
///
/// Needs You holds everything waiting for the person (#773): sessions asking a question or
/// blocked, sessions asking to be archived (#584, #649, once their own group), and each
/// folder's `approvals` — MCP servers, workflows, plugins and guarded files, and workflows
/// that failed (#989) — as rows of their own. A failed run's agent is its workflow's row,
/// not a session row as well. Each open request to the person (#3864) is a row of its own
/// too, before the sessions, and stands for its asker in the same way.
///
/// For Review (#3194) holds what is ready to look at but blocks no agent: today, a session
/// that ended done with a file it showed that nobody has opened (`fileToSee`), the daily
/// summary's too. Opening it, or Mark as Read, its Dismiss, takes it out. After its sessions,
/// each folder's open pull requests labelled needs-approval (#3330), until they are answered,
/// closed or dismissed, then the read-only daily checks' suggestions (#3331), until one is
/// started or dismissed.
///
/// Read off each folder's shelf (#165), so a folded smart row costs a sum of counts per
/// folder and not a pass over every agent held; only an open one lists its sessions.
public enum SidebarSmartRow: String, CaseIterable, Hashable, Sendable {
    /// The pinned sessions (#180) and workflows (#432) of every folder, in the folders'
    /// order and each folder's pin order. Out of their folders' groups (Alex, #495).
    case pinned
    case needsYou, forReview, working, unread

    public var title: String {
        switch self {
        case .pinned: "Pinned"
        case .needsYou: "Needs You"
        case .forReview: "For Review"
        case .working: "Working"
        case .unread: "Unread"
        }
    }

    /// Every group, on.
    public static let all = Set(allCases)

    /// Where each device keeps the groups turned off (#846): their raw values, comma-
    /// separated, so a group added later starts on. A device's own choice; the web page keeps the same in its local storage.
    public static let offDefaultsKey = "sidebarSmartGroupsOff"

    /// What a device with nothing kept under `offDefaultsKey` reads (#979): Working and
    /// Unread off, Pinned, Needs You and For Review (#3194) on. Every `@AppStorage(offDefaultsKey)` starts with
    /// it; a device that keeps a choice, `""` (every group on) too, keeps it.
    public static let offAtFirst = "working,unread"

    /// The groups on, from what the defaults keep under `offDefaultsKey`.
    public static func on(off raw: String) -> Set<SidebarSmartRow> {
        all.subtracting(raw.split(separator: ",").compactMap { SidebarSmartRow(rawValue: String($0)) })
    }

    /// What the defaults keep under `offDefaultsKey` for the groups on, in the sidebar's order.
    public static func off(on: Set<SidebarSmartRow>) -> String {
        allCases.filter { !on.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// Needs You starts open, so the first thing the window says is who is waiting, and
    /// For Review after it (#3194); the others start folded, their counts in sight.
    public var startsOpen: Bool { self == .pinned || self == .needsYou || self == .forReview }

    /// How many sessions it gathers across the folders named, and for Needs You the
    /// approvals besides.
    @MainActor
    public func count(in work: AgentsModel, folders: [FolderKey], on: Set<SidebarSmartRow> = all) -> Int {
        if on != Self.all, self != .pinned {
            // With a group off, its sessions go to the next one they fit (#846): a pass
            // over the live sessions, not the shelf's sums, which are for all four.
            return agents(in: work, folders: folders, on: on).count
                + (self == .needsYou ? folders.reduce(work.terminalRequests.count) { $0 + Self.ownApprovals(in: work, $1).count
                    + work.requests(in: $1.folder).count } : 0)
                + pulls(in: work, folders: folders).count + suggestions(in: work, folders: folders).count
        }
        return folders.reduce(self == .needsYou ? work.terminalRequests.count : 0) { total, key in
            let shelf = work.shelf(key)
            if self == .pinned {
                return total + Self.pinnedSessions(in: work, key).count + Self.pinnedWorkflows(in: work, key).count
            }
            // Less the pinned that would be here: they are listed once, in Pinned (#587).
            let pinnedHere = Self.pinnedSessions(in: work, key).count {
                Self.home(of: $0, in: work.group(of: $0), isPinned: false) == self
            }
            switch self {
            case .needsYou:
                // Less the failed runs' agents: their workflows' rows stand for them (#989).
                let failedHere = Self.failedRuns(in: work, key).count { id in
                    work.agent(id).map { Self.home(of: $0, in: work.group(of: $0), isPinned: false) == .needsYou
                        && !work.pinnedSessions(in: key.folder).contains(id) } ?? false
                }
                return total + (shelf.counts[.needsAttention] ?? 0) + (shelf.counts[.blocked] ?? 0)
                    + Self.askingAtRest(in: shelf) + Self.ownApprovals(in: work, key).count - pinnedHere - failedHere
                    + Self.requestShift(in: work, key)
            case .forReview:
                return total + Self.forReview(in: shelf).count + work.reviewPulls(in: key.folder).count
                    + work.checkSuggestions(in: key.folder).count - pinnedHere
            case .working:
                return total + (shelf.counts[.running] ?? 0) - pinnedHere
            case .unread:
                return total + Self.unreadAtRest(in: shelf)
                    - Self.forReview(in: shelf).count(where: \.showsUnread) - pinnedHere
            case .pinned:
                return total
            }
        }
    }

    /// Where a live session is listed (#587): once, in the first of the smart groups it
    /// belongs to — Pinned, Needs You (asking, blocked, or asking to be archived, #773),
    /// For Review (done, with a file to see, #3194), Working, Unread — or, in none of
    /// them, under its folder. Nil for its folder.
    /// A group turned off (#846) is passed over: its sessions go to the next one they
    /// fit, so one unread that asks to be archived goes to Unread with Needs You off.
    public static func home(of agent: Agent, in group: AgentGroup, isPinned: Bool,
                            on: Set<SidebarSmartRow> = all) -> SidebarSmartRow? {
        if group == .archived { return nil }
        if isPinned, on.contains(.pinned) { return .pinned }
        let waits = group == .needsAttention || group == .blocked || (group != .running && agent.asksToArchive)
        if waits, on.contains(.needsYou) { return .needsYou }
        if isForReview(agent, in: group), on.contains(.forReview) { return .forReview }
        if group == .running, on.contains(.working) { return .working }
        return agent.showsUnread && on.contains(.unread) ? .unread : nil
    }

    /// Whether a session goes to For Review when nothing before it takes it (#3194): done,
    /// with a file it showed that nobody has opened. Reading it clears the file (#1802). Not
    /// the daily summary's, whose page is the Summary row (#3721).
    public static func isForReview(_ agent: Agent, in group: AgentGroup) -> Bool {
        group == .finished && agent.fileToSee != nil && !agent.writesDailySummary
    }

    /// The group that keeps a session opened from the sidebar while it is open (#495): For
    /// review when it had a file to see and that group is on (#3194), else Unread.
    public static func keeper(fileToSee: Bool, on: Set<SidebarSmartRow> = all) -> SidebarSmartRow {
        fileToSee && on.contains(.forReview) ? .forReview : .unread
    }

    /// The session Unread keeps (#495): opened from it, read now, and listed there until
    /// another is opened, so it does not leave under the pointer. Until then it is not under
    /// its folder too (#689). Nil while searching, or once it belongs elsewhere: archived,
    /// pinned, waiting, working or asking to be archived. For Review keeps the one opened
    /// from it in the same way (`keeper`, #3194); `keptBy` is the group asking.
    @MainActor
    public static func keptInUnread(_ id: UUID?, in work: AgentsModel, query: String = "",
                                    on: Set<SidebarSmartRow> = all, keptBy: SidebarSmartRow = .unread) -> Agent? {
        guard on.contains(keptBy), query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let id,
              let kept = work.agent(id), kept.state != .archived,
              !(on.contains(.pinned) && work.pinnedSessions(in: kept.folderPath).contains(id)) else { return nil }
        switch home(of: kept, in: work.group(of: kept), isPinned: false, on: on) {
        case nil, .unread, .forReview: return kept
        default: return nil
        }
    }

    /// For Review's share of one folder's sessions (#3194): done, with a file to see, and
    /// not asking to be archived, which is Needs You's.
    @MainActor
    static func forReview(in shelf: FolderShelf) -> [Agent] {
        (shelf.groups[.finished] ?? []).filter { isForReview($0, in: .finished) && !$0.asksToArchive }
    }

    /// The groups whose sessions go to Needs You or Working whatever else they are.
    static let busyGroups: [AgentGroup] = [.needsAttention, .blocked, .running]

    /// The unread that are neither waiting on a person nor working nor asking to be
    /// archived: Unread's share. The busy groups are few, so this is the shelf's count
    /// less a short count of theirs.
    @MainActor
    static func unreadAtRest(in shelf: FolderShelf) -> Int {
        shelf.unread - busyGroups.reduce(0) { $0 + (shelf.groups[$1] ?? []).count(where: \.showsUnread) }
            - (shelf.groups[.archived] ?? []).count(where: \.showsUnread)
            - AgentGroup.live.filter { !busyGroups.contains($0) }
                .reduce(0) { $0 + (shelf.groups[$1] ?? []).count { $0.showsUnread && $0.asksToArchive } }
    }

    /// Those asking to be archived that are neither waiting on a person nor working: Needs
    /// You's share of them (#584, #773).
    @MainActor
    static func askingAtRest(in shelf: FolderShelf) -> Int {
        shelf.asking - busyGroups.reduce(0) { $0 + (shelf.groups[$1] ?? []).count(where: \.asksToArchive) }
    }

    /// Whether the sidebar draws it at all (#507): only with something in it, and while
    /// searching only with a match. Its count is a sum of counts; a search, already
    /// filtering every list, filters this one too.
    @MainActor
    public func isShown(in work: AgentsModel, folders: [FolderKey], query: String = "",
                        on: Set<SidebarSmartRow> = all) -> Bool {
        guard on.contains(self) else { return false }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return count(in: work, folders: folders, on: on) > 0
        }
        return !agents(in: work, folders: folders, query: query, on: on).isEmpty
            || !workflows(in: work, folders: folders, query: query).isEmpty
            || !approvals(in: work, folders: folders, query: query).isEmpty
            || !requests(in: work, folders: folders, query: query).isEmpty
            || !pulls(in: work, folders: folders, query: query).isEmpty
            || !suggestions(in: work, folders: folders, query: query).isEmpty
    }

    /// The sessions it gathers, newest started first, as a search leaves them.
    @MainActor
    public func agents(in work: AgentsModel, folders: [FolderKey], query: String = "",
                       on: Set<SidebarSmartRow> = all) -> [Agent] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = words.isEmpty ? nil : SessionLabelQuery(words, said: work.saidLines, onIssue: work.issueSessions)
        guard on.contains(self) else { return [] }
        // A search for an epic lists its sessions under their issues in the folders (#3900).
        if matcher != nil, SidebarIssueGroup.isOn(query: words, in: work) { return [] }
        if on != Self.all, self != .pinned {
            // A group off (#846): each live session goes where `home` puts it.
            let gathered = folders.flatMap { key -> [Agent] in
                let shelf = work.shelf(key)
                let pinned = Set(work.pinnedSessions(in: key.folder))
                let failed = self == .needsYou ? Self.failedRuns(in: work, key).union(Self.askers(in: work, key)) : []
                return AgentGroup.live.flatMap { group in
                    (shelf.groups[group] ?? []).filter {
                        Self.home(of: $0, in: group, isPinned: pinned.contains($0.id), on: on) == self
                            && !failed.contains($0.id)
                    }
                }
            }
            let shown = matcher.map { gathered.filter($0.matches) } ?? gathered
            return shown.sorted { $0.createdAt > $1.createdAt }
        }
        if self == .pinned {
            // In pin order, not by start: the order they were put in is the point.
            let pinned = folders.flatMap { Self.pinnedSessions(in: work, $0) }
            return matcher.map { pinned.filter($0.matches) } ?? pinned
        }
        let gathered = folders.flatMap { key -> [Agent] in
            let shelf = work.shelf(key)
            let held: [Agent] = switch self {
            case .pinned: []
            case .needsYou: (shelf.groups[.needsAttention] ?? []) + (shelf.groups[.blocked] ?? [])
                + AgentGroup.live.filter { !Self.busyGroups.contains($0) }
                .flatMap { shelf.groups[$0] ?? [] }.filter(\.asksToArchive)
            case .forReview: Self.forReview(in: shelf)
            case .working: shelf.groups[.running] ?? []
            case .unread: AgentGroup.live.filter { !Self.busyGroups.contains($0) }
                .flatMap { group in (shelf.groups[group] ?? []).filter { !Self.isForReview($0, in: group) } }
                .filter { $0.showsUnread && !$0.asksToArchive }
            }
            // A pinned session is listed in Pinned and nowhere else (#587); a failed run's
            // agent, as its workflow's row (#989); an asker, as its requests' rows (#3864).
            let hidden = Set(work.pinnedSessions(in: key.folder))
                .union(self == .needsYou ? Self.failedRuns(in: work, key).union(Self.askers(in: work, key)) : [])
            return hidden.isEmpty ? held : held.filter { !hidden.contains($0.id) }
        }
        let shown = matcher.map { gathered.filter($0.matches) } ?? gathered
        return shown.sorted { $0.createdAt > $1.createdAt }
    }

    /// The pinned workflows of the folders named, each with its folder, in pin order:
    /// only Pinned gathers workflows.
    @MainActor
    public func workflows(in work: AgentsModel, folders: [FolderKey], query: String = "")
        -> [(folder: FolderKey, workflow: WorkflowSummary)] {
        guard self == .pinned else { return [] }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = words.isEmpty ? nil : SessionLabelQuery(words, said: work.saidLines, onIssue: work.issueSessions)
        return folders.flatMap { key in
            Self.pinnedWorkflows(in: work, key)
                .filter { matcher?.matches($0) ?? true }
                .map { (folder: key, workflow: $0) }
        }
    }

    /// What waits for an OK in the folders named, each with its folder (#773): only Needs
    /// You lists them, oldest first, after its sessions. A search matches the title, the
    /// kind and the grey line.
    @MainActor
    public func approvals(in work: AgentsModel, folders: [FolderKey], query: String = "")
        -> [(folder: FolderKey, approval: Approval)] {
        guard self == .needsYou else { return [] }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folders.flatMap { key in
            Self.ownApprovals(in: work, key)
                .filter { words.isEmpty || "\($0.title) \($0.kindWord) \($0.line)".lowercased().contains(words) }
                .map { (folder: key, approval: $0) }
        }
        .sorted { ($0.approval.since ?? .distantPast) < ($1.approval.since ?? .distantPast) }
    }

    /// The open requests to the person in the folders named, each with its folder (#3864):
    /// only Needs You lists them, oldest first, before its sessions. A search matches the
    /// title and the kind. A terminal's (#4179) is in no folder: its folder is the personal
    /// home, which names no place.
    @MainActor
    public func requests(in work: AgentsModel, folders: [FolderKey], query: String = "")
        -> [(folder: FolderKey, request: NeedRequest)] {
        guard self == .needsYou else { return [] }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terminal = work.terminalRequests.map { (folder: FolderKey(folder: $0.folder), request: $0) }
        return (terminal + folders.flatMap { key in
            work.requests(in: key.folder).map { (folder: key, request: $0) }
        })
        .filter { words.isEmpty || "\($0.request.title) \($0.request.kindWord)".lowercased().contains(words) }
        .sorted { $0.request.askedAt < $1.request.askedAt }
    }

    /// The sessions of one folder that asked an open request (#3864): Needs You lists its
    /// requests' rows for each, and not a session row too.
    @MainActor
    public static func askers(in work: AgentsModel, _ key: FolderKey) -> Set<UUID> {
        Set(work.requests(in: key.folder).compactMap(\.askedBy))
    }

    /// What one folder's requests change in Needs You's count and the badge (#3864): one for
    /// each request, less each asker that Needs You would have counted as a session.
    @MainActor
    public static func requestShift(in work: AgentsModel, _ key: FolderKey) -> Int {
        let askers = askers(in: work, key)
        guard !askers.isEmpty else { return 0 }
        let pinned = Set(work.pinnedSessions(in: key.folder))
        let counted = askers.count { id in
            guard let agent = work.agent(id), !pinned.contains(id) else { return false }
            return home(of: agent, in: work.group(of: agent), isPinned: false) == .needsYou
        }
        return work.requests(in: key.folder).count - counted
    }

    /// The pull requests waiting for the person's approval in the folders named, each with
    /// its folder (#3330): only For Review lists them, newest first, after its sessions. A
    /// search matches the title, the repo and the number.
    @MainActor
    public func pulls(in work: AgentsModel, folders: [FolderKey], query: String = "")
        -> [(folder: FolderKey, pull: ReviewPull)] {
        guard self == .forReview else { return [] }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folders.flatMap { key in
            work.reviewPulls(in: key.folder)
                .filter { words.isEmpty || "\($0.title) \($0.repo) #\($0.number)".lowercased().contains(words) }
                .map { (folder: key, pull: $0) }
        }
        .sorted { $0.pull.updatedAt > $1.pull.updatedAt }
    }

    /// The read-only daily checks' suggestions in the folders named, each with its folder
    /// (#3331): only For Review lists them, after its pull requests, the urgent first, then
    /// newest first. A search matches the title and the prompt.
    @MainActor
    public func suggestions(in work: AgentsModel, folders: [FolderKey], query: String = "")
        -> [(folder: FolderKey, suggestion: CheckSuggestion)] {
        guard self == .forReview else { return [] }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folders.flatMap { key in
            work.checkSuggestions(in: key.folder)
                .filter { words.isEmpty || "\($0.title) \($0.prompt)".lowercased().contains(words) }
                .map { (folder: key, suggestion: $0) }
        }
        .sorted { a, b in
            let (ua, ub) = (a.suggestion.urgent ?? false, b.suggestion.urgent ?? false)
            return ua != ub ? ua : a.suggestion.at > b.suggestion.at
        }
    }

    /// One folder's approvals drawn as rows of their own: every kind but a session's
    /// archive request, which is the session's row (`home`).
    @MainActor
    public static func ownApprovals(in work: AgentsModel, _ key: FolderKey) -> [Approval] {
        (work.folder(key)?.approvals ?? []).filter { !$0.isSession }
    }

    /// The agents of one folder's failed workflow runs (#989): Needs You lists each as its
    /// workflow's row, which opens it, and not as a session too.
    @MainActor
    public static func failedRuns(in work: AgentsModel, _ key: FolderKey) -> Set<UUID> {
        Set((work.folder(key)?.approvals ?? []).filter { $0.kind == .workflowFailed }.compactMap(\.agentID))
    }

    /// One folder's pinned sessions held and not archived, in the order they were put in.
    @MainActor
    public static func pinnedSessions(in work: AgentsModel, _ key: FolderKey) -> [Agent] {
        work.pinnedSessions(in: key.folder).compactMap { work.agent($0) }
            .filter { $0.host == key.host && $0.state != .archived }
    }

    /// One folder's pinned workflows held and not archived, in their order.
    @MainActor
    public static func pinnedWorkflows(in work: AgentsModel, _ key: FolderKey) -> [WorkflowSummary] {
        let held = work.workflows(in: key.folder)
        return work.pinnedWorkflows(in: key.folder).compactMap { id in
            held.first { $0.workflowID == id && !$0.isArchived }
        }
    }
}
