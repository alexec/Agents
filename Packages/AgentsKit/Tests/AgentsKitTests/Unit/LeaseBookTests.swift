import Foundation
import Testing
@testable import AgentsKitCore

/// The rules of taking turns (036), as a property of the book alone.
@Suite("The lease book")
struct LeaseBookTests {
    private let screen = ResourceName.screen
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let a = UUID(), b = UUID(), c = UUID()

    private func minutes(_ n: Double) -> TimeInterval { n * 60 }

    @discardableResult
    private func ask(_ book: inout LeaseBook, _ agent: UUID, _ name: ResourceName? = nil,
                     minutes: Int? = nil, wait: Bool = true, waitID: UUID? = nil,
                     at: Date? = nil) -> [LeaseEvent] {
        book.request(name ?? screen, kind: .screen, displayName: "Screen, mouse and keyboard",
                     by: agent, minutes: minutes, wait: wait, waitID: waitID, now: at ?? t0)
    }

    private func holder(_ book: LeaseBook, _ name: ResourceName? = nil) -> UUID? {
        book.entry(name ?? screen)?.lease?.holder
    }

    private func line(_ book: LeaseBook, _ name: ResourceName? = nil) -> [UUID] {
        book.entry(name ?? screen)?.line.map(\.agentID) ?? []
    }

    // MARK: Names

    @Test func namesAreComparedWithoutCaseOrSurroundingSpaces() {
        #expect(ResourceName("  Screen ") == ResourceName("screen"))
        #expect(ResourceName("Port 8080")?.key == "port 8080")
        #expect(ResourceName("   ") == nil)
    }

    @Test func twoSpellingsWaitInOneLine() {
        var book = LeaseBook()
        ask(&book, a, ResourceName("Port 8080")!)
        let events = ask(&book, b, ResourceName(" port 8080 ")!)
        guard case .queued(1, a, _)? = events.first else {
            Issue.record("expected b queued behind a, got \(events)"); return
        }
    }

    // MARK: One holder

    @Test func twoAtTheSameMomentGiveOneHolderAndOneWaiter() {
        var book = LeaseBook()
        let first = ask(&book, a)
        let second = ask(&book, b)
        guard case .granted(let lease, nil, false)? = first.first else {
            Issue.record("expected a grant, got \(first)"); return
        }
        #expect(lease.holder == a)
        #expect(lease.expiresAt == t0.addingTimeInterval(minutes(30)))
        guard case .queued(1, a, _)? = second.first else {
            Issue.record("expected a place in line, got \(second)"); return
        }
        #expect(holder(book) == a)
        #expect(line(book) == [b])
    }

    @Test func manyAsking_neverTwoHolders() {
        var book = LeaseBook()
        let agents = (0..<20).map { _ in UUID() }
        let grants = agents.flatMap { ask(&book, $0) }.filter {
            if case .granted = $0 { return true } else { return false }
        }
        #expect(grants.count == 1)
        #expect(line(book).count == 19)
    }

    // MARK: Extending

    @Test func theHolderAskingAgainExtendsAndNeverQueues() {
        var book = LeaseBook()
        ask(&book, a, minutes: 10)
        let later = t0.addingTimeInterval(minutes(5))
        let events = ask(&book, a, minutes: 30, at: later)
        guard case .extended(let lease, false)? = events.first else {
            Issue.record("expected an extension, got \(events)"); return
        }
        #expect(lease.expiresAt == later.addingTimeInterval(minutes(30)))
        #expect(lease.grantedAt == t0)
        #expect(line(book).isEmpty)
    }

    @Test func anExtensionNeverShortensALease() {
        var book = LeaseBook()
        ask(&book, a, minutes: 60)
        let events = ask(&book, a, minutes: 5)
        guard case .extended(let lease, _)? = events.first else {
            Issue.record("expected an extension, got \(events)"); return
        }
        #expect(lease.expiresAt == t0.addingTimeInterval(minutes(60)))
    }

    @Test func tooLongIsCutToTheLongestAndSaysSo() {
        var book = LeaseBook()
        let events = ask(&book, a, minutes: 600)
        guard case .granted(let lease, _, true)? = events.first else {
            Issue.record("expected a capped grant, got \(events)"); return
        }
        #expect(lease.expiresAt == t0.addingTimeInterval(minutes(240)))
    }

    // MARK: Waiting

