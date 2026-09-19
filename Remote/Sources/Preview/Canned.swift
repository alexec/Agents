import AgentsKitCore
import Foundation

/// What the fake Mac has on it.
///
/// Chosen to make the screens hard rather than easy: a project whose folder has gone,
/// two projects that would share a name, an agent waiting on a question, one working
/// with a plan half done, one that crashed, one archived, and a conversation long
/// enough that opening it has to page.
enum Canned {
    static let home = URL(filePath: NSHomeDirectory())

    static let agentsFolder = home.appending(path: "Developer/Agents")
    static let apiFolder = home.appending(path: "Developer/pricing/api")
    static let siteFolder = home.appending(path: "Developer/marketing/api")
    static let goneFolder = home.appending(path: "Developer/old-thing")

    static let waiting = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let working = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let crashed = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    static let done = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
    static let filed = UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!
    static let inTheOther = UUID(uuidString: "00000000-0000-0000-0000-0000000000A6")!

    static func ago(_ minutes: Int) -> Date { Date(timeIntervalSinceNow: -Double(minutes) * 60) }

    static var agents: [Agent] {
        [
            Agent(id: waiting, runtimeID: "claude", cwd: agentsFolder,
                  title: "Lay the remote out for a phone", state: .waitingOnUser,
                  createdAt: ago(41), lastActivityAt: ago(2),
                  usage: Usage(used: 92_000, size: 200_000,
                               cost: Cost(amount: 1.84, currency: "USD")),
                  costToDate: ["USD": 1.84]),
            Agent(id: working, runtimeID: "claude", cwd: agentsFolder,
                  title: "Split the package in two", state: .running,
                  createdAt: ago(18), lastActivityAt: ago(1),
                  usage: Usage(used: 41_000, size: 200_000),
                  costToDate: ["USD": 0.62],
                  plans: [Plan(planID: "p1", entries: [
                      PlanEntry(content: "Move the model across", status: .completed),
                      PlanEntry(content: "Split the client in two", status: .completed),
                      PlanEntry(content: "Build both platforms", status: .inProgress),
                      PlanEntry(content: "Run the tests", status: .pending),
                  ])]),
            Agent(id: crashed, runtimeID: "copilot", cwd: agentsFolder,
                  title: "Rename the suggestion service", state: .stopped,
                  createdAt: ago(190), lastActivityAt: ago(140),
                  endedReason: .processDied, costToDate: ["USD": 0.11]),
            Agent(id: done, runtimeID: "grok", cwd: agentsFolder,
                  title: "Swipe a chat aside to archive it", state: .finished,
                  createdAt: ago(400), lastActivityAt: ago(320),
                  endedReason: .endTurn, costToDate: ["USD": 0.47]),
            Agent(id: filed, runtimeID: "claude", cwd: agentsFolder,
                  title: "The project lead that came back out", state: .archived,
                  createdAt: ago(2_200), lastActivityAt: ago(2_000),
                  archivedReason: .byUser),
            Agent(id: inTheOther, runtimeID: "cursor", cwd: apiFolder,
                  title: "Work out what the new tier costs", state: .running,
                  createdAt: ago(9), lastActivityAt: ago(3)),
        ]
    }

    /// The daemon works these out from the agents, so the fake does too rather than
    /// writing counts by hand that could disagree with the cards below them.
    static func projects(for agents: [Agent]) -> [DaemonAPI.ProjectSummary] {
        let folders: [(URL, String, Bool, Date?)] = [
            (agentsFolder, "Agents", true, nil),
            (apiFolder, "pricing/api", true, nil),
            (siteFolder, "marketing/api", true, nil),
            (goneFolder, "old-thing", false, nil),
        ]
        return folders.map { folder, name, exists, archivedAt in
            let mine = agents.filter { $0.cwd == folder }
            var counts: [AgentGroup: Int] = [:]
            for agent in mine { counts[agent.group, default: 0] += 1 }
            return DaemonAPI.ProjectSummary(
                project: Project(folder: folder, archivedAt: archivedAt, addedAt: ago(9_000)),
                name: name,
                exists: exists,
                lastActivityAt: mine.map(\.lastActivityAt).max() ?? ago(9_000),
                counts: counts)
        }
    }

