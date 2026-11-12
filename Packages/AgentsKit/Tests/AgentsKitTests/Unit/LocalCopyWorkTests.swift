import Foundation
import Testing
@testable import AgentsKitCore

/// Work's part of the local copy (#4930): each answer kept by what was asked, read back only for
/// it, each group to its count, and the oldest Work entry first when the copy is over its cap.
@Suite("The local copy of Work")
struct LocalCopyWorkTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("local-copy-work-\(UUID().uuidString)", isDirectory: true)
    }

    private func item(_ n: Int) -> DaemonAPI.ForgeItem {
        DaemonAPI.ForgeItem(node: .init(kind: "issue", ref: "github:alexec/Agents#\(n)"), title: "Issue \(n)", state: "open",
                            url: "https://github.com/alexec/Agents/issues/\(n)", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func held(_ copy: LocalCopy, _ group: LocalCopy.WorkGroup) async -> Int {
        let at = await copy.work.appendingPathComponent(group.rawValue, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? []).count
    }

    @Test func anAnswerIsReadBackForWhatWasAskedOnly() async {
        let copy = LocalCopy(folder: folder(), cap: LocalCopy.macCap)
        defer { Task { await copy.forget() } }
        let list = DaemonAPI.ForgeList(items: [item(1), item(2)], cursor: "next", total: 9)
        await copy.keepWork(list, .list, "issue|open|newest|")
        #expect(await copy.work(DaemonAPI.ForgeList.self, .list, "issue|open|newest|") == list)
        #expect(await copy.work(DaemonAPI.ForgeList.self, .list, "issue|closed|newest|") == nil)
        // The same words in another group are another entry.
        #expect(await copy.work(DaemonAPI.ForgeList.self, .plan, "issue|open|newest|") == nil)
        // An entry of another form is no entry.
        #expect(await copy.work(DaemonAPI.ForgePlan.self, .list, "issue|open|newest|") == nil)
    }

    @Test func aPictureIsKeptByItsURL() async {
        let copy = LocalCopy(folder: folder(), cap: LocalCopy.macCap)
        defer { Task { await copy.forget() } }
        let url = "https://avatars.githubusercontent.com/u/1142830?v=4&size=" + String(repeating: "9", count: 400)
        await copy.keepWork(Data([1, 2, 3]), .image, url)
        #expect(await copy.work(Data.self, .image, url) == Data([1, 2, 3]))
    }

    @Test func eachGroupKeepsItsNewest() async {
        let copy = LocalCopy(folder: folder(), cap: LocalCopy.macCap)
        defer { Task { await copy.forget() } }
        let most = LocalCopy.WorkGroup.item.kept
        for n in 0 ..< most + 3 { await copy.keepWork(item(n), .item, "github:alexec/Agents#\(n)") }
        #expect(await held(copy, .item) == most)
        #expect(await copy.work(DaemonAPI.ForgeItem.self, .item, "github:alexec/Agents#\(most + 2)") != nil)
    }

    @Test func overTheCapTheOldestWorkEntryGoesBeforeATranscript() async throws {
        let copy = LocalCopy(folder: folder(), cap: 20_000)
        defer { Task { await copy.forget() } }
        let session = UUID()
        await copy.keep(LocalCopy.Transcript(session: session, turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                                             page: TranscriptPage(firstIndex: 0, total: 0, entries: [])))
        for n in 0 ..< 20 {
            await copy.keepWork(DaemonAPI.ForgeList(items: (0 ..< 10).map(item)), .list, "list \(n)")
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await copy.transcript(of: session) != nil)
        #expect(await copy.work(DaemonAPI.ForgeList.self, .list, "list 0") == nil)
        #expect(await copy.work(DaemonAPI.ForgeList.self, .list, "list 19") != nil)
    }

    @Test func aForgetTakesWorkWithIt() async {
        let copy = LocalCopy(folder: folder(), cap: LocalCopy.macCap)
        await copy.keepWork(item(1), .item, "github:alexec/Agents#1")
        await copy.forget()
        #expect(await copy.work(DaemonAPI.ForgeItem.self, .item, "github:alexec/Agents#1") == nil)
    }
}
