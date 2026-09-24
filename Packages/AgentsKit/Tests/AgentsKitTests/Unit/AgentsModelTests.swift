import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a notification from the daemon does to a client.
///
/// This is the file the Mac's window and the phone now share, so these are the
/// properties both of them have. Before it existed the window had its own copy of this
/// switch and the phone would have grown a second one; the case worth remembering is
/// `agent/permission` with no request, which means "answered, stop asking" and not
/// "nothing is waiting".
@MainActor
@Suite("What a notification means to a client")
struct AgentsModelTests {
    private let folder = URL(filePath: "/tmp/work/api")

    private func agent(_ id: UUID = UUID(), state: AgentState = .running,
                       cwd: URL? = nil, at: Date = Date()) -> Agent {
        Agent(id: id, runtimeID: "claude", cwd: cwd ?? folder, title: "Something",
              state: state, lastActivityAt: at)
    }

    private func notification(_ value: some Encodable) throws -> JSONValue {
        try JSONValue.encoding(value)
    }

    @Test func anAgentThatChangesIsFiledOnceAndNotTwice() throws {
        let model = AgentsModel()
        let id = UUID()
        model.apply(DaemonAPI.Notification.agentChanged, try notification(agent(id)))
        model.apply(DaemonAPI.Notification.agentChanged,
                    try notification(agent(id, state: .finished)))
        #expect(model.agents.count == 1)
        #expect(model.agents.first?.state == .finished)
    }

    @Test func agentsAreKeptNewestFirst() throws {
        let model = AgentsModel()
        let old = agent(at: Date(timeIntervalSinceNow: -600))
        let new = agent(at: Date())
        model.apply(DaemonAPI.Notification.agentChanged, try notification(old))
        model.apply(DaemonAPI.Notification.agentChanged, try notification(new))
        #expect(model.agents.first?.id == new.id)
    }

    /// The case this file exists for. A withdrawal carries no request, and a client
    /// that read it as "nothing to do" would leave the question on screen for somebody
    /// to answer a second time.
    @Test func aWithdrawnQuestionTakesTheOneThatWasWaiting() throws {
        let model = AgentsModel()
        let id = UUID()
        let question = PermissionRequest(
            agentID: id,
            toolCall: ToolCall(title: "Run `git push`"),
            options: [PermissionOption(optionID: "y", name: "Allow", kind: .allowOnce)])
        model.apply(DaemonAPI.Notification.agentPermission,
                    try notification(DaemonAPI.PermissionNotification(agentID: id, request: question)))
        #expect(model.permission(for: id) != nil)

        model.apply(DaemonAPI.Notification.agentPermission,
                    try notification(DaemonAPI.PermissionNotification(agentID: id, request: nil)))
        #expect(model.permission(for: id) == nil)
        #expect(model.permissions.isEmpty)
    }

    /// One question per agent. A second one replaces the first rather than stacking up
    /// behind it, because the runtime is blocked on the newest.
    @Test func oneAgentHasOneQuestion() throws {
        let model = AgentsModel()
        let id = UUID()
        for title in ["First", "Second"] {
            model.apply(DaemonAPI.Notification.agentPermission,
                        try notification(DaemonAPI.PermissionNotification(
                            agentID: id,
                            request: PermissionRequest(agentID: id,
                                                       toolCall: ToolCall(title: title),
                                                       options: []))))
        }
        #expect(model.permissions.count == 1)
        #expect(model.permission(for: id)?.toolCall.title == "Second")
    }

    /// Transcript is kept for the conversation being read and for no other, which is
    /// what keeps a phone's data bill small and a window's memory flat.
    @Test func onlyTheConversationBeingReadKeepsItsEntries() throws {
        let model = AgentsModel()
        let watched = UUID()
        let other = UUID()
        model.watching = watched
        model.apply(DaemonAPI.Notification.agentEntry,
                    try notification(DaemonAPI.EntryNotification(
                        agentID: watched,
                        entry: TranscriptEntry(kind: .agentMessage(messageID: nil, text: "Mine")))))
        model.apply(DaemonAPI.Notification.agentEntry,
                    try notification(DaemonAPI.EntryNotification(
                        agentID: other,
                        entry: TranscriptEntry(kind: .agentMessage(messageID: nil, text: "Not mine")))))
        #expect(model.entries.count == 1)
    }