    /// One conversation, long enough to page. The first forty lines exist so that
    /// scrolling back asks for another page and the join can be looked at.
    static func transcript(for agentID: UUID?) -> [TranscriptEntry] {
        guard let agentID else { return [] }
        var entries: [TranscriptEntry] = []
        for i in 1...40 {
            entries.append(TranscriptEntry(at: ago(300 - i), kind: .userMessage("Earlier question \(i)")))
            entries.append(TranscriptEntry(at: ago(300 - i),
                                           kind: .agentMessage(messageID: nil,
                                                               text: "Earlier answer \(i).")))
        }
        guard agentID == waiting || agentID == working else { return entries }
        entries += [
            TranscriptEntry(at: ago(41), kind: .userMessage(
                "Lay the remote out for a phone. Same three levels as the Mac, one at a time.")),
            TranscriptEntry(at: ago(40), kind: .agentThought(
                messageID: nil,
                text: "The Mac ships two columns and a push, which is already the shape a phone wants.")),
            TranscriptEntry(at: ago(39), kind: .agentMessage(
                messageID: nil,
                text: "Starting with the project list. I will copy what shipped rather than what the contract described.")),
            TranscriptEntry(at: ago(36), kind: .toolCall(ToolCall(
                toolCallID: "t1",
                title: "Read ProjectAgentsView.swift",
                kind: "read",
                content: [.content(.text("200 lines, the 144pt gutter and the grouped cards."))],
                locations: [ToolCallLocation(path: "/App/Sources/Projects/ProjectAgentsView.swift",
                                             line: 1)]))),
            TranscriptEntry(at: ago(30), kind: .toolCall(ToolCall(
                toolCallID: "t2",
                title: "Write Remote/Sources/Projects/ProjectListView.swift",
                kind: "edit",
                content: [.diff(ToolCallContent.Diff(
                    path: "/Remote/Sources/Projects/ProjectListView.swift",
                    oldText: "struct ProjectListView: View {\n    var body: some View {\n        List {}\n    }\n}\n",
                    newText: "struct ProjectListView: View {\n    var body: some View {\n        List(model.liveProjects) { ProjectRow(summary: $0) }\n    }\n}\n"))]))),
            TranscriptEntry(at: ago(24), kind: .planUpdated(Plan(planID: "p1", entries: [
                PlanEntry(content: "The project list", status: .completed),
                PlanEntry(content: "The project page", status: .inProgress),
                PlanEntry(content: "The conversation", status: .pending),
            ]))),
            TranscriptEntry(at: ago(20), kind: .toolCall(ToolCall(
                toolCallID: "t3",
                title: "Run `swift build`",
                kind: "execute",
                content: [.content(.text("Compiling AgentsKitCore\nBuild complete! (4.21s)"))]))),
            TranscriptEntry(at: ago(12), kind: .agentMessage(
                messageID: nil,
                text: "The list and the page are in. Next is the conversation, which is where the paging matters.")),
            TranscriptEntry(at: ago(4), kind: .usageRecorded(
                TurnUsage(totalTokens: 92_000, inputTokens: 81_000, outputTokens: 11_000,
                          cost: Cost(amount: 0.31, currency: "USD")))),
        ]
        if agentID == waiting {
            entries.append(TranscriptEntry(at: ago(2), kind: .agentMessage(
                messageID: nil, text: "That is the layout done. I would like to push it.")))
        }
        return entries
    }

    /// The question waiting when the app opens, so the screen this feature exists for
    /// is the one you land on rather than one you have to provoke.
    static var question: PermissionRequest {
        PermissionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            agentID: waiting,
            toolCall: ToolCall(
                toolCallID: "q1",
                title: "Run `git push origin 005-mobile-remotes`",
                kind: "execute",
                content: [.content(.text("git push origin 005-mobile-remotes"))]),
            options: [PermissionOption(optionID: "allow", name: "Allow", kind: .allowOnce),
                      PermissionOption(optionID: "always", name: "Always allow", kind: .allowAlways),
                      PermissionOption(optionID: "no", name: "Don't allow", kind: .rejectOnce)],
            askedAt: ago(2))
    }
}