    @Test func notWaitingIsRefusedAndJoinsNoLine() {
        var book = LeaseBook()
        ask(&book, a)
        let events = ask(&book, b, wait: false)
        guard case .refused(a, _)? = events.first else {
            Issue.record("expected a refusal, got \(events)"); return
        }
        #expect(line(book).isEmpty)
    }

    @Test func askingAgainWhileInLineKeepsThePlaceAndTakesTheNewCall() {
        var book = LeaseBook()
        ask(&book, a)
        ask(&book, b, waitID: UUID())
        ask(&book, c)
        let fresh = UUID()
        let events = ask(&book, b, waitID: fresh)
        guard case .stillWaiting(1, a, _)? = events.first else {
            Issue.record("expected b still first, got \(events)"); return
        }
        #expect(line(book) == [b, c])
        #expect(book.entry(screen)?.line.first?.waitID == fresh)
    }

    @Test func theLineIsServedInAskingOrder() {
        var book = LeaseBook()
        ask(&book, a)
        ask(&book, b)
        ask(&book, c)
        _ = book.release(screen, by: a, now: t0)
        #expect(holder(book) == b)
        _ = book.release(screen, by: b, now: t0)
        #expect(holder(book) == c)
    }

    @Test func handingOnSaysWhetherTheWaitersCallIsOpen() {
        var book = LeaseBook()
        ask(&book, a)
        let call = UUID()
        ask(&book, b, minutes: 10, waitID: call)
        let later = t0.addingTimeInterval(minutes(3))
        let events = book.release(screen, by: a, now: later)
        #expect(events.count == 2)
        guard case .granted(let lease, let waiter?, _) = events[1] else {
            Issue.record("expected a hand-on, got \(events)"); return
        }
        #expect(waiter.waitID == call)
        #expect(lease.holder == b)
        #expect(lease.grantedAt == later)
        #expect(lease.expiresAt == later.addingTimeInterval(minutes(10)))
    }

    @Test func aTimedOutCallKeepsItsPlace() {
        var book = LeaseBook()
        ask(&book, a)
        let call = UUID()
        ask(&book, b, waitID: call)
        let events = book.waitTimedOut(call)
        guard case .stillWaiting(1, a, _)? = events.first else {
            Issue.record("expected still waiting, got \(events)"); return
        }
        #expect(line(book) == [b])
        #expect(book.entry(screen)?.line.first?.isCallOpen == false)
    }

    @Test func closingAllWaitsLeavesEveryoneInLine() {
        var book = LeaseBook()
        ask(&book, a)
        ask(&book, b, waitID: UUID())
        ask(&book, c, waitID: UUID())
        book.closeAllWaits()
        #expect(line(book) == [b, c])
        #expect(book.entry(screen)?.line.allSatisfy { !$0.isCallOpen } == true)
    }

    // MARK: Letting go

    @Test func aWaiterReleasingLeavesTheLine() {
        var book = LeaseBook()
        ask(&book, a)
        ask(&book, b)
        let events = book.release(screen, by: b, now: t0)
        guard case .leftLine(_, _, b)? = events.first else {
            Issue.record("expected b to leave, got \(events)"); return
        }
        #expect(holder(book) == a)
        #expect(line(book).isEmpty)
    }

    @Test func releasingWhatYouNeitherHoldNorWaitForChangesNothing() {
        var book = LeaseBook()
        ask(&book, a)
        #expect(book.release(screen, by: b, now: t0) == [.nothingHeld])
        #expect(holder(book) == a)
    }

    @Test func aFreedResourceWithNobodyWaitingIsNotKept() {
        var book = LeaseBook()
        ask(&book, a)
        _ = book.release(screen, by: a, now: t0)
        #expect(book.isEmpty)
    }

    @Test func theEndByThePersonHandsOnAndTellsTheHolderLater() {
        var book = LeaseBook()
        ask(&book, a)
        ask(&book, b)
        let events = book.end(screen, now: t0)
        guard case .released(let ended, .endedByPerson)? = events.first else {
            Issue.record("expected a's lease ended by the person, got \(events)"); return
        }
        #expect(ended.holder == a)
        #expect(holder(book) == b)
        let told = book.takeNotices(for: a)
        #expect(told.map(\.kind) == [.endedByPerson])
        #expect(book.takeNotices(for: a).isEmpty)
    }