    @Test func changingTheConversationThrowsAwayThePageBeforeIt() throws {
        let model = AgentsModel()
        model.watching = UUID()
        model.replaceTranscript(with: TranscriptPage(
            firstIndex: 40, total: 60,
            entries: [TranscriptEntry(kind: .agentMessage(messageID: nil, text: "Old"))]))
        #expect(!model.entries.isEmpty)
        #expect(model.hasMoreBefore)

        model.watching = UUID()
        #expect(model.entries.isEmpty)
        #expect(!model.hasMoreBefore)
        #expect(model.firstEntryIndex == 0)
    }

    @Test func anEarlierPageGoesInFrontAndMovesTheMark() {
        let model = AgentsModel()
        model.replaceTranscript(with: TranscriptPage(
            firstIndex: 10, total: 20,
            entries: [TranscriptEntry(kind: .agentMessage(messageID: nil, text: "Later"))]))
        model.prepend(TranscriptPage(
            firstIndex: 0, total: 20,
            entries: [TranscriptEntry(kind: .agentMessage(messageID: nil, text: "Earlier"))]))
        #expect(model.entries.count == 2)
        #expect(model.entries.first?.text == "Earlier")
        #expect(model.firstEntryIndex == 0)
        #expect(!model.hasMoreBefore)
    }

    /// An agent's `cwd` is whatever it was started with and a project's folder is the
    /// resolved form. Comparing them raw is how a project looks empty while its agents
    /// are plainly running.
    @Test func anAgentIsFoundByItsProjectHoweverTheFolderWasWritten() throws {
        let model = AgentsModel()
        model.apply(DaemonAPI.Notification.agentChanged,
                    try notification(agent(cwd: URL(filePath: "/tmp/work/api/"))))
        #expect(model.agents(in: URL(filePath: "/tmp/work/./api"), group: .running).count == 1)
    }

    @Test func usageLandsOnTheAgentItIsAbout() throws {
        let model = AgentsModel()
        let id = UUID()
        model.apply(DaemonAPI.Notification.agentChanged, try notification(agent(id)))
        model.apply(DaemonAPI.Notification.agentUsage,
                    try notification(DaemonAPI.UsageNotification(
                        agentID: id, usage: Usage(used: 100, size: 1_000))))
        #expect(model.agent(id)?.usage?.used == 100)
    }

    /// FR-020: the number on the row is the number of rows under the heading, for
    /// every heading, including the one an agent is under only because it asked to
    /// be looked at — the fact the daemon's own counts cannot see.
    @Test func theCountsAreTheListUnderEveryHeading() throws {
        let model = AgentsModel()
        for state in AgentState.allCases {
            model.apply(DaemonAPI.Notification.agentChanged, try notification(agent(state: state)))
        }
        let shown = agent(state: .running)
        model.apply(DaemonAPI.Notification.agentChanged, try notification(shown))
        model.apply(DaemonAPI.Notification.agentShowFile,
                    try notification(DaemonAPI.ShowFileNotification(
                        agentID: shown.id, file: ShownFile(path: "/tmp/work/api/main.swift"))))

        let counts = model.counts(in: folder)
        for group in AgentGroup.allCases {
            #expect(counts[group] ?? 0 == model.agents(in: folder, group: group).count, "\(group)")
        }
        #expect(model.agents(in: folder, group: .needsAttention).contains { $0.id == shown.id })
        #expect(!model.agents(in: folder, group: .running).contains { $0.id == shown.id })
    }

