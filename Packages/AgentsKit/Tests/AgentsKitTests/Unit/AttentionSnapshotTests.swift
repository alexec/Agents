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

    private func model(_ agents: [Agent], in summary: DaemonAPI.ProjectSummary? = nil) -> AgentsModel {
        let model = AgentsModel()
        model.replaceProjects([summary ?? DaemonAPI.ProjectSummary(
            project: Project(folder: folder), name: "api", exists: true,
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
        let badge = model.liveProjects.reduce(0) { $0 + model.attentionCount(in: $1.key) }
        #expect(AttentionSnapshot.make(model: model).total == badge)
    }

    /// #70: an unread finish left Needs you, and is still news: counted and drawn, once.
    @Test func anUnreadFinishIsCountedThoughItIsDone() {
        let unread = agent(state: .finished, report: WorkReport(outcome: .done, message: "Done", at: Date()))
        let asked = agent(state: .finished, report: WorkReport(outcome: .needsAnswer, message: "Which?", at: Date()))
        let model = model([unread, asked, agent(state: .finished, isUnread: false)])
        #expect(model.agents(in: folder, group: .finished).contains { $0.id == unread.id })
        let snapshot = AttentionSnapshot.make(model: model)
        #expect(snapshot.total == 2, "the unread one and the question, each once")
        #expect(Set(snapshot.sessions.map(\.id)) == [unread.id, asked.id])
    }

    @Test func anArchivedProjectIsNotCounted() {
        let model = AgentsModel()
        model.replaceProjects([
            DaemonAPI.ProjectSummary(project: Project(folder: URL(filePath: "/tmp/work/api")),
                                     name: "api", exists: true, lastActivityAt: Date(), counts: [:]),
            DaemonAPI.ProjectSummary(project: Project(folder: URL(filePath: "/tmp/work/old"), archivedAt: Date()),
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
        #expect(row.project == "api")
        #expect(row.title == "Fix the widget")
    }

    /// FR-007: a finished turn nobody has read is in the list, and it is not given a
    /// question it did not ask.
    @Test func aFinishedSessionIsNotGivenAQuestionItDidNotAsk() {
        let model = model([agent(state: .finished, title: "Rename the thing")])
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

    /// FR-006: four rows fit, and the rest are counted rather than drawn.
    @Test func rowsAreNewestFirstAndCappedWithTheRestCounted() {
        let base = Date(timeIntervalSinceNow: -3600)
        let waiting = (0..<6).map { agent(at: base.addingTimeInterval(Double($0) * 60)) }
        let snapshot = AttentionSnapshot.make(model: model(waiting))
        #expect(snapshot.total == 6)
        #expect(snapshot.sessions.count == 4)
        #expect(snapshot.leftover == 2)
        let dates = snapshot.sessions.map(\.since)
        #expect(dates == dates.sorted(by: >), "newest first, as the app's own list is")
    }

    // MARK: The file

    @Test func aSnapshotGoesOutAndComesBackWhole() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let snapshot = AttentionSnapshot(writtenAt: Date(), total: 2, sessions: [
            AttentionSnapshotSession(id: UUID(), project: "api", title: "Fix the widget",
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

    // MARK: The link

    @Test func aLinkRoundTrips() throws {
        let id = UUID()
        #expect(AttentionLink.parse(AttentionLink.attention.url) == .attention)
        #expect(AttentionLink.parse(AttentionLink.agent(id).url) == .agent(id))
        #expect(AttentionLink.attention.url.scheme == AttentionLink.scheme)
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
