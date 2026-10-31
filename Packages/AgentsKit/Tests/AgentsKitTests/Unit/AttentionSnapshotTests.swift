import Foundation
import Testing
@testable import AgentsKitCore

/// What the Home-screen widget is shown, and where it is told to go (068).
///
/// The widget itself cannot be tested here — it is a view over this file — so these are the
/// properties that file has to have for the view to be honest: the count is the count the
/// Dock badge shows, one session is one row whatever it has asked, and a snapshot that is
/// not there is not a zero.
@MainActor
@Suite("What the attention widget is shown")
struct AttentionSnapshotTests {

    private let folder = URL(filePath: "/tmp/work/api")

    private func agent(_ id: UUID = UUID(), state: AgentState = .waitingOnUser,
                       title: String? = "Fix the widget", at: Date = Date(),
                       isUnread: Bool? = nil, report: WorkReport? = nil) -> Agent {
        Agent(id: id, runtimeID: "claude", cwd: folder, title: title, state: state,
              lastActivityAt: at, isUnread: isUnread ?? (state == .finished), report: report)
    }

    private func model(_ agents: [Agent], in summary: DaemonAPI.FolderSummary? = nil) -> AgentsModel {
        let model = AgentsModel()
        model.replaceFolders([summary ?? DaemonAPI.FolderSummary(
            folder: Folder(folder: folder), name: "api", exists: true,
            lastActivityAt: Date(), counts: [:])])
        model.replaceAgents(agents)
        return model
    }

    private func need(_ id: UUID, _ agentID: UUID, kind: Need.Kind = .elicitation,
                      at: Date = Date(), h3: String = "which branch to use") -> Need {
        Need(id: .elicitation(id), agentID: agentID, folder: folder, kind: kind, raisedAt: at,
             headline: Headline(h1: "api", h2: "Fix the widget", h3: h3))
    }

    // MARK: The number

    @Test func theCountIsWhatNeedsYouAndNothingElse() {
        let model = model([agent(), agent(), agent(state: .running), agent(state: .finished, isUnread: false)])
        let snapshot = AttentionSnapshot.make(model: model)
        #expect(snapshot.total == 2, "the two waiting, not the working one and not a finished one nobody has read")
    }

    /// SC-001. The widget and the Dock badge read the same expression, so a change to one
    /// that did not change the other would be a change to this, once.
    @Test func theCountIsTheDockBadgesCount() {
        let model = model([agent(), agent(), agent(state: .running), agent(state: .finished)])
        let badge = model.liveFolders.reduce(0) { $0 + model.attentionCount(in: $1.key) }
        #expect(AttentionSnapshot.make(model: model).total == badge)
    }

    @Test func theHostsCountIsTheBadgesCount() {
        // The daemon counts by `Agent.wantsALook` (#1163); the phone, by its shelves.
        let agents = [agent(state: .waitingOnUser), agent(state: .running), agent(state: .finished),
                      agent(state: .finished, isUnread: false), agent(state: .stopped), agent(state: .queued)]
        #expect(agents.count(where: \.wantsALook) == AttentionSnapshot.make(model: model(agents)).total)
    }

    /// #1565: an unread finish does not need the person. It is a mark on its row, not a
    /// count on the badge or a row in the widget.
    @Test func anUnreadFinishIsNotCounted() {
        let unread = agent(state: .finished, report: WorkReport(outcome: .done, message: "Done", at: Date()))
        let asked = agent(state: .finished, report: WorkReport(outcome: .needsAnswer, message: "Which?", at: Date()))
        let model = model([unread, asked, agent(state: .finished, isUnread: false)])
        #expect(model.agents(in: folder, group: .finished).contains { $0.id == unread.id })
        let snapshot = AttentionSnapshot.make(model: model)
        #expect(snapshot.total == 1, "the question only")
        #expect(snapshot.sessions.map(\.id) == [asked.id])
    }