    /// The unread count is the finished chats the daemon has flagged, and only those
    /// under Complete: one flagged but wanting eyes is under Needs attention instead.
    @Test func unreadCountsFlaggedFinishedChatsUnderComplete() throws {
        let model = AgentsModel()
        var unread = agent(state: .finished); unread.isUnread = true
        var read = agent(state: .finished); read.isUnread = false
        var wanted = agent(state: .finished); wanted.isUnread = true
        for one in [unread, read, wanted] {
            model.apply(DaemonAPI.Notification.agentChanged, try notification(one))
        }
        model.apply(DaemonAPI.Notification.agentShowFile,
                    try notification(DaemonAPI.ShowFileNotification(
                        agentID: wanted.id, file: ShownFile(path: "/tmp/work/api/main.swift"))))
        #expect(model.unreadCount(in: folder) == 1)
    }

    /// US2: an agent that asked to be looked at and was then stopped wants nobody,
    /// because the grouping consults its state and the count is the grouping.
    @Test func aStoppedAgentThatAskedToBeLookedAtIsNotWanted() throws {
        let model = AgentsModel()
        let stopped = agent(state: .stopped)
        model.apply(DaemonAPI.Notification.agentChanged, try notification(stopped))
        model.apply(DaemonAPI.Notification.agentShowFile,
                    try notification(DaemonAPI.ShowFileNotification(
                        agentID: stopped.id, file: ShownFile(path: "/tmp/work/api/main.swift"))))

        #expect((model.counts(in: folder)[.needsAttention] ?? 0) == 0)
        #expect(model.agents(in: folder, group: .stopped).map(\.id) == [stopped.id])
    }

    /// A file an agent asked to be looked at is taken, not read: one that has been put
    /// in front of somebody is not still waiting to be.
    @Test func aFileToShowIsHandedOverOnce() throws {
        let model = AgentsModel()
        let id = UUID()
        model.apply(DaemonAPI.Notification.agentShowFile,
                    try notification(DaemonAPI.ShowFileNotification(
                        agentID: id, file: ShownFile(path: "/tmp/work/api/main.swift"))))
        #expect(model.takeFileToShow(for: id) != nil)
        #expect(model.takeFileToShow(for: id) == nil)
    }

    /// The Mac has notifications of its own — shells, terminals — and a client that
    /// claimed them would swallow them. Anything unknown is handed back.
    @Test func aNotificationThisDoesNotKnowIsHandedBack() {
        let model = AgentsModel()
        #expect(model.apply(DaemonAPI.Notification.shellOutput, nil) == false)
        #expect(model.apply("something/nobodyHasWrittenYet", nil) == false)
    }

    /// Ours, but unreadable. Skipped rather than guessed at, and never handed on as if
    /// nobody had claimed it.
    @Test func aNotificationWeKnowButCannotReadIsSkippedRatherThanPassedOn() {
        let model = AgentsModel()
        #expect(model.apply(DaemonAPI.Notification.agentChanged, .string("not an agent")) == true)
        #expect(model.agents.isEmpty)
    }

    // MARK: Coming back after a restart

    @Test func aChatSaidToBeComingBackIsShownAsComingBack() throws {
        let model = AgentsModel()
        let coming = agent(state: .stopped)
        model.replaceAgents([coming])

        let claimed = model.apply(DaemonAPI.Notification.agentResuming,
                                  try notification(DaemonAPI.ResumingNotification(agentID: coming.id,
                                                                                  isResuming: true)))
        #expect(claimed, "the client knows this one")
        #expect(model.isComingBack(coming))

        model.apply(DaemonAPI.Notification.agentResuming,
                    try notification(DaemonAPI.ResumingNotification(agentID: coming.id,
                                                                    isResuming: false)))
        #expect(model.isComingBack(coming) == false, "and stops saying so when it is told to")
    }

    /// A client that connected mid-batch is told the set rather than piecing it
    /// together from notifications it was not there to hear.
    @Test func aClientConnectingLateIsGivenTheWholeSet() {
        let model = AgentsModel()
        let first = agent(state: .stopped)
        let second = agent(state: .stopped)
        model.replaceAgents([first, second])
        model.setResuming([second.id])
        #expect(model.isComingBack(second))
        #expect(model.isComingBack(first) == false)
        model.setResuming([])
        #expect(model.isComingBack(second) == false)
    }

