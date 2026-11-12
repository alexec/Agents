import Foundation
import Testing
@testable import AgentsKitCore

/// Resume by revision (#4794; spec 4777-fast, "clients resume from their host"): on reconnect
/// and at launch a client asks only for the sessions changed since its point and the entries
/// written since its chat's end, and falls back to the whole list or page when the host
/// cannot say.
@MainActor
@Suite("Resume by revision")
struct ResumeByRevisionTests {
    private let path = URL(filePath: "/home/alex/src/api")
    private let point = DaemonAPI.ListRevision(epoch: "e1", revision: 7)

    private func agent(_ title: String, state: AgentState = .finished) -> Agent {
        Agent(runtimeID: "claude", cwd: path, title: title, state: state, endedReason: .endTurn)
    }

    private func page(_ texts: [String], firstIndex: Int, total: Int? = nil) -> TranscriptPage {
        TranscriptPage(firstIndex: firstIndex, total: total ?? firstIndex + texts.count,
                       entries: texts.map { TranscriptEntry(kind: .agentMessage(messageID: nil, text: $0)) })
    }

    private func opened(_ model: AgentsModel, _ texts: [String], firstIndex: Int = 0) -> Int {
        let load = model.beginTranscriptLoad()
        model.takeOpening(ChatOpening.Loaded(turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                             page: page(texts, firstIndex: firstIndex), turnsFailure: nil), load: load)
        return load
    }

    // MARK: The session list

    @Test func aWholeListKeepsItsPoint() {
        let model = AgentsModel()
        model.replaceAgents([agent("one")], from: .mac)
        model.notePoint(DaemonAPI.AgentChanges(epoch: "e1", revision: 7, all: true), of: .mac)
        #expect(model.listPoint(of: .mac) == point)
        model.notePoint(nil, of: .mac)
        #expect(model.listPoint(of: .mac) == nil)
    }

    @Test func changesAreLaidOnWhatIsHeld() {
        let model = AgentsModel()
        let kept = agent("kept")
        var renamed = agent("old name")
        let removed = agent("removed")
        model.replaceAgents([kept, renamed, removed], from: .mac)
        model.notePoint(DaemonAPI.AgentChanges(epoch: "e1", revision: 7, all: true), of: .mac)

        renamed.title = "new name"
        let started = agent("started", state: .running)
        model.takeChanges([renamed, started],
                          DaemonAPI.AgentChanges(epoch: "e1", revision: 9, removed: [removed.id], all: false), from: .mac)
        #expect(model.agent(kept.id) != nil)
        #expect(model.agent(renamed.id)?.title == "new name")
        #expect(model.agent(started.id)?.host == .mac)
        #expect(model.agent(removed.id) == nil)
        #expect(model.listPoint(of: .mac) == DaemonAPI.ListRevision(epoch: "e1", revision: 9))
    }

    /// An archived session this client does not hold stays out, as a lean agent/changed of one
    /// does; one it holds is archived in place.
    @Test func anArchivedOneNotHeldStaysOut() {
        let model = AgentsModel()
        var held = agent("held", state: .running)
        model.replaceAgents([held], from: .mac)
        held.state = .archived
        let elsewhere = agent("never held", state: .archived)
        model.takeChanges([held, elsewhere], DaemonAPI.AgentChanges(epoch: "e1", revision: 8, all: false), from: .mac)
        #expect(model.agent(held.id)?.state == .archived)
        #expect(model.agent(elsewhere.id) == nil)
    }

    /// Changes from one host leave another host's sessions, and a removal names only its own.
    @Test func changesTouchOnlyTheirHost() {
        let model = AgentsModel()
        let devbox = MachineRef(rawValue: "devbox01")
        let theirs = agent("theirs")
        model.replaceAgents([theirs], from: devbox)
        model.takeChanges([], DaemonAPI.AgentChanges(epoch: "e1", revision: 8, removed: [theirs.id], all: false), from: .mac)
        #expect(model.agent(theirs.id) != nil)
    }

    /// The copy's point is drawn with it, so a launch asks only for what changed since; the
    /// host's changes then make the machine the host's.
    @Test func aLaunchResumesFromTheCopysPoint() async {
        let model = AgentsModel()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
        let keeper = LocalCopyKeeper(copy: LocalCopy(folder: folder, cap: LocalCopy.macCap), work: model)
        defer { Task { await keeper.forget() } }
        let one = agent("one")
        await keeper.copy.keep(LocalCopy.Machine(host: .mac, folders: [], agents: [one], point: point))
        await keeper.drawMachines()
        #expect(model.listPoint(of: .mac) == point)
        #expect(model.drawnFromCopy == [.mac])
        model.takeChanges([], DaemonAPI.AgentChanges(epoch: "e1", revision: 7, all: false), from: .mac)
        #expect(model.drawnFromCopy.isEmpty)
        #expect(model.agent(one.id) != nil)
    }

