import Foundation
import Testing
@testable import AgentsKitCore

/// The rules the web remote ports by hand, pinned by what Swift does (071, research R7).
///
/// Each file under `Fixtures/web/` is a list of cases, `{"name", "input", "expected"}`. The
/// input is JSON from the Swift encoders, the expected output is the Swift rule run on it, and
/// `Web/test/*.test.mjs` runs the TypeScript port on the same input. Run with
/// `AGENTS_WRITE_WEB_FIXTURES=1` to write them; without it, every rule is run again and any
/// difference from the checked-in file fails, so the fixtures are always what Swift does.
@Suite("Web fixtures")
@MainActor
struct WebFixturesTests {
    static let folder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/web")

    static var writing: Bool { ProcessInfo.processInfo.environment["AGENTS_WRITE_WEB_FIXTURES"] == "1" }

    struct Case {
        var name: String
        var input: JSONValue
    }

    /// Writes `cases` with `rule` run on each, or checks the file holds exactly that.
    func pin(_ path: String, _ cases: [Case], rule: (JSONValue) throws -> JSONValue) throws {
        let made: JSONValue = .array(try cases.map {
            .object(["name": .string($0.name), "input": $0.input, "expected": try rule($0.input)])
        })
        let url = Self.folder.appending(path: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if Self.writing {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (encoder.encode(made) + Data("\n".utf8)).write(to: url)
            return
        }
        let held = try JSONValue.parse(Data(contentsOf: url))
        // Compared case by case, so a failure names the case.
        let heldCases = held.arrayValue ?? []
        let madeCases = made.arrayValue ?? []
        #expect(heldCases.count == madeCases.count,
                "\(path) has \(heldCases.count) cases, Swift makes \(madeCases.count); run AGENTS_WRITE_WEB_FIXTURES=1 swift test --filter WebFixtures")
        for (heldCase, madeCase) in zip(heldCases, madeCases) {
            #expect(heldCase == madeCase,
                    "\(path) \(madeCase["name"]?.stringValue ?? "?") differs from what Swift does; run AGENTS_WRITE_WEB_FIXTURES=1 swift test --filter WebFixtures")
        }
    }

    // MARK: Making things

    static let base = Date(timeIntervalSinceReferenceDate: 812_500_000)
    static let folderURL = URL(filePath: "/fixture/project/")

    static func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func agent(_ n: Int, _ state: AgentState, title: String? = nil, minutes: Double = 0,
                      isUnread: Bool = false, endedReason: EndedReason? = nil, report: WorkReport? = nil,
                      outcomeAsked: Bool = false, parking: Parking? = nil, eventWait: EventWait? = nil,
                      labels: [SessionLabel] = [], background: [BackgroundItem] = [],
                      cwd: URL = folderURL) -> Agent {
        Agent(id: id(n), runtimeID: "claude", cwd: cwd, title: title ?? "Session \(n)", labels: labels, state: state,
              createdAt: base, lastActivityAt: at(minutes), isUnread: isUnread, endedReason: endedReason,
              background: background, eventWait: eventWait, report: report, outcomeAsked: outcomeAsked,
              parking: parking)
    }

    static func report(_ outcome: WorkOutcome, _ message: String = "It went.", block: Block? = nil) -> WorkReport {
        WorkReport(outcome: outcome, message: message, at: at(1), block: block)
    }

    static let openWait = EventWait(id: id(900), patterns: [EventPattern("ci.finished")], from: 4, since: base)
    static let endedWait = EventWait(id: id(901), patterns: [EventPattern("ci.finished")], from: 4, since: base,
                                     ending: .timedOut)

    static func encode(_ value: some Encodable) throws -> JSONValue { try JSONValue.encoding(value) }
    static func encodeAny(_ value: any Encodable) throws -> JSONValue { try encode(value) }

    /// The agents the group and status cases run over: every arm of `AgentGroup.init` and
    /// `StatusShape.init`, each named for what it shows.
    static var agents: [(String, Agent, Bool)] {
        let waits = Block(waits: [Wait(agentID: id(77), nameAtReport: "Build")])
        let later = Block(checkAgainAt: at(60))
        let cleared = Block(waits: [Wait(agentID: id(77), nameAtReport: "Build")], clearedAt: at(2), clearedBy: .waits)
        return [
            ("starting", agent(1, .starting), false),
            ("waiting on the person", agent(2, .waitingOnUser), false),
            ("running", agent(3, .running), false),
            ("running, wants eyes", agent(4, .running), true),
            ("running the app's question, no report yet", agent(5, .running, outcomeAsked: true), false),
            ("running the app's question, reported done", agent(6, .running, report: report(.done), outcomeAsked: true), false),
            ("finished, nothing said, read", agent(7, .finished, endedReason: .endTurn), false),
            ("finished, unread", agent(8, .finished, isUnread: true, endedReason: .endTurn), false),
            ("finished, needs an answer", agent(9, .finished, report: report(.needsAnswer)), false),
            ("finished, partly done", agent(10, .finished, report: report(.partlyDone)), false),
            ("finished, stuck", agent(11, .finished, report: report(.stuck)), false),
            ("blocked on agents", agent(12, .finished, report: report(.blocked, block: waits)), false),
            ("blocked until a time", agent(13, .finished, report: report(.blocked, block: later)), false),
            ("blocked on nothing named", agent(14, .finished, report: report(.blocked)), false),
            ("blocked, cleared", agent(15, .finished, report: report(.blocked, block: cleared)), false),
            ("finished, waiting on events", agent(16, .finished, endedReason: .endTurn, eventWait: openWait), false),
            ("finished, wait on events ended", agent(17, .finished, endedReason: .endTurn, eventWait: endedWait), false),
            ("asked how it went, said nothing", agent(18, .finished, endedReason: .endTurn, outcomeAsked: true), false),
            ("done", agent(19, .finished, endedReason: .endTurn, report: report(.done)), false),
            ("nothing to do", agent(20, .finished, report: report(.nothingToDo)), false),
            ("done, unread", agent(21, .finished, isUnread: true, report: report(.done)), false),
            ("done, wants eyes", agent(22, .finished, report: report(.done)), true),
            ("done, waiting on events", agent(23, .finished, report: report(.done), eventWait: openWait), false),
            ("stopped by the person", agent(24, .stopped, endedReason: .cancelled), false),
            ("stopped by its starter", agent(25, .stopped, endedReason: .stoppedByAgent), false),
            ("stopped, allowance spent", agent(26, .stopped, endedReason: .allowanceSpent), false),
            ("stopped, the runtime crashed", agent(27, .stopped, endedReason: .processDied), false),
            ("stopped with the daemon", agent(28, .stopped, endedReason: .daemonGone), false),
            ("stopped, no reason", agent(29, .stopped), false),
            ("stopped, a needs-answer report kept", agent(30, .stopped, endedReason: .cancelled, report: report(.needsAnswer)), false),
            ("parked, done", agent(31, .finished, report: report(.done), parking: .parked(at: at(5))), false),
            ("parked, stuck", agent(32, .finished, report: report(.stuck), parking: .parked(at: at(6))), false),
            ("parked, but asking", agent(33, .waitingOnUser, parking: .parked(at: at(5))), false),
            ("parked when the turn ends, running", agent(34, .running, parking: .whenTurnEnds(since: at(4))), false),
            ("archived", agent(35, .archived), false),
            ("archived and parked", agent(36, .archived, parking: .parked(at: at(5))), false),
        ]
    }

    // MARK: groups/ and status/

    @Test func groups() throws {
        let cases = try Self.agents.map { name, agent, eyes in
            Case(name: name, input: .object(["agent": try Self.encode(agent), "wantsEyes": .bool(eyes)]))
        }
        try pin("groups/agents.json", cases) { input in
            let agent = try input["agent"]!.decode(Agent.self)
            let group = agent.group(wantsEyes: input["wantsEyes"]?.boolValue ?? false)
            return .object(["group": .string(group.rawValue), "title": .string(group.title),
                            "needsAPerson": .bool(agent.needsAPerson), "isWaiting": .bool(agent.isWaiting),
                            "showsUnread": .bool(agent.showsUnread)])
        }
    }

    /// A project's whole column: the headings in order, who is under each, archived apart,
    /// and the counts the project row shows.
    @Test func panels() throws {
        let everyone = Self.agents.enumerated().map { index, entry in
            var agent = entry.1
            // Spread out in time, not in the order listed, so the order is the rule's.
            agent.lastActivityAt = Self.at(Double((index * 7) % 23))
            return agent
        }
        let elsewhere = Self.agent(99, .running, cwd: URL(filePath: "/fixture/other/"))
        let inWorktree: Agent = {
            var agent = Self.agent(98, .running, minutes: 30)
            agent.cwd = URL(filePath: "/fixture/project/.agents/worktrees/x/")
            agent.worktree = AgentWorktree(name: "x", root: URL(filePath: "/fixture/project/.agents/worktrees/x/"),
                                           branch: "agents/x", project: Self.folderURL, base: "main", madeByApp: true)
            return agent
        }()
        let cases = [
            Case(name: "every kind of session in one project", input: .object([
                "folder": .string(Self.folderURL.absoluteString),
                "agents": .array(try (everyone + [elsewhere, inWorktree]).map(Self.encode)),
            ])),
            Case(name: "an empty project", input: .object([
                "folder": .string(Self.folderURL.absoluteString), "agents": .array([try Self.encode(elsewhere)]),
            ])),
        ]
        try pin("groups/panels.json", cases) { input in
            let model = AgentsModel()
            model.replaceAgents(try input["agents"]!.decode([Agent].self))
            let folder = URL(string: input["folder"]!.stringValue!)!
            var headings: [JSONValue] = []
            for group in AgentGroup.live {
                for heading in group.headings(model.agents(in: folder, group: group)) {
                    headings.append(.object(["group": .string(group.rawValue), "title": .string(heading.title),
                                             "ids": .array(heading.agents.map { .string($0.id.uuidString) }),
                                             "unread": .int(heading.agents.filter(\.showsUnread).count)]))
                }
            }
            let counts = model.counts(in: folder)
            return .object([
                "headings": .array(headings),
                "archived": .array(model.agents(in: folder, group: .archived).map { .string($0.id.uuidString) }),
                "counts": .object(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, .int($0.value)) })),
                "needsYou": .int(counts[.needsAttention] ?? 0),
                "unread": .int(model.unreadCount(in: folder)),
                "attention": .int(model.attentionCount(in: folder)),
            ])
        }
    }

    @Test func status() throws {
        var cases = try Self.agents.map { name, agent, _ in
            Case(name: name, input: .object(["agent": try Self.encode(agent), "isComingBack": .bool(false)]))
        }
        cases.append(Case(name: "coming back after a restart", input: .object([
            "agent": try Self.encode(Self.agent(40, .stopped, endedReason: .daemonGone)), "isComingBack": .bool(true)])))
        try pin("status/rows.json", cases) { input in
            let agent = try input["agent"]!.decode(Agent.self)
            let back = input["isComingBack"]?.boolValue ?? false
            let shape = StatusShape(row: agent, isComingBack: back)
            return .object([
                "shape": .string(Self.name(of: shape)),
                "symbol": shape.symbol.map(JSONValue.string) ?? .null,
                "tinted": .bool(StatusShape.isTinted(shape, isParked: agent.parking?.isParked == true)),
                "words": .string(StatusShape.words(row: agent, isComingBack: back)),
            ])
        }
    }

    static func name(of shape: StatusShape) -> String {
        switch shape {
        case .working: return "working"
        case .needsYou: return "needsYou"
        case .waiting: return "waiting"
        case .done: return "done"
        case .stopped: return "stopped"
        }
    }

    // MARK: turns/

    static func entry(_ n: Int, _ kind: TranscriptEntry.Kind, subagent: String? = nil) -> TranscriptEntry {
        TranscriptEntry(id: id(1000 + n), at: at(Double(n) / 10), kind: kind, subagentID: subagent)
    }

    static func call(_ id: String, _ title: String, name: String? = nil, kind: String? = nil, status: String? = nil,
                     description: String? = nil, output: String? = nil) -> ToolCall {
        ToolCall(toolCallID: id, title: title, name: name, kind: kind, status: status,
                 rawInput: description.map { .object(["description": .string($0)]) },
                 rawOutput: output.map(JSONValue.string))
    }

    static func ask(_ n: Int, _ text: String) -> TranscriptEntry { entry(n, .userMessage(text)) }

    /// Transcripts covering the fold: chunks joined, tool runs and their updates, what is
    /// never drawn, passing lines, thoughts, subagents, and turns live and over.
    static var transcripts: [(String, [TranscriptEntry], Bool)] {
        let finished = entry(90, .stateChanged(.finished, reason: .endTurn))
        let usage = entry(91, .usageRecorded(TurnUsage(totalTokens: 10, inputTokens: 6, outputTokens: 4)))
        return [
            ("a reply in chunks", [
                ask(1, "Hello"),
                entry(2, .agentMessage(messageID: "a", text: "Hel")),
                entry(3, .agentMessage(messageID: "a", text: "lo there")),
                entry(4, .agentMessage(messageID: "b", text: "A second message.")),
                finished, usage,
            ], false),
            ("a run of tool calls with updates", [
                ask(1, "Look around"),
                entry(2, .agentMessage(messageID: "a", text: "Looking.")),
                entry(3, .toolCall(call("t1", "ls", kind: "execute", status: "pending", description: "List the files"))),
                entry(4, .toolCallUpdate(call("t1", "Tool call", status: "completed", output: "a b c"))),
                entry(5, .toolCall(call("t2", "Read README.md", name: "Read", kind: "read", status: "pending"))),
                entry(6, .toolCallUpdate(call("t2", "", status: "completed"))),
                entry(7, .optionChanged(id: "mode", value: .string("auto"))),
                entry(8, .toolCall(call("t3", "grep foo", name: "Grep", kind: "search"))),
                entry(9, .agentMessage(messageID: "c", text: "Found it.")),
                entry(10, .toolCallUpdate(call("t3", "Tool call", status: "completed"))),
                entry(11, .workReported(report(.done, "Found foo."))),
                entry(12, .agentMessage(messageID: "d", text: "That's all.")),
                finished,
            ], false),
            ("the app's own calls are not drawn", [
                ask(1, "Finish up"),
                entry(2, .toolCall(call("f1", "mcp__agents__finish_turn", name: "mcp__agents__finish_turn"))),
                entry(3, .toolCallUpdate(call("f1", "Tool call", status: "completed"))),
                entry(4, .toolCall(call("f2", "mcp__agents__report_outcome"))),
                entry(5, .toolCallUpdate(ToolCall(toolCallID: "x9", title: "Tool call"))),
                entry(6, .servedRequest(ServedRequest(kind: .readFile(path: "/a/b.txt"), outcome: .served))),
                entry(7, .servedRequest(ServedRequest(kind: .writeFile(path: "/a/c.txt", byteCount: 3), outcome: .served))),
                entry(8, .agentMessage(messageID: "a", text: "Done.")),
                finished,
            ], false),
            ("passing lines", [
                entry(1, .runtimeNote("Starting Claude…")),
                entry(2, .stateChanged(.running, reason: nil)),
                ask(3, "Go on"),
                entry(4, .runtimeNote(RuntimeNote.pickedBackUp)),
                entry(5, .runtimeNote(RuntimeNote.questionWentUnanswered)),
                entry(6, .stateChanged(.running, reason: nil)),
            ], true),
            ("thoughts between calls", [
                ask(1, "Think"),
                entry(2, .agentThought(messageID: "th", text: "Hmm")),
                entry(3, .agentThought(messageID: "th", text: ", maybe.")),
                entry(4, .toolCall(call("t1", "one", kind: "read"))),
                entry(5, .agentThought(messageID: "th2", text: "And then")),
                entry(6, .toolCall(call("t2", "two", kind: "edit"))),
                entry(7, .agentMessage(messageID: "a", text: "Edited.")),
                finished,
            ], false),
            ("a subagent's lines are left out", [
                ask(1, "Delegate"),
                entry(2, .agentMessage(messageID: "a", text: "Asking a helper.")),
                entry(3, .agentMessage(messageID: "a", text: " Its words."), subagent: "s1"),
                entry(4, .agentMessage(messageID: "a", text: " Mine again.")),
                entry(5, .background(BackgroundItem(id: "bg1", kind: .task, name: "Tick", taskType: "shell",
                                                    toolCallID: "t9", startedAt: at(0)))),
                entry(6, .background(BackgroundItem(id: "bg1", kind: .task, name: "Tick", taskType: "shell",
                                                    state: .completed, startedAt: at(0), endedAt: at(1)))),
                finished,
            ], false),
            ("a live turn on a step", [
                ask(1, "Build it"),
                entry(2, .agentMessage(messageID: "a", text: "Building.")),
                entry(3, .toolCall(call("t1", "make", kind: "execute", status: "in_progress", description: "Run the build"))),
            ], true),
            ("a live turn with its reply arriving", [
                ask(1, "Build it"),
                entry(2, .toolCall(call("t1", "make", kind: "execute", status: "completed"))),
                entry(3, .agentMessage(messageID: "a", text: "It built.")),
            ], true),
            ("questions, answers and an ending", [
                ask(1, "Ask me"),
                entry(2, .elicitationAnswered(id: id(5), summary: "Answered", answers: [
                    ElicitationAnswer(question: "Colour?", answer: "Blue")])),
                entry(3, .permissionAnswered(optionID: "allow", optionName: "Allow")),
                entry(4, .notice(SessionNotice(severity: "error", title: "It broke"))),
                entry(5, .notice(SessionNotice(severity: "warning", title: "Careful"))),
                entry(6, .stateChanged(.stopped, reason: .cancelled)),
                ask(7, "Again"),
                entry(8, .userMessage("How did it go?", from: .app)),
                entry(9, .planUpdated(Plan(entries: [PlanEntry(content: "Step", priority: .high, status: .inProgress)],
                                          at: at(1)))),
                entry(10, .agentMessage(messageID: "z", text: "Fine.")),
                finished,
            ], false),
        ]
    }

    static func digest(_ item: TranscriptItem) throws -> JSONValue {
        switch item {
        case .entry(let entry):
            var fields: [String: JSONValue] = ["entry": .string(entry.id.uuidString),
                                               "kind": .string(try kindName(entry.kind))]
            switch entry.kind {
            case .agentMessage(_, let text, _), .agentThought(_, let text), .userMessage(let text, _, _):
                fields["text"] = .string(text)
            default: break
            }
            return .object(fields)
        case .toolRun(let id, let calls):
            return .object(["run": .string(id.uuidString), "calls": .array(calls.map { call in
                .object(["id": call.toolCallID.map(JSONValue.string) ?? .null, "title": .string(call.title),
                         "status": call.status.map(JSONValue.string) ?? .null, "turnLine": .string(call.turnLine)])
            })])
        }
    }

    static func kindName(_ kind: TranscriptEntry.Kind) throws -> String {
        try encode(kind).objectValue?.keys.first ?? "?"
    }

    @Test func turns() throws {
        let cases = try Self.transcripts.map { name, entries, live in
            Case(name: name, input: .object(["entries": .array(try entries.map(Self.encode)), "isLive": .bool(live)]))
        }
        try pin("turns/transcripts.json", cases) { input in
            let entries = try input["entries"]!.decode([TranscriptEntry].self)
            let isLive = input["isLive"]?.boolValue ?? false
            let items = TranscriptEntry.display(entries)
            let turns = items.turns()
            let ids: ([TranscriptItem]) -> JSONValue = { .array($0.map { .string($0.id.uuidString) }) }
            return .object([
                "items": .array(try items.map(Self.digest)),
                "omittingThoughts": ids(items.omittingThoughts()),
                "turns": .array(turns.enumerated().map { index, turn in
                    let live = isLive && index == turns.count - 1
                    let parts = TurnParts(turn.items, isLive: live)
                    let outcome = Set(parts.outcome.map(\.id))
                    let steps = TurnParts.drawn(turn.items, isLive: live).filter { !outcome.contains($0.id) }
                    return .object([
                        "id": .string(turn.id.uuidString),
                        "ask": turn.ask.map { .string($0.id.uuidString) } ?? .null,
                        "outcome": ids(parts.outcome),
                        "stepCount": .int(parts.stepCount),
                        "live": parts.live.map { .string($0.id.uuidString) } ?? .null,
                        "steps": ids(steps),
                    ])
                }),
            ])
        }
    }

    @Test func toolLines() throws {
        let calls: [(String, ToolCall)] = [
            ("described", Self.call("1", "ls -la", kind: "execute", description: "  List the files  ")),
            ("read", Self.call("2", "Read a.swift", name: "Read", kind: "read")),
            ("edit, named", Self.call("3", "Edit", name: "MultiEdit", kind: "edit")),
            ("execute named Bash", Self.call("4", "make", name: "Bash", kind: "execute")),
            ("other, an MCP tool", Self.call("5", "x", name: "mcp__agents__show_file", kind: "other")),
            ("other, unnamed", Self.call("6", "x", kind: "other")),
            ("think, a kind of its own", Self.call("7", "x", name: nil, kind: "think")),
            ("search named search", Self.call("8", "x", name: "search", kind: "search")),
            ("no kind, camel name", Self.call("9", "x", name: "WebFetch")),
            ("nothing at all", Self.call("10", "Tool call")),
            ("fetch", Self.call("11", "GET", name: "fetch_url", kind: "Fetch")),
        ]
        let cases = try calls.map { Case(name: $0.0, input: .object(["call": try Self.encode($0.1)])) }
        try pin("turns/lines.json", cases) { input in
            let call = try input["call"]!.decode(ToolCall.self)
            return .object(["turnLine": .string(call.turnLine), "line": .string(call.line)])
        }
    }

    // MARK: background/

    @Test func background() throws {
        let shell = BackgroundItem(id: "a", kind: .task, name: "Tick", taskType: "shell", startedAt: Self.at(0))
        let monitor = BackgroundItem(id: "b", kind: .task, name: "Watch", taskType: "monitor", state: .paused,
                                     startedAt: Self.at(0))
        let helper = BackgroundItem(id: "c", kind: .subagent, name: "Count files", startedAt: Self.at(0))
        func ended(_ item: BackgroundItem, _ state: BackgroundItem.State, minutes: Double) -> BackgroundItem {
            var item = item
            item.state = state
            item.endedAt = Self.at(minutes)
            return item
        }
        let sets: [(String, [BackgroundItem])] = [
            ("nothing", []),
            ("one shell", [shell]),
            ("two shells, a subagent and a task", [shell, BackgroundItem(id: "d", kind: .task, name: "Two", taskType: "shell",
                                                                          startedAt: Self.at(0)), helper, monitor]),
            ("every ending", [ended(shell, .completed, minutes: 0.6), ended(helper, .failed, minutes: 75),
                              ended(monitor, .stopped, minutes: 12.07),
                              ended(BackgroundItem(id: "e", kind: .task, name: "W", taskType: "workflow",
                                                   startedAt: Self.at(0)), .disconnected, minutes: 1)]),
        ]
        let cases = try sets.map { name, items in
            Case(name: name, input: .object(["items": .array(try items.map(Self.encode)),
                                             "now": try Self.encode(Self.at(2))]))
        }
        try pin("background/words.json", cases) { input in
            let items = try input["items"]!.decode([BackgroundItem].self)
            let now = try input["now"]!.decode(Date.self)
            return .object([
                "mark": BackgroundWords.mark(items).map(JSONValue.string) ?? .null,
                "rows": .array(items.map { item in
                    .object(["id": .string(item.id), "noun": .string(BackgroundWords.noun(item)),
                             "ending": .string(BackgroundWords.ending(item)),
                             "ended": BackgroundWords.ended(item).map(JSONValue.string) ?? .null,
                             "age": .string(BackgroundWords.age(item, now: now)),
                             "isRunning": .bool(item.isRunning)])
                }),
            ])
        }
    }

    // MARK: labels/

    @Test func labels() throws {
        let typed: [(String, String, [String])] = [
            ("one finished, one typing", "bug, ui", []),
            ("trailing comma", "bug,", []),
            ("spaces and repeats", " Bug , bug,  ,ui", ["UI"]),
            ("too long", "\(String(repeating: "x", count: 25)),ok,", []),
            ("exactly 24", "\(String(repeating: "y", count: 24)),", []),
            ("no room", "a,b,c,", ["one", "two", "three", "four"]),
            ("nothing", "", []),
        ]
        let cases = typed.map { name, text, existing in
            Case(name: name, input: .object(["typed": .string(text), "existing": .array(existing.map(JSONValue.string))]))
        }
        try pin("labels/policy.json", cases) { input in
            let split = SessionLabelPolicy.split(typed: input["typed"]!.stringValue!)
            let existing = (input["existing"]?.arrayValue ?? []).compactMap(\.stringValue)
            return .object([
                "finished": .array(split.finished.map(JSONValue.string)),
                "remainder": .string(split.remainder),
                "accepted": .array(SessionLabelPolicy.accepted(split.finished, existing: existing).map(JSONValue.string)),
            ])
        }

        let labelled = Self.agent(50, .finished, title: "Fix the Login page", report: Self.report(.done, "Logins work again."),
                                  labels: [SessionLabel(value: "Bug", owner: .person, addedAt: Self.base),
                                           SessionLabel(value: "web ui", owner: .agent, addedAt: Self.base)])
        let queries = ["", "login", "LOGINS", "label:bug", "label:BUG login", "label:\"web ui\"", "label:web",
                       "label:", "nothing here", "label:bug nothing"]
        let queryCases = try queries.map {
            Case(name: $0.isEmpty ? "empty" : $0, input: .object(["query": .string($0), "agent": try Self.encode(labelled)]))
        }
        try pin("labels/query.json", queryCases) { input in
            let query = SessionLabelQuery(input["query"]!.stringValue!)
            return .object(["label": query.label.map(JSONValue.string) ?? .null, "text": .string(query.text),
                            "matches": .bool(query.matches(try input["agent"]!.decode(Agent.self)))])
        }
    }

    // MARK: reducer/

    static func notify(_ method: String, _ params: some Encodable) throws -> JSONValue {
        .object(["notify": .object(["method": .string(method), "params": try encode(params)])])
    }

    @Test func reducer() throws {
        let one = Self.agent(60, .running, minutes: 1)
        let two = Self.agent(61, .finished, minutes: 2, report: Self.report(.done))
        let permission = PermissionRequest(id: Self.id(70), agentID: one.id,
                                           toolCall: Self.call("p1", "rm -rf build", kind: "execute"),
                                           options: [PermissionOption(optionID: "allow", name: "Allow", kind: .allowOnce),
                                                     PermissionOption(optionID: "deny", name: "Deny", kind: .rejectOnce)],
                                           askedAt: Self.at(3))
        let earlier = PermissionRequest(id: Self.id(71), agentID: two.id, toolCall: Self.call("p2", "Write a"),
                                        options: [], askedAt: Self.at(1))
        let question = ElicitationRequest(id: Self.id(72), agentID: one.id, message: "Which?",
                                          mode: .form(ElicitationSchema(properties: [
                                              .init(name: "pick", isRequired: true,
                                                    kind: .string(format: nil, minLength: nil, maxLength: nil,
                                                                  choices: [.init(value: "a"), .init(value: "b")]))])),
                                          askedAt: Self.at(3))
        typealias N = DaemonAPI.Notification
        let entryOf = { (n: Int, agent: UUID, text: String) throws -> JSONValue in
            try Self.notify(N.agentEntry, DaemonAPI.EntryNotification(
                agentID: agent, entry: Self.entry(n, .agentMessage(messageID: "r", text: text))))
        }
        var moved = one
        moved.lastActivityAt = Self.at(9)
        let streams: [(String, [JSONValue])] = [
            ("agents arrive and change, newest first", [
                try Self.notify(N.agentChanged, one), try Self.notify(N.agentChanged, two),
                try Self.notify(N.agentChanged, moved),
            ]),
            ("an agent removed takes its cards with it", [
                try Self.notify(N.agentChanged, one), try Self.notify(N.agentChanged, two),
                try Self.notify(N.agentPermission, DaemonAPI.PermissionNotification(agentID: one.id, request: permission)),
                try Self.notify(N.agentElicitation, DaemonAPI.ElicitationNotification(agentID: one.id, requestID: question.id,
                                                                                      request: question)),
                try Self.notify(N.agentRemoved, DaemonAPI.AgentRemovedNotification(agentID: one.id)),
            ]),
            ("permissions in order asked, withdrawn by id or all at once", [
                try Self.notify(N.agentPermission, DaemonAPI.PermissionNotification(agentID: one.id, request: permission)),
                try Self.notify(N.agentPermission, DaemonAPI.PermissionNotification(agentID: two.id, request: earlier)),
                try Self.notify(N.agentPermission, DaemonAPI.PermissionNotification(agentID: one.id, request: nil,
                                                                                    requestID: permission.id)),
                try Self.notify(N.agentPermission, DaemonAPI.PermissionNotification(agentID: one.id, request: permission)),
                try Self.notify(N.agentPermission, DaemonAPI.PermissionNotification(agentID: two.id, request: nil)),
            ]),
            ("a question asked and answered", [
                try Self.notify(N.agentElicitation, DaemonAPI.ElicitationNotification(agentID: one.id, requestID: question.id,
                                                                                      request: question)),
                try Self.notify(N.agentElicitation, DaemonAPI.ElicitationNotification(agentID: one.id, requestID: question.id,
                                                                                      request: nil)),
            ]),
            ("entries for the agent watched, and no other", [
                .object(["watch": .string(one.id.uuidString)]),
                try entryOf(1, one.id, "Hel"), try entryOf(2, one.id, "lo"), try entryOf(3, two.id, "Not mine"),
            ]),
            ("entries heard before the page land after it, once", [
                .object(["watch": .string(one.id.uuidString)]),
                try entryOf(5, one.id, "late"),
                try entryOf(4, one.id, "on the page"),
                .object(["page": try Self.encode(TranscriptPage(firstIndex: 3, total: 5, entries: [
                    Self.entry(1, .userMessage("Hi")), Self.entry(4, .agentMessage(messageID: "q", text: "on the page"))]))]),
                try entryOf(4, one.id, "on the page"),
                try entryOf(6, one.id, " and more"),
            ]),
        ]
        let cases = streams.map { Case(name: $0.0, input: .object(["steps": .array($0.1)])) }
        try pin("reducer/streams.json", cases) { input in
            let model = AgentsModel()
            for step in input["steps"]?.arrayValue ?? [] {
                if let note = step["notify"] {
                    model.apply(note["method"]!.stringValue!, note["params"])
                } else if let watch = step["watch"]?.stringValue {
                    model.watching = UUID(uuidString: watch)
                } else if let page = step["page"] {
                    model.replaceTranscript(with: try page.decode(TranscriptPage.self))
                }
            }
            let ids: ([UUID]) -> JSONValue = { .array($0.map { .string($0.uuidString) }) }
            return .object([
                "agents": ids(model.agents.map(\.id)),
                "permissions": ids(model.permissions.map(\.id)),
                "elicitations": ids(model.elicitations.map(\.id)),
                "entries": ids(model.entries.map(\.id)),
                "items": .array(try model.transcriptItems.map(Self.digest)),
                "firstEntryIndex": .int(model.firstEntryIndex),
            ])
        }
    }
    // MARK: options/

    /// The prompt's menus: which options are drawn and in what order, which sit apart as
    /// permission, what a closed menu says, and what a new agent's mode opens on.
    @Test func options() throws {
        func choices(_ values: String...) -> [ConfigChoice] {
            values.map { ConfigChoice(value: .string($0), name: $0.capitalized) }
        }
        let mode = ConfigOption(id: "mode", name: "Mode", category: "mode", type: "select",
                                currentValue: .string("default"), options: choices("default", "acceptEdits", "plan"))
        let model = ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                                 currentValue: .string("opus"), options: choices("opus", "sonnet"))
        let effort = ConfigOption(id: "effort", name: "Effort", category: "thought_level", type: "select",
                                  currentValue: .string("high"), options: choices("low", "high"))
        let fast = ConfigOption(id: "fast", name: "Fast", type: "boolean", currentValue: .bool(false))
        let odd = ConfigOption(id: "slider", name: "Slider", type: "slider")
        let empty = ConfigOption(id: "empty", name: "Empty", category: "model", type: "select", options: [])
        let allow = ConfigOption(id: "allow", name: "Allow all", category: "permissions", type: "boolean")
        let newCategory = ConfigOption(id: "voice", name: "Voice", category: "voice", type: "select",
                                       options: choices("calm"))
        let grouped = ConfigOption(id: "mode", name: "Mode", kind: .select([
            ConfigChoiceGroup(name: "Safe", choices: choices("ask")),
            ConfigChoiceGroup(name: "Fast", choices: choices("auto"))]))
        let sets: [(String, [ConfigOption], [ConfigOption], JSONValue?)] = [
            ("agent's own, in category order", [fast, newCategory, model, effort, odd, empty, mode, allow], [], .string("plan")),
            ("an agent's empty list falls to the draft", [], [effort, model], nil),
            ("nothing drawable", [odd, empty], [], nil),
            ("a remembered mode no longer offered", [mode], [], .string("bypassPermissions")),
            ("grouped choices; mode found by id", [grouped], [], .string("auto")),
        ]
        let cases = try sets.map { name, agent, draft, remembered in
            Case(name: name, input: .object([
                "agentOptions": .array(try agent.map(Self.encode)), "draftOptions": .array(try draft.map(Self.encode)),
                "remembered": remembered ?? .null,
            ]))
        }
        try pin("options/drawable.json", cases) { input in
            let agent = try input["agentOptions"]!.decode([ConfigOption].self)
            let draft = try input["draftOptions"]!.decode([ConfigOption].self)
            let drawn = PromptControlsState.drawable(agentOptions: agent, draftOptions: draft)
            let remembered = input["remembered"].flatMap { $0.isNull ? nil : $0 }
            let modeOption = ModeMemory.modeOption(in: drawn)
            return .object([
                "drawn": .array(drawn.map { .string($0.id) }),
                "permission": .array(drawn.filter(\.isAboutPermission).map { .string($0.id) }),
                "titles": .array(drawn.map { .string($0.closedTitle(for: nil)) }),
                "mode": modeOption.map { .string($0.id) } ?? .null,
                "modeStartsOn": modeOption.flatMap { ModeMemory.startingValue(remembered: remembered, for: $0) } ?? .null,
            ])
        }
    }

    // MARK: overrides/

    /// A Swift-encoded sample of every case of each type whose TypeScript is hand-written
    /// (`Packages/WebTypes/Overrides`), so `Web/test/shapes.test.mjs` can hold the
    /// hand-written shape to real JSON (T020, T042).
    @Test func overrideSamples() throws {
        let stamp = FileStamp(size: 12, modifiedAt: Self.base)
        let text = Data("hi".utf8)
        let samples: [(String, [(String, any Encodable)])] = [
            ("ConfigOption", [
                ("select", ConfigOption(id: "model", name: "Model", description: "Which model", category: "model",
                                        type: "select", currentValue: .string("a"),
                                        options: [ConfigChoice(value: .string("a"), name: "A", description: "First")])),
                ("grouped", ConfigOption(id: "mode", name: "Mode", kind: .select([
                    ConfigChoiceGroup(name: "Safe", choices: [ConfigChoice(value: .string("ask"), name: "Ask")]),
                    ConfigChoiceGroup(name: "Fast", choices: [ConfigChoice(value: .string("auto"), name: "Auto")])]))),
                ("boolean", ConfigOption(id: "fast", name: "Fast", type: "boolean", currentValue: .bool(true))),
                ("unsupported", ConfigOption(id: "x", name: "X", type: "slider")),
            ]),
            ("ContentBlock", [
                ("text", ContentBlock.text("Hello")),
                ("image", ContentBlock.image(data: text, mimeType: "image/png", uri: "file:///a.png")),
                ("audio", ContentBlock.audio(data: text, mimeType: "audio/wav")),
                ("resource link", ContentBlock.resourceLink(uri: "file:///a.txt", name: "a.txt", mimeType: "text/plain",
                                                            size: 2)),
                ("resource", ContentBlock.resource(uri: "file:///b.txt", text: "b", blob: nil, mimeType: "text/plain")),
            ]),
            ("FileReading", [
                ("text", FileReading.text("hello", isTruncated: false, size: 5, stamp: stamp)),
                ("image", FileReading.image(text, describedAs: "PNG image, 1 × 1", stamp: stamp)),
                ("other", FileReading.other(describedAs: "Binary file", size: 12, stamp: stamp)),
                ("unchanged", FileReading.unchanged(stamp)),
            ]),
            ("GitView", [
                ("owned", GitView.owned(since: "abc123")),
                ("shared", GitView.shared(since: "abc123")),
                ("shared from head", GitView.sharedFromHead),
                ("unavailable", GitView.unavailable(.notARepository)),
                ("failed", GitView.unavailable(.failed(message: "no"))),
            ]),
            ("NeedID", [
                ("permission", NeedID.permission(Self.id(1))),
                ("elicitation", NeedID.elicitation(Self.id(2))),
                ("report", NeedID.report(Self.id(3), Self.base)),
            ]),
            ("Retirement", [
                ("at", Retirement.at(Self.base)),
                ("next under the cap", Retirement.nextUnderCap),
                ("held", Retirement.held(.worktreeHasWork)),
            ]),
            ("RuntimeAvailability", [
                ("available", RuntimeAvailability.available(path: "/bin/claude", supportsResume: true)),
                ("missing", RuntimeAvailability.missing(lookedIn: ["/bin"])),
                ("needs sign-in", RuntimeAvailability.needsSignIn(authMethods: ["oauth"], fixCommand: "claude login")),
                ("failed", RuntimeAvailability.failed(reason: "no")),
                ("installing", RuntimeAvailability.installing(progress: "50%")),
                ("install failed", RuntimeAvailability.installFailed(reason: "no")),
            ]),
            ("Surface", [("mac", Surface.mac), ("device", Surface.device(Self.id(4)))]),
            ("ToolCallContent", [
                ("content", ToolCallContent.content(.text("out"))),
                ("diff", ToolCallContent.diff(.init(path: "/a.swift", oldText: "a", newText: "b"))),
                ("new file", ToolCallContent.diff(.init(path: "/b.swift", oldText: nil, newText: "b"))),
                ("terminal", ToolCallContent.terminal("term-1")),
            ]),
            ("WorkflowTrigger", [
                // One minute and one day: a Set encodes in no fixed order.
                ("schedule", WorkflowTrigger.schedule(WorkflowSchedule(minutes: [30], hours: 9...17, days: [.mon]))),
                ("agent finished", WorkflowTrigger.agentFinished),
                ("asked permission", WorkflowTrigger.agentAskedPermission),
                ("asked a form", WorkflowTrigger.agentAskedForm),
                ("stopped", WorkflowTrigger.agentStopped),
                ("workflow completed", WorkflowTrigger.workflowCompleted(id: "nightly")),
                ("event", WorkflowTrigger.event(EventPattern("ci.finished", filters: ["branch": "main"]))),
            ]),
        ]
        for (type, values) in samples {
            let cases = try values.map { Case(name: $0.0, input: try Self.encodeAny($0.1)) }
            try pin("overrides/\(type).json", cases) { _ in .string(type) }
        }
    }
}