    /// Stop is offered wherever the daemon has something to stop: a runtime it holds,
    /// or a pick-up it is about to make. A chat coming back is `stopped` on the record,
    /// which is why `holdsRuntime` alone left it with no way to say no.
    @Test func stopIsOfferedForEveryChatTheDaemonHasSomethingToStop() {
        let model = AgentsModel()
        let coming = agent(state: .stopped)
        let others = AgentState.allCases.map { agent(state: $0) }
        model.replaceAgents(others + [coming])
        model.setResuming([coming.id])

        for other in others {
            #expect(model.canStop(other) == other.state.holdsRuntime, "\(other.state)")
        }
        #expect(model.canStop(coming), "a chat on its way back can be stopped before it arrives")
        model.setResuming([])
        #expect(model.canStop(coming) == false, "and not once it is no longer coming")
    }

    /// The existing "a notification nobody claims is skipped, never guessed at" rule,
    /// asserted over the new one.
    @Test func anOlderClientIgnoresTheResumingNotification() {
        let model = AgentsModel()
        #expect(model.apply(DaemonAPI.Notification.agentResuming, .string("not a notification")) == true,
                "claimed, and skipped rather than guessed at")
        #expect(model.resuming.isEmpty)
        #expect(model.apply("agent/somethingFromNextYear", nil) == false,
                "while a method nobody knows is still passed on")
    }

    @Test func archivedProjectsAreKeptApartFromLiveOnes() {
        let model = AgentsModel()
        let live = DaemonAPI.ProjectSummary(
            project: Project(folder: URL(filePath: "/tmp/work/api")),
            name: "api", exists: true, lastActivityAt: Date(), counts: [:])
        let filed = DaemonAPI.ProjectSummary(
            project: Project(folder: URL(filePath: "/tmp/work/old"), archivedAt: Date()),
            name: "old", exists: true, lastActivityAt: Date(), counts: [:])
        model.replaceProjects([live, filed])
        #expect(model.liveProjects.map(\.name) == ["api"])
        #expect(model.archivedProjects.map(\.name) == ["old"])
    }

    // MARK: What is being spent

    @Test("cost state is seeded on connect and kept current by the notification")
    func moneyArrivesTheWayProjectsDo() throws {
        let model = AgentsModel()
        #expect(model.costState == nil,
                "nothing until the daemon says, so a window shows nothing rather than a zero")

        model.replaceCostState(DaemonAPI.CostState(
            limits: CostLimits(perAgent: Cost(amount: 2, currency: "USD"),
                               daily: Cost(amount: 10, currency: "USD")),
            today: ["USD": 4], day: "2026-09-19"))
        #expect(model.costState?.today["USD"] == 4)
        #expect(model.costState?.dayHeadroom == 6, "derived here, never sent")
        #expect(model.costState?.dayLimitReached == false)

        let update = try notification(DaemonAPI.CostState(
            limits: CostLimits(daily: Cost(amount: 10, currency: "USD")),
            today: ["USD": 10], day: "2026-09-19"))
        #expect(model.apply(DaemonAPI.Notification.costChanged, update))
        #expect(model.costState?.dayLimitReached == true, "reached, not exceeded")
        #expect(model.costState?.dayHeadroom == 0, "floored, never negative")
        #expect(model.costState?.dayIsCloseToFull == true)
    }

    @Test("a changed day resets today without the client consulting its own clock")
    func theDaemonsDayIsTheOnlyDay() throws {
        let model = AgentsModel()
        model.replaceCostState(DaemonAPI.CostState(
            limits: CostLimits(daily: Cost(amount: 10, currency: "USD")),
            today: ["USD": 10], day: "2026-09-19"))
        #expect(model.costState?.dayLimitReached == true)

        // The daemon says it is tomorrow. A window may be in another time zone, so
        // its own clock is not something it may consult about this.
        let tomorrow = try notification(DaemonAPI.CostState(
            limits: CostLimits(daily: Cost(amount: 10, currency: "USD")),
            today: [:], day: "2026-09-20"))
        #expect(model.apply(DaemonAPI.Notification.costChanged, tomorrow))
        #expect(model.costState?.day == "2026-09-20")
        #expect(model.costState?.today.isEmpty == true, "the day's figure starts from zero")
        #expect(model.costState?.dayLimitReached == false)
    }

    @Test("headroom for one agent follows its own ceiling, and is nothing when uncapped")
    func anAgentsHeadroomIsTheAgentsOwn() {
        let model = AgentsModel()
        var spender = agent(state: .finished)
        spender.costToDate = ["USD": 1.5]
        model.replaceAgents([spender])

        #expect(model.costHeadroom(for: spender) == nil, "no limits known yet, nothing to show")
        #expect(!model.isAtCostLimit(spender))

        model.replaceCostState(DaemonAPI.CostState(
            limits: CostLimits(perAgent: Cost(amount: 2, currency: "USD")),
            today: ["USD": 1.5], day: "2026-09-19"))
        #expect(model.costHeadroom(for: spender) == 0.5)
        #expect(!model.isAtCostLimit(spender))

        spender.costCeiling = Cost(amount: 1, currency: "USD")
        #expect(model.costHeadroom(for: spender) == 0, "its own ceiling wins")
        #expect(model.isAtCostLimit(spender))
    }
}

