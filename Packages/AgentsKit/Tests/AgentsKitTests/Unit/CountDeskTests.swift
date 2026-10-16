import Foundation
import Testing
@testable import AgentsKitCore

/// The control plane's Needs you count for the devices (#1163): every host's added up, and
/// each device told when it moves and not otherwise.
@Suite("The count the devices are told")
struct CountDeskTests {
    private let mac = HostID(rawValue: "mac")
    private let server = HostID(rawValue: "devbox")
    private let phone = UUID(), pad = UUID()

    @Test func nothingIsOwedBeforeAHostHasSaidACount() async {
        let desk = CountDesk()
        #expect(await desk.total == nil)
        #expect(await desk.owed(to: [phone]).isEmpty, "a zero nobody said is not sent")
    }

    @Test func theHostsCountsAreAddedUp() async {
        let desk = CountDesk()
        #expect(await desk.heard(mac, waiting: 2))
        #expect(await desk.heard(server, waiting: 1))
        #expect(await desk.total == 3)
        #expect(await desk.heard(mac, waiting: 2) == false, "the same count again moves nothing")
    }

    @Test func eachDeviceIsToldOnceForEachCount() async {
        let desk = CountDesk()
        await desk.heard(mac, waiting: 2)
        let first = await desk.owed(to: [phone, pad])
        #expect(Set(first.map(\.device)) == [phone, pad])
        #expect(first.allSatisfy { $0.waiting == 2 })
        #expect(await desk.owed(to: [phone, pad]).isEmpty)
        await desk.heard(mac, waiting: 0)
        #expect(await desk.owed(to: [phone, pad]).map(\.waiting) == [0, 0], "a need met at the Mac clears it")
    }

    @Test func aDeviceToldOnANeedsPushIsNotToldAgain() async {
        let desk = CountDesk()
        await desk.heard(mac, waiting: 1)
        await desk.told(phone, 1)
        #expect(await desk.owed(to: [phone, pad]).map(\.device) == [pad])
    }

    @Test func aNewRelayHostTellsEveryDeviceAgain() async {
        let desk = CountDesk()
        await desk.heard(mac, waiting: 1)
        _ = await desk.owed(to: [phone])
        await desk.forgetTold()
        #expect(await desk.owed(to: [phone]).map(\.waiting) == [1])
    }

    @Test func oneFlushAtATime() async {
        let desk = CountDesk()
        #expect(await desk.startFlush())
        #expect(await desk.startFlush() == false, "a burst is one send")
        _ = await desk.owed(to: [])
        #expect(await desk.startFlush(), "the send ended the flush")
    }
}
