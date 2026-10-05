import Foundation
import Testing
@testable import AgentsKitCore

/// #176: a drag on the Dashboard while a refresh is on its way neither loses nor doubles a
/// tile, and the host ends with the last drop.
@Suite("Dashboard order sync")
struct DashboardOrderSyncTests {
    private let folder = URL(filePath: "/tmp/somewhere/api")

    private func order(_ ids: String...) -> DashboardOrder {
        DashboardOrder(sections: [.init(title: nil, tiles: ids)])
    }

    private func snapshot(_ order: DashboardOrder?) -> DashboardSnapshot {
        DashboardSnapshot(folder: folder, tiles: [], now: Date(), order: order)
    }

    /// The race as the review found it: two quick drops while a refresh is out, and the
    /// replies landing in the worst order.
    @Test func aRefreshThatLandsDuringADragDoesNotUndoIt() throws {
        var sync = DashboardOrderSync()
        var host = order("a", "b", "c")
        var shown = host

        let early = sync.beginFetch(in: folder)
        let earlyReply = snapshot(host)

        // First drop: shown at once and sent.
        let first = order("b", "a", "c")
        shown = first
        let sends = sync.arrange(first, in: folder)
        #expect(sends)
        let sent = sync.takeUnsent(in: folder)
        #expect(sent == first)

        // Second drop while the first is out: waits, and is what goes next.
        let second = order("c", "b", "a")
        shown = second
        let sendsToo = sync.arrange(second, in: folder)
        #expect(!sendsToo)

        // The refresh from before either drop lands: the drops stay.
        shown = sync.accept(earlyReply, ticket: early)?.order ?? shown
        #expect(shown == second)

        // The first send lands; its dashboard/changed asks again, and the host says first.
        host = try #require(sent)
        let middle = sync.beginFetch(in: folder)
        let middleReply = snapshot(host)

        // Then the second is sent and lands, and the send is over.
        let next = sync.takeUnsent(in: folder)
        #expect(next == second)
        host = try #require(next)
        let more = sync.takeUnsent(in: folder)
        #expect(more == nil)

        // The fetch after the sends, and then the one from the middle, late.
        let last = sync.beginFetch(in: folder)
        shown = sync.accept(snapshot(host), ticket: last)?.order ?? shown
        #expect(shown == second)
        let late = sync.accept(middleReply, ticket: middle)
        #expect(late == nil, "older than what is shown")
        #expect(host == second, "the host keeps the last drop")
    }

    /// Once everything is sent and fetched back, the host's word is the screen's again:
    /// an agent moving a tile afterwards is shown.
    @Test func afterTheSendsTheHostIsBelievedAgain() {
        var sync = DashboardOrderSync()
        _ = sync.arrange(order("b", "a"), in: folder)
        _ = sync.takeUnsent(in: folder)
        _ = sync.takeUnsent(in: folder)
        _ = sync.accept(snapshot(order("b", "a")), ticket: sync.beginFetch(in: folder))

        let moved = order("a", "b")
        let ticket = sync.beginFetch(in: folder)
        let shown = sync.accept(snapshot(moved), ticket: ticket)
        #expect(shown?.order == moved)
    }

    /// A failed send: the fetch after it shows what the host really has.
    @Test func aSendThatFailedIsUndoneByTheNextFetch() {
        var sync = DashboardOrderSync()
        let kept = order("a", "b")
        _ = sync.arrange(order("b", "a"), in: folder)
        _ = sync.takeUnsent(in: folder)
        // The host refused it, and nothing else was arranged.
        _ = sync.takeUnsent(in: folder)
        let ticket = sync.beginFetch(in: folder)
        let shown = sync.accept(snapshot(kept), ticket: ticket)
        #expect(shown?.order == kept)
    }

    /// Every interleaving at once: random drops, refreshes begun, read by the host and
    /// answered in any order, sends landing. When it all settles, the host and the screen
    /// both have the last drop, and every tile is on it once.
    @Test(arguments: 0..<200)
    func anyInterleavingEndsWithTheLastDrop(seed: Int) {
        var random = SplitMix(seed: UInt64(seed))
        var sync = DashboardOrderSync()
        let tiles = ["a", "b", "c", "d", "e"]
        var host = DashboardOrder(sections: [.init(title: nil, tiles: tiles)])
        var shown = host
        var lastDrop: DashboardOrder?
        var inFlight: DashboardOrder?
        var asked: [Int] = []                 // fetches begun, not yet read by the host
        var replies: [(Int, DashboardSnapshot)] = []

        func show(_ reply: (Int, DashboardSnapshot)) {
            if let kept = sync.accept(reply.1, ticket: reply.0) { shown = kept.order ?? shown }
        }
        func landWrite() {
            guard let write = inFlight else { return }
            host = write
            asked.append(sync.beginFetch(in: folder))       // its dashboard/changed
            inFlight = sync.takeUnsent(in: folder)
            if inFlight == nil { asked.append(sync.beginFetch(in: folder)) }   // the refresh after the sends
        }

        for _ in 0..<40 {
            switch random.next() % 5 {
            case 0:
                // A drop: one tile moved somewhere else in what is shown.
                var ids = shown.tiles
                let tile = ids.remove(at: Int(random.next() % UInt64(ids.count)))
                ids.insert(tile, at: Int(random.next() % UInt64(ids.count + 1)))
                let drop = DashboardOrder(sections: [.init(title: nil, tiles: ids)])
                shown = drop
                lastDrop = drop
                if sync.arrange(drop, in: folder) { inFlight = sync.takeUnsent(in: folder) }
            case 1:
                asked.append(sync.beginFetch(in: folder))
            case 2:
                if !asked.isEmpty { replies.append((asked.removeFirst(), snapshot(host))) }
            case 3:
                if !replies.isEmpty { show(replies.remove(at: Int(random.next() % UInt64(replies.count)))) }
            default:
                landWrite()
            }
            #expect(shown.tiles.sorted() == tiles, "each tile once, whatever landed")
        }
        // Everything lands, in any order.
        while inFlight != nil { landWrite() }
        for ticket in asked { replies.append((ticket, snapshot(host))) }
        while !replies.isEmpty { show(replies.remove(at: Int(random.next() % UInt64(replies.count)))) }

        if let lastDrop {
            #expect(host == lastDrop)
            #expect(shown == lastDrop)
        }
        #expect(shown.tiles.sorted() == tiles)
    }
}

/// A seeded generator, so a failing interleaving can be run again.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