@MainActor
@Suite("The fold the chat draws is kept by the model")
struct AgentsModelDisplayTests {
    private func entry(_ agentID: UUID, _ text: String, id: String? = "m") throws -> JSONValue {
        try JSONValue.encoding(DaemonAPI.EntryNotification(
            agentID: agentID, entry: TranscriptEntry(kind: .agentMessage(messageID: id, text: text))))
    }

    @Test func itemsFollowTheEntriesAChunkAtATime() throws {
        let model = AgentsModel()
        let watched = UUID()
        model.watching = watched
        model.apply(DaemonAPI.Notification.agentEntry, try entry(watched, "Hel"))
        model.apply(DaemonAPI.Notification.agentEntry, try entry(watched, "lo"))
        model.apply(DaemonAPI.Notification.agentEntry, try entry(UUID(), "not mine"))
        #expect(model.transcriptItems.count == 1)
        #expect(model.transcriptItems == TranscriptEntry.display(model.entries))
    }

    @Test func aReplacedOrGrownPageIsFoldedAgain() throws {
        let model = AgentsModel()
        model.replaceTranscript(with: TranscriptPage(
            firstIndex: 10, total: 20,
            entries: [TranscriptEntry(kind: .agentMessage(messageID: "b", text: "Later"))]))
        #expect(model.transcriptItems.count == 1)
        model.prepend(TranscriptPage(
            firstIndex: 0, total: 20,
            entries: [TranscriptEntry(kind: .agentMessage(messageID: "a", text: "Earlier"))]))
        #expect(model.transcriptItems.map { $0.id } == model.entries.map(\.id))
        model.clearTranscript()
        #expect(model.transcriptItems.isEmpty)
    }

    @Test func readingHappensAnywhereAndMeaningInOnePlace() throws {
        let model = AgentsModel()
        let id = UUID()
        let agent = Agent(id: id, runtimeID: "claude", cwd: URL(filePath: "/tmp/work/api"), state: .running)
        let update = AgentsModel.read(DaemonAPI.Notification.agentChanged, try JSONValue.encoding(agent))
        guard case .agentChanged(let read) = update else { Issue.record("not read"); return }
        #expect(read.id == id)
        model.apply(update!)
        #expect(model.agent(id) != nil)
        #expect(AgentsModel.read(DaemonAPI.Notification.shellOutput, nil) == nil, "not ours")
        guard case .unreadable = AgentsModel.read(DaemonAPI.Notification.agentChanged, .string("no")) else {
            Issue.record("ours, and unreadable, is claimed"); return
        }
    }
}
