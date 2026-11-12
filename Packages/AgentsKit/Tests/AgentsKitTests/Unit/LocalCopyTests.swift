import Foundation
import Testing
@testable import AgentsKitCore

/// The Mac window's and the Remote's local copy (#4791): kept in plain files, drawn before
/// the host answers, and the host always wins.
@MainActor
@Suite("The local copy")
struct LocalCopyTests {
    private let devbox = MachineRef(rawValue: "devbox01")
    private let path = URL(filePath: "/home/alex/src/api")

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("local-copy-\(UUID().uuidString)", isDirectory: true)
    }

    private func agent(_ title: String = "t", state: AgentState = .finished) -> Agent {
        Agent(runtimeID: "claude", cwd: path, title: title, state: state, endedReason: .endTurn)
    }

    private func summary() -> DaemonAPI.FolderSummary {
        DaemonAPI.FolderSummary(folder: Folder(folder: path), name: "api", exists: true, lastActivityAt: Date(), counts: [:])
    }

    private func page(_ count: Int, firstIndex: Int = 0) -> TranscriptPage {
        TranscriptPage(firstIndex: firstIndex, total: firstIndex + count,
                       entries: (0..<count).map { TranscriptEntry(kind: .agentMessage(messageID: nil, text: "e\($0)")) })
    }

    private func opening(_ count: Int) -> ChatOpening.Loaded {
        ChatOpening.Loaded(turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0), page: page(count), turnsFailure: nil)
    }

    @Test func aMachineIsKeptAndReadBackWithItsHost() async {
        let copy = LocalCopy(folder: folder(), cap: LocalCopy.macCap)
        defer { Task { await copy.forget() } }
        let one = agent("one")
        await copy.keep(LocalCopy.Machine(host: devbox, folders: [summary()], agents: [one]))
        let read = await copy.allMachines()
        #expect(read.count == 1)
        #expect(read.first?.agents.map(\.id) == [one.id])
        #expect(read.first?.agents.first?.host == devbox)
        #expect(read.first?.folders.count == 1)
    }

    @Test func aTranscriptKeepsItsEndOnly() async {
        let copy = LocalCopy(folder: folder(), cap: LocalCopy.macCap)
        defer { Task { await copy.forget() } }
        let session = UUID()
        await copy.keep(LocalCopy.Transcript(session: session, turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                             page: page(LocalCopy.entriesKept + 50)))
        let kept = await copy.transcript(of: session)
        #expect(kept?.page.entries.count == LocalCopy.entriesKept)
        #expect(kept?.page.firstIndex == 50)
        #expect(kept?.page.entries.first?.text == "e50")
        #expect(await copy.transcript(of: UUID()) == nil)
    }

    @Test func theOldestTranscriptGoesFirst() async throws {
        let copy = LocalCopy(folder: folder(), cap: LocalCopy.macCap, transcriptsKept: 2)
        defer { Task { await copy.forget() } }
        let (oldest, older, newest) = (UUID(), UUID(), UUID())
        for session in [oldest, older, newest] {
            await copy.keep(LocalCopy.Transcript(session: session, turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                                 page: page(3)))
            // Modification dates are what order them; a clock tick apart.
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await copy.transcript(of: oldest) == nil)
        #expect(await copy.transcript(of: older) != nil)
        #expect(await copy.transcript(of: newest) != nil)
    }

    @Test func overTheCapTranscriptsGo() async {
        let copy = LocalCopy(folder: folder(), cap: 1)
        defer { Task { await copy.forget() } }
        let session = UUID()
        await copy.keep(LocalCopy.Transcript(session: session, turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                             page: page(3)))
        #expect(await copy.transcript(of: session) == nil)
    }

    @Test func refsAreTheWebPagesAndNameAFile() {
        let session = UUID(uuidString: "6A2F0D7E-0000-4000-8000-000000000001")!
        #expect(LocalCopy.sessionRef(session).description == "agents:session:#6a2f0d7e-0000-4000-8000-000000000001")
        #expect(LocalCopy.machineRef(devbox).description == "agents:machine:#devbox01")
        #expect(LocalCopy.fileName(LocalCopy.machineRef(devbox)) == "agents_machine__devbox01.json")
    }

    /// Drawn before the host answers, marked as the copy; the host's list then replaces it.
    @Test func theCopyIsDrawnAndTheHostWins() async {
        let model = AgentsModel()
        let keeper = LocalCopyKeeper(copy: LocalCopy(folder: folder(), cap: LocalCopy.macCap), work: model)
        defer { Task { await keeper.forget() } }
        let gone = agent("gone")
        await keeper.copy.keep(LocalCopy.Machine(host: .mac, folders: [summary()], agents: [gone]))
        await keeper.drawMachines()
        #expect(model.agent(gone.id) != nil)
        #expect(model.drawnFromCopy == [.mac])

        let live = agent("live")
        model.replaceAgents([live], from: .mac)
        #expect(model.agent(gone.id) == nil)
        #expect(model.agent(live.id) != nil)
        #expect(model.drawnFromCopy.isEmpty)
    }

    /// A machine already listed by its host is never drawn over.
    @Test func aListedMachineIsNotDrawnOver() async {
        let model = AgentsModel()
        let keeper = LocalCopyKeeper(copy: LocalCopy(folder: folder(), cap: LocalCopy.macCap), work: model)
        defer { Task { await keeper.forget() } }
        await keeper.copy.keep(LocalCopy.Machine(host: .mac, folders: [summary()], agents: [agent("old")]))
        let live = agent("live")
        model.replaceAgents([live], from: .mac)
        await keeper.drawMachines()
        #expect(model.agents.map(\.id) == [live.id])
        #expect(model.drawnFromCopy.isEmpty)
    }

    /// A host's list is written after a pause; what was drawn from the copy is not.
    @Test func aHostsListIsWritten() async throws {
        let model = AgentsModel()
        let keeper = LocalCopyKeeper(copy: LocalCopy(folder: folder(), cap: LocalCopy.macCap), work: model)
        defer { Task { await keeper.forget() } }
        keeper.writeAfter = .milliseconds(10)
        let live = agent("live")
        model.replaceAgents([live], from: devbox)
        try await Task.sleep(for: .milliseconds(200))
        let read = await keeper.copy.allMachines()
        #expect(read.first?.host == devbox)
        #expect(read.first?.agents.map(\.id) == [live.id])
    }

    /// The chat opens on its kept end; the host's page replaces it, with what was heard
    /// meanwhile laid over it.
    @Test func aChatOpensOnItsCopyAndTheHostsPageReplacesIt() async throws {
        let model = AgentsModel()
        let keeper = LocalCopyKeeper(copy: LocalCopy(folder: folder(), cap: LocalCopy.macCap), work: model)
        defer { Task { await keeper.forget() } }
        let session = UUID()
        await keeper.copy.keep(LocalCopy.Transcript(session: session, turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                                    page: page(2)))
        model.watching = session
        let load = model.beginTranscriptLoad()
        #expect(await keeper.drawOpening(of: session, load: load))
        #expect(model.transcriptFromCopy)
        #expect(model.entries.compactMap(\.text) == ["e0", "e1"])

        model.apply(DaemonAPI.Notification.agentEntry, try JSONValue.encoding(DaemonAPI.EntryNotification(
            agentID: session, entry: TranscriptEntry(kind: .agentMessage(messageID: nil, text: "heard")))))
        #expect(model.takeOpening(opening(3), load: load))
        #expect(!model.transcriptFromCopy)
        #expect(model.entries.compactMap(\.text) == ["e0", "e1", "e2", "heard"])
    }

    /// A host that answered first is not drawn over by the copy.
    @Test func theCopyNeverReplacesTheHostsPage() async {
        let model = AgentsModel()
        let keeper = LocalCopyKeeper(copy: LocalCopy(folder: folder(), cap: LocalCopy.macCap), work: model)
        defer { Task { await keeper.forget() } }
        let session = UUID()
        await keeper.copy.keep(LocalCopy.Transcript(session: session, turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                                    page: page(5)))
        model.watching = session
        let load = model.beginTranscriptLoad()
        model.takeOpening(opening(1), load: load)
        #expect(!(await keeper.drawOpening(of: session, load: load)))
        #expect(model.entries.count == 1)
    }

    /// Leaving a chat keeps what it showed, with what was added while it was read.
    @Test func leavingAChatKeepsItsEnd() async throws {
        let model = AgentsModel()
        let keeper = LocalCopyKeeper(copy: LocalCopy(folder: folder(), cap: LocalCopy.macCap), work: model)
        defer { Task { await keeper.forget() } }
        let session = UUID()
        model.watching = session
        let load = model.beginTranscriptLoad()
        model.takeOpening(opening(2), load: load)
        model.apply(DaemonAPI.Notification.agentEntry, try JSONValue.encoding(DaemonAPI.EntryNotification(
            agentID: session, entry: TranscriptEntry(kind: .agentMessage(messageID: nil, text: "added")))))
        model.watching = UUID()
        try await Task.sleep(for: .milliseconds(200))
        let kept = await keeper.copy.transcript(of: session)
        #expect(kept?.page.entries.compactMap(\.text) == ["e0", "e1", "added"])
    }
}