    @Test func anArchivedFolderIsNotCounted() {
        let model = AgentsModel()
        model.replaceFolders([
            DaemonAPI.FolderSummary(folder: Folder(folder: URL(filePath: "/tmp/work/api")),
                                     name: "api", exists: true, lastActivityAt: Date(), counts: [:]),
            DaemonAPI.FolderSummary(folder: Folder(folder: URL(filePath: "/tmp/work/old"), archivedAt: Date()),
                                     name: "old", exists: true, lastActivityAt: Date(), counts: [:]),
        ])
        model.replaceAgents([agent(), Agent(id: UUID(), runtimeID: "claude",
                                            cwd: URL(filePath: "/tmp/work/old"), title: "Old work",
                                            state: .waitingOnUser, lastActivityAt: Date())])
        #expect(AttentionSnapshot.make(model: model).total == 1)
    }

    // MARK: The rows

    /// FR-005: an agent that asked twice is one session waiting on you, and taking two rows
    /// would make the widget's count and its rows disagree with each other.
    @Test func oneAgentAskingTwiceIsOneRow() {
        let id = UUID()
        let model = model([agent(id)])
        model.replaceAttention(DaemonAPI.AttentionPending(
            needs: [need(UUID(), id), need(UUID(), id, at: Date(timeIntervalSinceNow: -60))],
            deliveries: []))
        let snapshot = AttentionSnapshot.make(model: model)
        #expect(snapshot.total == 1)
        #expect(snapshot.sessions.count == 1)
    }

    @Test("a row carries the words the banner would carry")
    func theRowSaysWhatIsBeingAsked() {
        let id = UUID()
        let model = model([agent(id)])
        model.replaceAttention(DaemonAPI.AttentionPending(needs: [need(UUID(), id, h3: "which branch")],
                                                         deliveries: []))
        let row = try! #require(AttentionSnapshot.make(model: model).sessions.first)
        #expect(row.id == id)
        #expect(row.wanted == "which branch")
        #expect(row.kind == .elicitation)
        #expect(row.folder == "api")
        #expect(row.title == "Fix the widget")
    }

    /// FR-007: a session that stopped with no need pending is in the list, and it is not
    /// given a question it did not ask.
    @Test func aStoppedSessionIsNotGivenAQuestionItDidNotAsk() {
        let model = model([agent(state: .stopped, title: "Rename the thing")])
        let row = try! #require(AttentionSnapshot.make(model: model).sessions.first)
        #expect(row.wanted == nil)
        #expect(row.kind == nil)
        #expect(row.title == "Rename the thing")
    }

    @Test func anAgentWithNoTitleIsStillNamed() {
        let model = model([agent(title: nil)])
        let row = try! #require(AttentionSnapshot.make(model: model).sessions.first)
        #expect(row.title == "Untitled", "the words the app's own card uses")
    }

    /// FR-006: the file names as many as the largest size draws, newest first, and counts
    /// the rest rather than naming them.
    @Test func rowsAreNewestFirstAndCappedWithTheRestCounted() {
        let base = Date(timeIntervalSinceNow: -3600)
        let waiting = (0..<15).map { agent(at: base.addingTimeInterval(Double($0) * 60)) }
        let snapshot = AttentionSnapshot.make(model: model(waiting))
        #expect(snapshot.total == 15)
        #expect(snapshot.sessions.count == AttentionSnapshot.rowLimit)
        #expect(AttentionSnapshot.rowLimit == 12, "bounded by the extra large widget, not by what is waiting")
        let dates = snapshot.sessions.map(\.since)
        #expect(dates == dates.sorted(by: >), "newest first, as the app's own list is")
        #expect(snapshot.sessions.first?.since == waiting.last?.lastActivityAt)
    }