    /// A copy made before the point decodes with none, and the launch asks for all.
    @Test func aCopyFromBeforeHasNoPoint() throws {
        let machine = LocalCopy.Machine(host: .mac, folders: [], agents: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(machine)) as? [String: Any] ?? [:]
        json["point"] = nil
        let read = try JSONDecoder().decode(LocalCopy.Machine.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.point == nil)
    }

    /// A host let go of loses its point too: nothing resumes onto an empty list.
    @Test func anEmptiedHostLosesItsPoint() {
        let model = AgentsModel()
        model.replaceAgents([agent("one")], from: .mac)
        model.notePoint(DaemonAPI.AgentChanges(epoch: "e1", revision: 7, all: true), of: .mac)
        model.replaceAgents([], from: .mac)
        #expect(model.listPoint(of: .mac) == nil)
    }

    // MARK: The open chat

    @Test func aChatResumesFromItsHostsEnd() async {
        let model = AgentsModel()
        let session = UUID()
        model.watching = session
        _ = opened(model, ["e0", "e1"])
        #expect(model.transcriptEnd == 2)

        let load = model.beginTranscriptLoad()
        var asked: Int?
        let resumed = await model.resumeTranscript(load: load) { from, _ in
            asked = from
            return page(["e2", "e3"], firstIndex: from)
        }
        #expect(asked == 2)
        #expect(resumed != nil)
        #expect(model.entries.compactMap(\.text) == ["e0", "e1", "e2", "e3"])
        #expect(model.transcriptEnd == 4)
    }

    /// More written than one page holds leaves a gap: nothing is laid on, and the chat opens whole.
    @Test func aGapOpensTheChatWhole() async {
        let model = AgentsModel()
        model.watching = UUID()
        _ = opened(model, ["e0", "e1"])
        let load = model.beginTranscriptLoad()
        let resumed = await model.resumeTranscript(load: load) { _, _ in page(["e900"], firstIndex: 900) }
        #expect(resumed == nil)
        #expect(model.entries.compactMap(\.text) == ["e0", "e1"])
        #expect(model.transcriptEnd == 2)
    }

    /// No answer, or nothing held, is no resume.
    @Test func noAnswerOrNothingHeldIsNoResume() async {
        let model = AgentsModel()
        model.watching = UUID()
        struct Down: Error {}
        let none = await model.resumeTranscript(load: model.beginTranscriptLoad()) { _, _ in page([], firstIndex: 0) }
        #expect(none == nil)
        _ = opened(model, ["e0"])
        let failed = await model.resumeTranscript(load: model.beginTranscriptLoad()) { _, _ in throw Down() }
        #expect(failed == nil)
        #expect(model.entries.count == 1)
    }

    /// An entry heard while the resume was on its way, and on its page too, is drawn once.
    @Test func whatWasHeardIsDrawnOnce() async throws {
        let model = AgentsModel()
        let session = UUID()
        model.watching = session
        _ = opened(model, ["e0"])
        let load = model.beginTranscriptLoad()
        let heard = TranscriptEntry(kind: .agentMessage(messageID: nil, text: "heard"))
        model.apply(DaemonAPI.Notification.agentEntry,
                    try JSONValue.encoding(DaemonAPI.EntryNotification(agentID: session, entry: heard)))
        let resumed = await model.resumeTranscript(load: load) { from, _ in
            TranscriptPage(firstIndex: from, total: from + 1, entries: [heard])
        }
        #expect(resumed != nil)
        #expect(model.entries.compactMap(\.text) == ["e0", "heard"])
    }

    /// A chat drawn from the copy resumes from the copy's end and is the host's after.
    @Test func aCopiedChatResumesFromTheCopysEnd() async {
        let model = AgentsModel()
        let session = UUID()
        model.watching = session
        let load = model.beginTranscriptLoad()
        model.takeCopiedOpening(LocalCopy.Transcript(session: session, turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                                     page: page(["e5"], firstIndex: 5)), load: load)
        #expect(model.transcriptFromCopy)
        let resumed = await model.resumeTranscript(load: load) { from, _ in page(["e6"], firstIndex: from) }
        #expect(resumed != nil)
        #expect(!model.transcriptFromCopy)
        #expect(model.entries.compactMap(\.text) == ["e5", "e6"])
    }

    /// The copy keeps the host's count, not the entries held: one heard but never written
    /// would count past it, and a resume from there would miss what was written.
    @Test func theCopyKeepsTheHostsEnd() throws {
        let model = AgentsModel()
        let session = UUID()
        model.watching = session
        _ = opened(model, ["e0", "e1"])
        model.apply(DaemonAPI.Notification.agentEntry, try JSONValue.encoding(DaemonAPI.EntryNotification(
            agentID: session, entry: TranscriptEntry(kind: .agentMessage(messageID: nil, text: "heard")))))
        #expect(model.shownTranscript(of: session)?.page.total == 2)
    }
}
