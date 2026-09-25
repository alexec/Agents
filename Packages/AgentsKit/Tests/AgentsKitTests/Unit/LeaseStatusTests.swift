import Foundation
import Testing
@testable import AgentsKitCore

/// The chat's lease row and the card's mark (036 FR-010), from a snapshot.
@Suite("What an agent holds and waits for, in words")
struct LeaseStatusTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let walker = UUID(), fixer = UUID(), idle = UUID()
    private var titles: [UUID: String] { [walker: "Walk the phone", fixer: "Fix login"] }

    private func minutes(_ n: Double) -> Date { at.addingTimeInterval(n * 60) }

    private var snapshot: DaemonAPI.LeaseSnapshot {
        let screen = ResourceName.screen
        let sim = ResourceName("simulator:aaaa")!
        return DaemonAPI.LeaseSnapshot(resources: [
            .init(name: screen, kind: .screen, displayName: "Screen, mouse and keyboard",
                  lease: Lease(resource: screen, displayName: "Screen, mouse and keyboard", holder: walker,
                               grantedAt: minutes(-12), expiresAt: minutes(18)),
                  line: [.init(agentID: fixer, askedAt: minutes(-4), isCallOpen: true),
                         .init(agentID: idle, askedAt: minutes(-2), isCallOpen: false)]),
            .init(name: sim, kind: .simulator, displayName: "iPhone 17 Pro \u{00B7} iOS 26.0",
                  lease: Lease(resource: sim, displayName: "iPhone 17 Pro \u{00B7} iOS 26.0", holder: walker,
                               grantedAt: minutes(-1), expiresAt: minutes(3.5)),
                  endingSoon: true),
        ], at: at)
    }

    @Test func nothingHeldOrAwaitedIsNothingDrawn() {
        #expect(LeaseStatus.of(UUID(), in: snapshot, titles: titles) == nil)
    }

    @Test func holdingIsCountedFromTheDaemonsClock() throws {
        let status = try #require(LeaseStatus.of(walker, in: snapshot, titles: titles))
        #expect(status.capsules == ["\u{25A3} Screen \u{00B7} 18 min", "\u{25A3} iPhone 17 Pro \u{00B7} 4 min left"])
        #expect(status.mark == "Holds Screen \u{00B7} 18 min")
        #expect(status.markSymbol == LeaseStatus.holdingSymbol)
        #expect(status.moreCount == 1)
    }

    @Test func waitingSaysWhoHoldsItAndThePlace() throws {
        let status = try #require(LeaseStatus.of(idle, in: snapshot, titles: titles))
        #expect(status.capsules == ["\u{25F7} Waiting for Screen \u{00B7} held by \u{201C}Walk the phone\u{201D} "
                                    + "until \(LeaseWords.clock(minutes(18))) \u{00B7} 2nd"])
        #expect(status.mark == "Waiting for Screen \u{00B7} 2nd in line")
        #expect(status.markSymbol == LeaseStatus.waitingSymbol)
        #expect(status.moreCount == 0)
        #expect(status.fullLine.hasPrefix("Waiting for Screen, mouse and keyboard, held by \u{201C}Walk the phone\u{201D}"))
    }

    @Test func shortNamesFitANarrowPlace() {
        #expect(LeaseStatus.shortName("Screen, mouse and keyboard", kind: .screen) == "Screen")
        #expect(LeaseStatus.shortName("iPhone 17 Pro \u{00B7} iOS 26.0", kind: .simulator) == "iPhone 17 Pro")
        #expect(LeaseStatus.shortName("Safari", kind: .browser) == "Safari")
        #expect(LeaseStatus.shortName("Port 8080", kind: .named) == "Port 8080")
    }

    @Test func ordinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 101].map(LeaseWords.ordinal)
                == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st"])
    }
}
