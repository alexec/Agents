import Foundation
import Testing
@testable import AgentsKitCore

/// Chats fetched before they are opened (#4795): drawn at once on opening, held in memory
/// only, a few of them, and never over a page the host gave.
@MainActor
@Suite("Opening prefetch")
struct OpeningPrefetchTests {
    private struct Failed: Error {}

    private func opening(_ count: Int, turnsFailure: String? = nil) -> ChatOpening.Loaded {
        ChatOpening.Loaded(turns: TurnsPage(turns: [], firstTurn: 0, openStart: 0),
                           page: TranscriptPage(firstIndex: 0, total: count,
                                                entries: (0..<count).map { TranscriptEntry(kind: .agentMessage(messageID: nil, text: "e\($0)")) }),
                           turnsFailure: turnsFailure)
    }

    @Test func aFetchedChatIsTakenOnce() async {
        let prefetch = OpeningPrefetch()
        let session = UUID()
        await prefetch.prefetch(session) { self.opening(3) }?.value
        #expect(prefetch.take(session)?.page.entries.count == 3)
        #expect(prefetch.take(session) == nil)
    }

    @Test func oneHeldIsNotFetchedAgain() async {
        let prefetch = OpeningPrefetch()
        let session = UUID()
        var fetches = 0
        await prefetch.prefetch(session) { fetches += 1; return self.opening(1) }?.value
        #expect(prefetch.prefetch(session) { fetches += 1; return self.opening(1) } == nil)
        #expect(fetches == 1)
    }

    @Test func aFailedFetchOrOneWithoutItsTurnsHoldsNothing() async {
        let prefetch = OpeningPrefetch()
        let failed = UUID(), noTurns = UUID()
        await prefetch.prefetch(failed) { throw Failed() }?.value
        await prefetch.prefetch(noTurns) { self.opening(2, turnsFailure: "old host") }?.value
        #expect(prefetch.take(failed) == nil)
        #expect(prefetch.take(noTurns) == nil)
    }

    @Test func aStaleOneIsNotDrawn() async {
        let prefetch = OpeningPrefetch()
        prefetch.fresh = .zero
        let session = UUID()
        await prefetch.prefetch(session) { self.opening(1) }?.value
        #expect(prefetch.take(session) == nil)
    }

    @Test func onlyTheNewestFewAreHeld() async {
        let prefetch = OpeningPrefetch()
        prefetch.kept = 2
        let first = UUID(), second = UUID(), third = UUID()
        for id in [first, second, third] { await prefetch.prefetch(id) { self.opening(1) }?.value }
        #expect(!prefetch.isHeld(first))
        #expect(prefetch.isHeld(second) && prefetch.isHeld(third))
    }

    @Test func theNeighboursAreTheRowsEitherSide() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let ids = [a, b, c, d]
        #expect(OpeningPrefetch.neighbours(of: b, in: ids) == [c, a])
        #expect(OpeningPrefetch.neighbours(of: a, in: ids) == [b])
        #expect(OpeningPrefetch.neighbours(of: d, in: ids) == [c])
        #expect(OpeningPrefetch.neighbours(of: UUID(), in: ids).isEmpty)
    }

    @Test func aPrefetchedChatDrawsOnOpeningAndTheHostsPageReplacesIt() async {
        let work = AgentsModel()
        let keeper = LocalCopyKeeper(copy: LocalCopy(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("prefetch-\(UUID().uuidString)"), cap: LocalCopy.macCap), work: work)
        let session = UUID()
        await keeper.prefetched.prefetch(session) { self.opening(5) }?.value
        work.watching = session
        let load = work.beginTranscriptLoad()
        #expect(keeper.drawPrefetched(of: session, load: load))
        #expect(work.entries.count == 5)
        #expect(work.transcriptFromCopy)
        #expect(work.takeOpening(opening(7), load: load))
        #expect(work.entries.count == 7)
        #expect(!work.transcriptFromCopy)
        await keeper.forget()
    }
}