    /// #192: each size draws the newest it has room for and counts the rest, from one file.
    @Test(arguments: [
        (0, [0, 0, 0, 0], [0, 0, 0, 0]),
        (1, [0, 1, 1, 1], [1, 0, 0, 0]),
        (5, [0, 4, 5, 5], [5, 1, 0, 0]),
        (15, [0, 4, 6, 12], [15, 11, 9, 3]),
    ])
    func eachSizeDrawsWhatItHasRoomFor(waiting: Int, drawn: [Int], leftover: [Int]) {
        let base = Date(timeIntervalSinceNow: -3600)
        let snapshot = AttentionSnapshot.make(
            model: model((0..<waiting).map { agent(at: base.addingTimeInterval(Double($0) * 60)) }))
        let sizes: [AttentionSnapshot.Size] = [.small, .medium, .large, .extraLarge]
        #expect(sizes.map { snapshot.rows(for: $0).count } == drawn)
        #expect(sizes.map { snapshot.leftover(for: $0) } == leftover)
        for size in sizes {
            #expect(snapshot.rows(for: size) == Array(snapshot.sessions.prefix(size.rowLimit)),
                    "a smaller size draws the first of the same rows, so medium is what it was")
        }
    }

    /// An app from before #192 wrote four. A large widget draws those four and counts the
    /// rest, rather than drawing nothing until the app catches up.
    @Test func aFileOfFourStillFillsALargeWidgetAsFarAsItGoes() {
        let sessions = (0..<4).map {
            AttentionSnapshotSession(id: UUID(), folder: "api", title: "Row \($0)", wanted: nil,
                                     kind: nil, since: Date())
        }
        let snapshot = AttentionSnapshot(writtenAt: Date(), total: 9, sessions: sessions)
        #expect(snapshot.rows(for: .large).count == 4)
        #expect(snapshot.leftover(for: .large) == 5)
        #expect(snapshot.leftover(for: .medium) == 5)
    }

    @Test func nothingWaitingDrawsNoRowsAndCountsNone() {
        let snapshot = AttentionSnapshot(writtenAt: Date(), total: 0, sessions: [])
        for size in AttentionSnapshot.Size.allCases {
            #expect(snapshot.rows(for: size).isEmpty)
            #expect(snapshot.leftover(for: size) == 0)
        }
    }

    @Test func howLongARowHasWaitedIsShort() {
        let now = Date()
        func waited(_ seconds: TimeInterval) -> String {
            AttentionSnapshotSession(id: UUID(), folder: "api", title: "t", wanted: nil, kind: nil,
                                     since: now.addingTimeInterval(-seconds)).waited(at: now)
        }
        #expect(waited(-30) == "now", "a clock a little ahead is not a negative wait")
        #expect(waited(59) == "now")
        #expect(waited(5 * 60) == "5m")
        #expect(waited(3 * 3600 + 59) == "3h")
        #expect(waited(2 * 86_400) == "2d")
    }

    // MARK: The file

    @Test func aSnapshotGoesOutAndComesBackWhole() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let snapshot = AttentionSnapshot(writtenAt: Date(), total: 2, sessions: [
            AttentionSnapshotSession(id: UUID(), folder: "api", title: "Fix the widget",
                                     wanted: "which branch", kind: .permission, since: Date()),
        ])
        #expect(AttentionSnapshotStore.read(from: directory.url) == nil, "no file is no snapshot, never a zero")
        #expect(AttentionSnapshotStore.write(snapshot, into: directory.url))
        #expect(AttentionSnapshotStore.read(from: directory.url) == snapshot)
        #expect(AttentionSnapshotStore.write(snapshot, into: directory.url) == false,
                "the same thing said again, so nothing is redrawn")
        let moved = AttentionSnapshot(writtenAt: Date(), total: 1, sessions: [])
        #expect(AttentionSnapshotStore.write(moved, into: directory.url),
                "the count moved, so the widget is told")
    }

    @Test func aWriteMakesTheCachesFolderItGoesIn() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let caches = directory.url.appendingPathComponent("Library/Caches", isDirectory: true)
        let snapshot = AttentionSnapshot(writtenAt: Date(), total: 1, sessions: [])
        #expect(AttentionSnapshotStore.write(snapshot, into: caches), "a new group has no Library/Caches yet (#1052)")
        #expect(AttentionSnapshotStore.read(from: caches) == snapshot)
    }

    @Test func aFileThatIsNotASnapshotIsNotOne() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data("not json".utf8).write(to: directory.url.appendingPathComponent(AttentionSnapshotStore.fileName))
        #expect(AttentionSnapshotStore.read(from: directory.url) == nil)
    }

    @Test func anOldSnapshotSaysItIsOld() {
        let fresh = AttentionSnapshot(writtenAt: Date(), total: 1, sessions: [])
        #expect(!fresh.isStale())
        let stale = AttentionSnapshot(writtenAt: Date(timeIntervalSinceNow: -3600), total: 1, sessions: [])
        #expect(stale.isStale())
    }

    // MARK: A push laid over the file (#1046)

    @Test func aPushWithANewNeedChangesTheWrittenSnapshot() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let agentID = UUID()
        let before = AttentionSnapshot.make(model: model([agent(agentID)]), at: Date(timeIntervalSinceNow: -3600))
        #expect(AttentionSnapshotStore.write(before, into: directory.url))
        let need = NeedID.permission(UUID())
        let push = AttentionPush(need: need, headline: Headline(h1: "web", h2: "Tidy CSS", h3: "may it edit files"),
                                 withdrawn: false)
        #expect(AttentionSnapshotStore.apply(push, into: directory.url) != nil)
        let after = try #require(AttentionSnapshotStore.read(from: directory.url))
        #expect(after.total == before.total + 1)
        #expect(after.sessions.first?.title == "Tidy CSS")
        #expect(after.sessions.first?.kind == .permission)
        #expect(after.sessions.first?.link == .need(need.token), "a question's push does not name its session")
        #expect(!after.isStale(), "written now, not when the app last caught up")
        #expect(AttentionSnapshotStore.apply(push, into: directory.url) == nil, "the same push twice is one need")
    }

    @Test func aWithdrawnNeedTakesItsRowAway() throws {
        let agentID = UUID(), questionID = UUID()
        let held = model([agent(agentID)])
        held.replaceAttention(DaemonAPI.AttentionPending(needs: [need(questionID, agentID)], deliveries: []))
        let before = AttentionSnapshot.make(model: held)
        #expect(before.total == 1)
        let push = AttentionPush(need: .elicitation(questionID), headline: nil, withdrawn: true)
        let after = try #require(before.applying(push))
        #expect(after.total == 0)
        #expect(after.sessions.isEmpty)
        #expect(before.applying(AttentionPush(need: .elicitation(UUID()), headline: nil, withdrawn: true)) == nil,
                "a need no row names leaves the count alone")
    }

    @Test func aReportFromASessionAlreadyDrawnIsStillOneRow() throws {
        let agentID = UUID()
        let before = AttentionSnapshot.make(model: model([agent(agentID)]))
        let push = AttentionPush(need: .report(agentID, Date()), headline: nil, withdrawn: false)
        let after = try #require(before.applying(push))
        #expect(after.total == before.total)
        #expect(after.sessions.count == 1)
        #expect(after.sessions.first?.link == .agent(agentID))
    }

    @Test func noFileIsNotMadeUpFromOnePush() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let push = AttentionPush(need: .permission(UUID()), headline: nil, withdrawn: false)
        #expect(AttentionSnapshotStore.apply(push, into: directory.url) == nil)
        #expect(AttentionSnapshotStore.read(from: directory.url) == nil)
    }

    // MARK: The Mac's count (#1163)

    @Test func aPushThatCarriesTheMacsCountWritesItAsTheTruth() throws {
        let one = UUID(), two = UUID(), three = UUID()
        let before = AttentionSnapshot.make(model: model([agent(one), agent(two), agent(three)]),
                                            at: Date(timeIntervalSinceNow: -3600))
        #expect(before.total == 3)
        let counted = Date(timeIntervalSinceNow: -5)
        // Withdrawn, and no row names it: without the count this changed nothing.
        let push = AttentionPush(need: .elicitation(UUID()), headline: nil, withdrawn: true,
                                 count: AttentionCount(waiting: 1, countedAt: counted))
        let after = try #require(before.applying(push))
        #expect(after.total == 1)
        #expect(after.sessions.count == 1, "never more rows than are waiting")
        #expect(after.writtenAt == counted, "as old as the Mac's count, not the push's arrival")
    }

    @Test func aNewNeedWithTheCountIsDrawnAndCountedOnce() throws {
        let agentID = UUID()
        let before = AttentionSnapshot.make(model: model([agent(agentID)]), at: Date(timeIntervalSinceNow: -3600))
        let push = AttentionPush(need: .permission(UUID()), headline: Headline(h1: "web", h2: "Tidy CSS", h3: "edit?"),
                                 withdrawn: false, count: AttentionCount(waiting: 2, countedAt: Date()))
        let after = try #require(before.applying(push))
        #expect(after.total == 2)
        #expect(after.sessions.first?.title == "Tidy CSS")
    }

    @Test func aCountOlderThanTheFileIsNeverShown() throws {
        let now = Date()
        let file = AttentionSnapshot(writtenAt: now, total: 2, sessions: [])
        #expect(file.applying(AttentionCount(waiting: 5, countedAt: now.addingTimeInterval(-60))) == nil)
        let push = AttentionPush(need: .permission(UUID()), headline: nil, withdrawn: false,
                                 count: AttentionCount(waiting: 5, countedAt: now.addingTimeInterval(-60)))
        #expect(file.applying(push) == nil)
        #expect(file.applying(AttentionCount(waiting: 0, countedAt: now.addingTimeInterval(1)))?.total == 0)
    }

    @Test func aSnapshotOlderThanTheFileIsNeverWritten() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let now = Date()
        // A push counted at the Mac a minute after the app last heard from it.
        #expect(AttentionSnapshotStore.write(AttentionSnapshot(writtenAt: now, total: 0, sessions: []), into: directory.url))
        let old = AttentionSnapshot.make(model: model([agent(UUID())]), at: now.addingTimeInterval(-60))
        #expect(!AttentionSnapshotStore.write(old, into: directory.url))
        #expect(AttentionSnapshotStore.read(from: directory.url)?.total == 0)
    }

    @Test func aCountWithNoFileIsTheNumberAndNoRows() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let counted = Date()
        let written = try #require(AttentionSnapshotStore.apply(AttentionCount(waiting: 3, countedAt: counted),
                                                                into: directory.url))
        #expect(written.total == 3)
        #expect(written.sessions.isEmpty)
        #expect(AttentionSnapshotStore.read(from: directory.url) == written)
        #expect(AttentionSnapshotStore.apply(AttentionCount(waiting: 3, countedAt: counted), into: directory.url) == nil,
                "the same count again changes nothing")
    }

    @Test func aCountOfZeroDrawsNoRows() throws {
        let before = AttentionSnapshot.make(model: model([agent(UUID()), agent(UUID())]), at: Date(timeIntervalSinceNow: -60))
        let after = try #require(before.applying(AttentionCount(waiting: 0, countedAt: Date())))
        #expect(after.total == 0)
        #expect(after.sessions.isEmpty)
    }

    @Test(arguments: [0.0, 60, 14 * 60, 15 * 60 + 1, 3 * 3600, 3 * 86_400, -30] as [TimeInterval])
    func theUpdatedLineIsSaidAtEveryAge(age: TimeInterval) {
        let now = Date()
        let snapshot = AttentionSnapshot(writtenAt: now.addingTimeInterval(-age), total: 1, sessions: [])
        switch snapshot.updated(at: now) {
        case .at(let when):
            #expect(age <= AttentionSnapshot.staleness, "the time of day only while fresh")
            #expect(when <= now)
        case .ago(let when):
            #expect(age > AttentionSnapshot.staleness, "how long ago once stale")
            #expect(when <= now)
        }
    }

    // MARK: The link

    @Test func aLinkRoundTrips() throws {
        let id = UUID()
        #expect(AttentionLink.parse(AttentionLink.attention.url) == .attention)
        #expect(AttentionLink.parse(AttentionLink.agent(id).url) == .agent(id))
        #expect(AttentionLink.attention.url.scheme == AttentionLink.scheme)
        let guarded = NeedID.guardedChange(URL(filePath: "/tmp/work/api"), ".agents/folder.json").token
        #expect(AttentionLink.parse(AttentionLink.need(guarded).url) == .need(guarded))
    }

    @Test func aUrlThatIsNotOursIsIgnoredRatherThanGuessedAt() {
        #expect(AttentionLink.parse(URL(string: "https://example.com/agent")!) == nil)
        #expect(AttentionLink.parse(URL(string: "agents://something")!) == nil)
        #expect(AttentionLink.parse(URL(string: "agents://agent/not-a-uuid")!) == nil)
    }
}

/// A folder of its own for a test that writes a file, removed afterwards.
private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