    @Test func endingAFreeResourceDoesNothing() {
        var book = LeaseBook()
        #expect(book.end(screen, now: t0).isEmpty)
    }

    @Test func removingFromTheLineTakesOnlyThatAgent() {
        var book = LeaseBook()
        ask(&book, a)
        ask(&book, b)
        ask(&book, c)
        _ = book.removeFromLine(screen, agent: b)
        #expect(line(book) == [c])
        #expect(holder(book) == a)
    }

    @Test func droppingAnAgentLetsGoOfEverythingAndLeavesEveryLine() {
        var book = LeaseBook()
        let sim = ResourceName("simulator:1")!
        ask(&book, a)
        ask(&book, b, sim)
        ask(&book, a, sim)
        ask(&book, c)
        let events = book.drop(a, because: .holderStopped, now: t0)
        #expect(holder(book) == c)
        #expect(line(book, sim).isEmpty)
        #expect(holder(book, sim) == b)
        #expect(events.contains { if case .released(_, .holderStopped) = $0 { true } else { false } })
    }

    @Test func aDroppedHolderIsNeverHandedItsOwnLeaseBack() {
        var book = LeaseBook()
        let sim = ResourceName("simulator:1")!
        ask(&book, a, sim)
        ask(&book, b)
        ask(&book, a)
        _ = book.drop(b, because: .holderArchived, now: t0)
        #expect(holder(book) == a)
    }

    @Test func givingUpForAnAgentThatCouldNotStartHandsOn() {
        var book = LeaseBook()
        ask(&book, a)
        ask(&book, b)
        _ = book.release(screen, by: a, now: t0)
        ask(&book, c)
        let events = book.giveUp(screen, heldBy: b, now: t0)
        #expect(events.contains { if case .released(_, .couldNotStart) = $0 { true } else { false } })
        #expect(holder(book) == c)
    }

    // MARK: Time

    @Test func expiryReleasesHandsOnAndTellsTheHolder() {
        var book = LeaseBook()
        ask(&book, a, minutes: 10)
        ask(&book, b)
        let after = t0.addingTimeInterval(minutes(10))
        let events = book.lapse(now: after)
        #expect(events.contains { if case .released(_, .expired) = $0 { true } else { false } })
        #expect(holder(book) == b)
        #expect(book.takeNotices(for: a).map(\.kind) == [.expired])
    }

    @Test func theWarningComesOnceAndAnExtensionResetsIt() {
        var book = LeaseBook()
        ask(&book, a, minutes: 10)
        let inWindow = t0.addingTimeInterval(minutes(6))
        #expect(book.lapse(now: inWindow).count == 1)
        #expect(book.lapse(now: inWindow.addingTimeInterval(30)).isEmpty)
        #expect(book.takeNotices(for: a).count == 1)
        ask(&book, a, minutes: 10, at: inWindow)
        #expect(book.entry(screen)?.lease?.warned == false)
        #expect(book.lapse(now: inWindow.addingTimeInterval(minutes(6))).count == 1)
    }

    @Test func notYetDueDoesNothing() {
        var book = LeaseBook()
        ask(&book, a, minutes: 30)
        #expect(book.lapse(now: t0.addingTimeInterval(minutes(1))).isEmpty)
    }

    @Test func theNextDeadlineIsTheEarliestWarningOrExpiry() {
        var book = LeaseBook()
        #expect(book.nextDeadline == nil)
        ask(&book, a, minutes: 30)
        ask(&book, b, ResourceName("port 1")!, minutes: 8)
        #expect(book.nextDeadline == t0.addingTimeInterval(minutes(3)))
        _ = book.lapse(now: t0.addingTimeInterval(minutes(3)))
        #expect(book.nextDeadline == t0.addingTimeInterval(minutes(8)))
    }

    // MARK: Keeping

    @Test func aBookSurvivesBeingWrittenDown() throws {
        var book = LeaseBook()
        ask(&book, a)
        ask(&book, b, waitID: UUID())
        _ = book.end(screen, now: t0)
        ask(&book, c, ResourceName("Port 8080")!)
        let data = try JSONEncoder().encode(book)
        let back = try JSONDecoder().decode(LeaseBook.self, from: data)
        #expect(back == book)
        #expect(String(decoding: data, as: UTF8.self).contains("\"port 8080\""))
    }
}
