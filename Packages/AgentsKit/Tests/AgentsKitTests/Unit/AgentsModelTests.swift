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

    /// A working agent's activity moves with every line, and a click brings a fresh copy
    /// of it: ordered by activity, the rows of Working swapped places (#182). A group is
    /// in the order its agents started, so only a change of group moves a row.
    @Test func aGroupKeepsItsOrderWhileItsAgentsWork() throws {
        let model = AgentsModel()
        var older = agent(at: Date(timeIntervalSinceNow: -60))
        older.createdAt = Date(timeIntervalSinceNow: -600)
        var newer = agent(at: Date(timeIntervalSinceNow: -120))
        newer.createdAt = Date(timeIntervalSinceNow: -300)
        model.replaceAgents([older, newer])
        #expect(model.agents(in: folder, group: .running).map(\.id) == [newer.id, older.id], "newest started first")

        older.lastActivityAt = Date()
        model.apply(DaemonAPI.Notification.agentChanged, try notification(older))
        #expect(model.agents(in: folder, group: .running).map(\.id) == [newer.id, older.id], "a line written moves nothing")
        #expect(model.agents.first?.id == older.id, "everything held is still newest activity first")

        newer.lastActivityAt = Date().addingTimeInterval(1)
        model.replaceAgents([older, newer])
        #expect(model.agents(in: folder, group: .running).map(\.id) == [newer.id, older.id], "nor does a fresh list")

        older.state = .waitingOnUser
        model.apply(DaemonAPI.Notification.agentChanged, try notification(older))
        #expect(model.agents(in: folder, group: .running).map(\.id) == [newer.id], "a change of group does")
        #expect(model.agents(in: folder, group: .needsAttention).map(\.id) == [older.id])
    }

    /// A withdrawal carries no request, and a client that read it as "nothing to do"
    /// would leave the question on screen for somebody to answer a second time. Without
    /// a request identity, every question for that agent goes — the legacy shape.
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

    /// Several questions can wait on one agent at once. Answering one leaves the others.
    @Test func oneAgentKeepsEveryOutstandingQuestion() throws {
        let model = AgentsModel()
        let id = UUID()
        let first = PermissionRequest(
            agentID: id, toolCall: ToolCall(title: "First"), options: [],
            askedAt: Date(timeIntervalSince1970: 1))
        let second = PermissionRequest(
            agentID: id, toolCall: ToolCall(title: "Second"), options: [],
            askedAt: Date(timeIntervalSince1970: 2))
        model.apply(DaemonAPI.Notification.agentPermission,
                    try notification(DaemonAPI.PermissionNotification(agentID: id, request: first)))
        model.apply(DaemonAPI.Notification.agentPermission,
                    try notification(DaemonAPI.PermissionNotification(agentID: id, request: second)))
        #expect(model.permissions(for: id).map(\.toolCall.title) == ["First", "Second"])

        model.apply(DaemonAPI.Notification.agentPermission,
                    try notification(DaemonAPI.PermissionNotification(
                        agentID: id, request: nil, requestID: first.id)))
        #expect(model.permissions(for: id).map(\.toolCall.title) == ["Second"])
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

    @Test func reconnectingTurnsKeepsOneLatestCopyOfEveryTurn() throws {
        let model = AgentsModel()
        let earlierID = UUID()
        let overlapID = UUID()
        let laterID = UUID()
        func summary(_ id: UUID, _ text: String, start: Int) -> TurnSummary {
            let ask = TranscriptEntry(id: id, kind: .userMessage(text))
            return TurnSummary(id: id, start: start, end: start + 1, ask: ask, last: nil)
        }
        model.replaceTurns(with: TurnsPage(
            turns: [summary(overlapID, "old", start: 10), summary(laterID, "later", start: 20)],
            firstTurn: 1, openStart: 30))
        model.prependTurns(TurnsPage(
            turns: [summary(earlierID, "earlier", start: 0),
                    summary(overlapID, "stale page copy", start: 10),
                    summary(overlapID, "new page copy", start: 10)],
            firstTurn: 0, openStart: 30))

        #expect(model.turns.map(\.id) == [earlierID, overlapID, laterID])
        let heldOverlap = try #require(model.turns.dropFirst().first)
        #expect(heldOverlap.ask?.text == "old", "the already-held copy is newer than the earlier page")
    }

    @Test func storedAndLiveCopiesMakeOneChatRow() {
        let id = UUID()
        let stored = ChatTurn(id: id, ask: nil, items: [],
                              storedOutcome: [TranscriptItem.entry(
                                TranscriptEntry(kind: .agentMessage(messageID: "m", text: "old")))])
        let live = ChatTurn(id: id, ask: nil,
                            items: [.entry(TranscriptEntry(kind: .agentMessage(messageID: "m", text: "new")))])

        let rows = [stored, live].keepingLastTurnWithEachID()

        #expect(rows.count == 1)
        #expect(rows.first?.items.first?.id == live.items.first?.id)
    }

    @Test func reconnectingEntryWithSameIDReplacesHeldAndCatchUpCopies() throws {
        let model = AgentsModel()
        let agentID = UUID()
        let entryID = UUID()
        model.watching = agentID
        let old = TranscriptEntry(id: entryID, kind: .agentMessage(messageID: "m", text: "old"))
        let new = TranscriptEntry(id: entryID, kind: .agentMessage(messageID: "m", text: "new"))
        model.apply(.entry(DaemonAPI.EntryNotification(agentID: agentID, entry: old)))
        model.apply(.entry(DaemonAPI.EntryNotification(agentID: agentID, entry: new)))
        model.replaceTranscript(with: TranscriptPage(firstIndex: 0, total: 1, entries: [old]))

        #expect(model.entries.map(\.id) == [entryID])
        #expect(model.entries.first?.text == "new")
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

    /// Working in a worktree, filed under the project it was started from (030).
    @Test func anAgentInAWorktreeIsFoundUnderItsProject() throws {
        let model = AgentsModel()
        let root = folder.appending(path: ".agents/worktrees/fix-login")
        var working = agent(cwd: root)
        working.worktree = AgentWorktree(name: "fix-login", root: root, branch: "agents/fix-login",
                                         project: folder, base: "main", madeByApp: true)
        model.apply(DaemonAPI.Notification.agentChanged, try notification(working))
        #expect(model.agents(in: folder, group: .running).map(\.id) == [working.id])
        #expect(model.agents(in: root, group: .running).isEmpty)
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

    /// The unread count is the finished chats the daemon has flagged, whichever group
    /// they are under (#70): one flagged and wanting eyes is under Needs you, and still
    /// unread.
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
        #expect(model.unreadCount(in: folder) == 2)
    }

    /// US2: an agent that asked to be looked at and was then stopped wants nobody,
    /// because the grouping consults its state and the count is the grouping.
    @Test func aStoppedAgentThatAskedToBeLookedAtIsNotWanted() throws {
        let model = AgentsModel()
        var stopped = agent(state: .stopped)
        stopped.endedReason = .cancelled
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
            // A queued one too (#362): Stop takes it off the queue.
            #expect(model.canStop(other) == (other.state.holdsRuntime || other.state == .queued), "\(other.state)")
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
    // MARK: 033: what both chats now read from here

    private var modeOption: ConfigOption {
        ConfigOption(wire: ["id": "mode", "name": "Mode", "type": "select", "currentValue": "default",
                            "options": [["value": "default", "name": "Default"],
                                        ["value": "plan", "name": "Plan"]]])!
    }

    @Test func aChoiceShowsAtOnceAndGoesWhenItsCallComesBack() {
        let model = AgentsModel()
        let agent = self.agent()
        #expect(model.chosenOption("mode", for: agent, advertised: modeOption) == "default")
        let sequence = model.beginOption(agentID: agent.id, optionID: "mode", value: "plan")
        #expect(model.chosenOption("mode", for: agent, advertised: modeOption) == "plan")
        model.settleOption(agentID: agent.id, optionID: "mode", sequence: sequence)
        // The record is what is in force now; this agent's record never took it.
        #expect(model.chosenOption("mode", for: agent, advertised: modeOption) == "default")
        #expect(model.pendingOptions.isEmpty)
    }

    /// Two taps in a row, and the first call comes back last. The later choice stays.
    @Test func aSlowEarlierCallDoesNotDropALaterChoice() {
        let model = AgentsModel()
        let agent = self.agent()
        let first = model.beginOption(agentID: agent.id, optionID: "mode", value: "plan")
        _ = model.beginOption(agentID: agent.id, optionID: "mode", value: "default")
        model.settleOption(agentID: agent.id, optionID: "mode", sequence: first)
        #expect(model.pendingOptions[agent.id]?["mode"]?.value == "default")
    }

    /// A double click, or Archive from the menu while the swipe's is still going, is
    /// not a second call; once the first comes back the agent takes another (#87).
    @Test func oneActionAtATimeForAnAgent() {
        let model = AgentsModel()
        let id = UUID(), other = UUID()
        #expect(model.begin(.archive, on: id))
        #expect(!model.begin(.archive, on: id))
        #expect(!model.begin(.stop, on: id))
        #expect(model.begin(.stop, on: other))
        #expect(model.acting[id] == .archive)
        #expect(model.act(of: id) == .archive)
        // An end for something that is not what is in flight leaves it be.
        model.end(.stop, on: id)
        #expect(model.acting[id] == .archive)
        #expect(model.act(of: id) == .archive)
        model.end(.archive, on: id)
        #expect(model.acting[id] == nil)
        #expect(model.act(of: id) == nil)
    }

    /// A followed chat lets old turns go. One being read does not (#285).
    @Test func followedTurnsAreTrimmedAndAReaderUpThePageKeepsTheirs() {
        let model = AgentsModel()
        let page = (0..<80).map { turnSummary($0) }
        model.replaceTurns(with: TurnsPage(turns: page, firstTurn: 0, openStart: 80))
        #expect(model.turns.count == AgentsModel.turnsKept)
        #expect(model.firstTurn == 80 - AgentsModel.turnsKept)
        #expect(model.hasMoreTurns)

        model.isFollowingEnd = false
        let earlier = (0..<40).map { turnSummary(1_000 + $0) }
        model.prependTurns(TurnsPage(turns: earlier, firstTurn: 5, openStart: 80))
        #expect(model.turns.count == AgentsModel.turnsKept + 40)
        #expect(model.firstTurn == 5)

        model.isFollowingEnd = true
        #expect(model.turns.count == AgentsModel.turnsKept)
        #expect(model.firstTurn == 5 + 40)
    }

    /// One project's workflows changing leaves another's list as it was (#285).
    @Test func aWorkflowInOneProjectLeavesTheOther() {
        let model = AgentsModel()
        let api = URL(filePath: "/tmp/work/api")
        let web = URL(filePath: "/tmp/work/web")
        model.upsert(WorkflowSummary(workflow: Workflow(workflowID: "build", folder: api, name: "Build")))
        model.upsert(WorkflowSummary(workflow: Workflow(workflowID: "ship", folder: web, name: "Ship")))
        let webBefore = model.workflows(in: web)
        model.upsert(WorkflowSummary(workflow: Workflow(workflowID: "lint", folder: api, name: "Lint")))
        #expect(model.workflows(in: web) == webBefore)
        #expect(model.workflows(in: api).map(\.workflow.name) == ["Build", "Lint"])
        model.replaceWorkflows([WorkflowSummary(workflow: Workflow(workflowID: "ship", folder: web, name: "Ship"))])
        #expect(model.workflows(in: web).map(\.workflowID) == ["ship"])
        #expect(model.workflows(in: api).isEmpty)
    }

    /// A lease is the holder's and the waiter's, and the next snapshot moves it (#285).
    @Test func aLeaseIsReadFromTheAgentItBelongsTo() {
        let model = AgentsModel()
        let holder = UUID(), waiter = UUID(), other = UUID()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let screen = ResourceName.screen
        func snapshot(heldBy holder: UUID, waitedBy waiter: UUID) -> DaemonAPI.LeaseSnapshot {
            DaemonAPI.LeaseSnapshot(resources: [
                .init(name: screen, kind: .screen, displayName: "Screen",
                      lease: Lease(resource: screen, displayName: "Screen", holder: holder,
                                   grantedAt: at, expiresAt: at.addingTimeInterval(600)),
                      line: [.init(agentID: waiter, askedAt: at, isCallOpen: true)]),
            ], at: at)
        }
        model.replaceLeases(snapshot(heldBy: holder, waitedBy: waiter))
        #expect(model.leaseStatus(of: holder) == LeaseStatus.of(holder, in: snapshot(heldBy: holder, waitedBy: waiter), titles: [:]))
        #expect(model.leaseStatus(of: waiter) != nil)
        #expect(model.leaseStatus(of: other) == nil)
        model.replaceLeases(snapshot(heldBy: waiter, waitedBy: holder))
        #expect(model.leaseStatus(of: waiter)?.holding.isEmpty == false)
        #expect(model.leaseStatus(of: holder)?.waiting.isEmpty == false)
        #expect(model.leaseStatus(of: other) == nil)
    }

    private func turnSummary(_ start: Int) -> TurnSummary {
        TurnSummary(id: UUID(), start: start, end: start + 1, ask: nil, last: nil)
    }

    @Test func aCommandsOutputIsKeptPerTerminalAndByItsTail() throws {
        let model = AgentsModel()
        let id = UUID()
        model.watching = id
        model.apply(DaemonAPI.Notification.agentTerminalOutput,
                    try notification(DaemonAPI.TerminalOutputNotification(agentID: id, terminalID: "t1", chunk: "one ")))
        model.apply(DaemonAPI.Notification.agentTerminalOutput,
                    try notification(DaemonAPI.TerminalOutputNotification(agentID: id, terminalID: "t2", chunk: "other")))
        model.apply(DaemonAPI.Notification.agentTerminalOutput,
                    try notification(DaemonAPI.TerminalOutputNotification(agentID: id, terminalID: "t1", chunk: "two")))
        #expect(model.terminalOutput["t1"] == "one two")
        #expect(model.terminalOutput["t2"] == "other")

        let long = String(repeating: "a", count: AgentsModel.terminalOutputLimit) + "END"
        model.apply(DaemonAPI.Notification.agentTerminalOutput,
                    try notification(DaemonAPI.TerminalOutputNotification(agentID: id, terminalID: "t1", chunk: long)))
        #expect(model.terminalOutput["t1"]?.count == AgentsModel.terminalOutputLimit)
        #expect(model.terminalOutput["t1"]?.hasSuffix("END") == true)
    }

    /// Output is kept for the chat on screen only (#203), bounded as a whole, the least
    /// recently written terminal going first.
    @Test func outputIsKeptForTheChatOnScreenAndBoundedOldestFirst() throws {
        let model = AgentsModel()
        let watched = UUID(), other = UUID()
        model.watching = watched
        func say(_ agent: UUID, _ terminal: String, _ chunk: String, whole: Bool? = nil) throws {
            model.apply(DaemonAPI.Notification.agentTerminalOutput,
                        try notification(DaemonAPI.TerminalOutputNotification(agentID: agent, terminalID: terminal,
                                                                             chunk: chunk, whole: whole)))
        }
        try say(other, "theirs", "not on screen")
        #expect(model.terminalOutput["theirs"] == nil)

        // Each terminal is kept to its limit, so this many full ones fill the budget.
        let full = String(repeating: "b", count: AgentsModel.terminalOutputLimit)
        let fit = AgentsModel.terminalOutputBudget / AgentsModel.terminalOutputLimit
        for index in 0 ..< fit { try say(watched, "t\(index)", full) }
        #expect(model.terminalOutput.count == fit)
        try say(watched, "last", full)
        #expect(model.terminalOutput["t0"] == nil)
        #expect(model.terminalOutput["t1"] != nil)
        #expect(model.terminalOutput.values.reduce(0) { $0 + $1.utf8.count } <= AgentsModel.terminalOutputBudget)

        // What a host sends a chat opening is the terminal whole, in place of what was held.
        try say(watched, "last", "everything so far", whole: true)
        #expect(model.terminalOutput["last"] == "everything so far")

        // Another chat opened: the last one's output goes with it.
        model.watching = other
        #expect(model.terminalOutput.isEmpty)
    }

    /// An entry or terminal output for another chat is not read past its agentID (#203).
    @Test func anEntryForAnotherChatIsSkippedBeforeItIsDecoded() throws {
        let shown = UUID(), other = UUID()
        let entry = try notification(DaemonAPI.EntryNotification(
            agentID: other, entry: TranscriptEntry(kind: .agentMessage(messageID: nil, text: "hi"))))
        guard case .skipped? = AgentsModel.read(DaemonAPI.Notification.agentEntry, entry, showing: shown) else {
            Issue.record("an entry for another chat was read"); return
        }
        guard case .skipped? = AgentsModel.read(DaemonAPI.Notification.agentEntry, entry, showing: .some(nil)) else {
            Issue.record("an entry with no chat open was read"); return
        }
        guard case .entry? = AgentsModel.read(DaemonAPI.Notification.agentEntry, entry, showing: other) else {
            Issue.record("the open chat's entry was skipped"); return
        }
    }

    /// An archived agent the client does not hold stays out: a retention sweep must not
    /// file thousands of them into a client holding the live ones and a page (#203).
    @Test func anArchivedChangeForAnAgentNotHeldIsDropped() throws {
        let model = AgentsModel()
        let held = agent(state: .finished)
        model.apply(DaemonAPI.Notification.agentChanged, try notification(held))
        model.apply(DaemonAPI.Notification.agentChanged, try notification(agent(state: .archived)))
        #expect(model.agents.map(\.id) == [held.id])
        var archived = held
        archived.state = .archived
        model.apply(DaemonAPI.Notification.agentChanged, try notification(archived))
        #expect(model.agents.first?.state == .archived)
    }

    /// A lean change keeps the open chat's menus; a whole one is the truth, an emptied plan
    /// included (#203).
    @Test func aLeanChangeKeepsTheListsAndAWholeOneReplacesThem() throws {
        let model = AgentsModel()
        var whole = agent()
        whole.availableCommands = [SlashCommand(name: "review")]
        whole.plans = [Plan(entries: [PlanEntry(content: "Step", status: .inProgress)])]
        model.apply(DaemonAPI.Notification.agentChanged, try notification(whole))
        var renamed = whole
        renamed.title = "Renamed"
        model.apply(DaemonAPI.Notification.agentChanged, try notification(renamed.leaned()))
        #expect(model.agent(whole.id)?.title == "Renamed")
        #expect(model.agent(whole.id)?.availableCommands.map(\.name) == ["review"])
        #expect(model.agent(whole.id)?.plans.count == 1)
        var planDone = whole
        planDone.plans = []
        model.apply(DaemonAPI.Notification.agentChanged, try notification(planDone))
        #expect(model.agent(whole.id)?.plans.isEmpty == true)
        #expect(model.agent(whole.id)?.availableCommands.map(\.name) == ["review"])
    }

    /// An entry too big to send arrives as a stub that draws nothing; read whole, it takes
    /// the stub's place (#203).
    @Test func anOversizedEntryIsAskedForAndFilledInPlace() throws {
        let model = AgentsModel()
        let id = UUID()
        model.watching = id
        var asked: (UUID, UUID, Int?)?
        model.onOversized = { asked = ($0, $1, $2) }
        let before = TranscriptEntry(kind: .agentMessage(messageID: "a", text: "before"))
        let big = TranscriptEntry(kind: .toolCall(ToolCall(toolCallID: "c", title: "Read a file")))
        let after = TranscriptEntry(kind: .agentMessage(messageID: "b", text: "after"))
        model.apply(DaemonAPI.Notification.agentEntry,
                    try notification(DaemonAPI.EntryNotification(agentID: id, entry: before)))
        model.apply(DaemonAPI.Notification.agentEntry,
                    try notification(DaemonAPI.EntryNotification.stub(agentID: id, for: big, bytes: 90_000, index: 7)))
        model.apply(DaemonAPI.Notification.agentEntry,
                    try notification(DaemonAPI.EntryNotification(agentID: id, entry: after)))
        #expect(asked?.0 == id)
        #expect(asked?.1 == big.id)
        #expect(asked?.2 == 7)
        model.fillOversized(big, for: id)
        try #require(model.entries.map(\.id) == [before.id, big.id, after.id])
        #expect(model.entries[1] == big)
        guard case .toolRun? = model.transcriptItems.first(where: { $0.id == big.id }) else {
            Issue.record("the filled entry is not drawn as its tool call: \(model.transcriptItems)"); return
        }
    }


    /// A deleted agent leaves every list (#398), and a chat naming it as its starter says
    /// "another agent".
    @Test func aDeletedAgentLeavesTheListAndItsStarterMarkSaysAnotherAgent() throws {
        let model = AgentsModel()
        var starter = agent(state: .archived)
        starter.title = "Plan the release"
        var started = agent()
        started.startedByAgent = starter.id
        model.apply(DaemonAPI.Notification.agentChanged, try notification(starter))
        model.apply(DaemonAPI.Notification.agentChanged, try notification(started))

        model.apply(DaemonAPI.Notification.agentRemoved,
                    try notification(DaemonAPI.AgentRemovedNotification(agentID: starter.id)))
        #expect(model.agent(starter.id) == nil)
        #expect(model.agent(started.id) != nil)
        #expect(model.startedByAgentLabel(started) == "Started by another agent")
    }
}
