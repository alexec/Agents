import Foundation
import Testing
@testable import AgentsKitCore

/// Counted holders and declared resources (#116), as properties of the book alone.
@Suite("Counted leases")
struct CountedLeaseTests {
    private let build = ResourceName("build")!
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @discardableResult
    private func ask(_ book: inout LeaseBook, _ agent: UUID, holders: Int = 2, minutes: Int? = nil,
                     wait: Bool = true, at: Date? = nil) -> [LeaseEvent] {
        book.request(build, kind: .named, displayName: "build", rules: LeaseRules(holders: holders),
                     by: agent, minutes: minutes, wait: wait, waitID: nil, now: at ?? t0)
    }

    private func holders(_ book: LeaseBook) -> [UUID] { book.entry(build)?.leases.map(\.holder) ?? [] }
    private func line(_ book: LeaseBook) -> [UUID] { book.entry(build)?.line.map(\.agentID) ?? [] }

    @Test func twoHoldTheThirdWaitsAndOneReleaseLetsItIn() {
        var book = LeaseBook()
        guard case .granted? = ask(&book, a).first, case .granted? = ask(&book, b).first else {
            Issue.record("the first two should both hold it"); return
        }
        guard case .queued(1, _, _)? = ask(&book, c).first else {
            Issue.record("the third should be first in line"); return
        }
        #expect(holders(book) == [a, b])
        #expect(line(book) == [c])

        let events = book.release(build, by: a, now: t0.addingTimeInterval(60))
        guard case .released(let gone, .released)? = events.first, gone.holder == a,
              case .granted(let given, let waiter?, false)? = events.dropFirst().first else {
            Issue.record("a's release should let c in, got \(events)"); return
        }
        #expect(given.holder == c)
        #expect(waiter.agentID == c)
        #expect(holders(book) == [b, c])
        #expect(line(book).isEmpty)
    }

    @Test func theLineIsServedInOrder() {
        var book = LeaseBook()
        ask(&book, a); ask(&book, b); ask(&book, c); ask(&book, d)
        #expect(line(book) == [c, d])
        _ = book.release(build, by: b, now: t0)
        #expect(holders(book) == [a, c])
        #expect(line(book) == [d])
    }

    @Test func manyAsking_neverMoreThanTheCount() {
        var book = LeaseBook()
        for _ in 0..<20 { ask(&book, UUID(), holders: 3) }
        #expect(holders(book).count == 3)
        #expect(line(book).count == 17)
    }

    @Test func aQueuedAnswerNamesTheLeaseThatEndsFirst() {
        var book = LeaseBook()
        ask(&book, a, minutes: 50)
        ask(&book, b, minutes: 10)
        guard case .queued(1, let holder, let until)? = ask(&book, c).first else {
            Issue.record("expected c in line"); return
        }
        #expect(holder == b)
        #expect(until == t0.addingTimeInterval(600))
    }

    @Test func aHolderAskingAgainExtendsItsOwnPlace() {
        var book = LeaseBook()
        ask(&book, a, minutes: 10); ask(&book, b, minutes: 10)
        guard case .extended(let lease, _)? = ask(&book, a, minutes: 40).first else {
            Issue.record("expected an extension"); return
        }
        #expect(lease.holder == a)
        #expect(holders(book) == [a, b])
    }

    @Test func expiryFreesOnePlaceOnly() {
        var book = LeaseBook()
        ask(&book, a, minutes: 5); ask(&book, b, minutes: 60); ask(&book, c)
        _ = book.lapse(now: t0.addingTimeInterval(6 * 60))
        #expect(holders(book) == [b, c])
    }

    @Test func raisingTheCountLetsTheLineIn_andLoweringItTakesNothing() {
        var book = LeaseBook()
        ask(&book, a, holders: 1); ask(&book, b, holders: 1); ask(&book, c, holders: 1)
        #expect(holders(book) == [a])
        let raised = book.setRules(LeaseRules(holders: 3), for: build, now: t0)
        #expect(raised.count == 2)
        #expect(holders(book) == [a, b, c])

        _ = book.setRules(LeaseRules(holders: 1), for: build, now: t0)
        #expect(holders(book) == [a, b, c], "nobody loses a lease they hold")
        ask(&book, d, holders: 1)
        #expect(line(book) == [d])
        _ = book.release(build, by: a, now: t0)
        #expect(line(book) == [d], "still two holding, over a count of one")
    }

    @Test func thePersonEndsOneHolderOrAll() {
        var book = LeaseBook()
        ask(&book, a); ask(&book, b); ask(&book, c)
        _ = book.end(build, holder: b, now: t0)
        #expect(holders(book) == [a, c])
        #expect(book.takeNotices(for: b).first?.kind == .endedByPerson)
        _ = book.end(build, now: t0)
        #expect(holders(book).isEmpty)
        #expect(book.end(build, holder: d, now: t0).isEmpty)
    }

    @Test func aDeclaredLengthIsUsedAndCapped() {
        var book = LeaseBook()
        let rules = LeaseRules(holders: 1, defaultMinutes: 15, maximumMinutes: 60)
        guard case .granted(let first, _, false)? = book.request(
            build, kind: .named, displayName: "build", rules: rules, by: a, minutes: nil,
            wait: true, waitID: nil, now: t0).first else { Issue.record("expected a grant"); return }
        #expect(first.expiresAt == t0.addingTimeInterval(15 * 60))
        guard case .extended(let longer, true)? = book.request(
            build, kind: .named, displayName: "build", rules: rules, by: a, minutes: 200,
            wait: true, waitID: nil, now: t0).first else { Issue.record("expected a capped extension"); return }
        #expect(longer.expiresAt == t0.addingTimeInterval(60 * 60))
    }

    @Test func aBookFromBefore116ReadsWithOneHolder() throws {
        let lease = Lease(resource: .screen, displayName: "Screen", holder: a, grantedAt: t0,
                          expiresAt: t0.addingTimeInterval(600))
        let old = """
            {"entries":{"screen":{"kind":"screen","displayName":"Screen","lease":\
            \(String(decoding: try JSONEncoder().encode(lease), as: UTF8.self)),"line":[]}},"notices":{}}
            """
        let book = try JSONDecoder().decode(LeaseBook.self, from: Data(old.utf8))
        #expect(book.entry(.screen)?.leases == [lease])
        #expect(book.entry(.screen)?.rules == .standard)
    }

    // MARK: Declarations

    @Test func aDeclarationSaysWhatIsWrongWithIt() {
        let ok = DeclaredResource(name: build, description: "Lease before any build.")
        #expect(ok.problem == nil)
        #expect(DeclaredResource(name: .screen, description: "x").problem != nil)
        #expect(DeclaredResource(name: ResourceName("simulator:abc")!, description: "x").problem != nil)
        #expect(DeclaredResource(name: build, description: "  ").problem != nil)
        #expect(DeclaredResource(name: build, description: "x", holders: 0).problem != nil)
        #expect(DeclaredResource(name: build, description: "x", maximumMinutes: 500).problem != nil)
        #expect(DeclaredResource(name: build, description: "x", defaultMinutes: 90, maximumMinutes: 60).problem != nil)
    }

    @Test func aLineIsToldEveryPlace() {
        let at = Calendar.current.date(bySettingHour: 14, minute: 5, second: 0, of: t0)!
        #expect(LeaseWords.heldBy("build", holders: [("“A”", at)], places: 1)
                == "build is held by “A” until 14:05")
        #expect(LeaseWords.heldBy("build", holders: [("“A”", at), ("“B”", at.addingTimeInterval(900))], places: 2)
                == "All 2 places on build are held: by “A” until 14:05 and “B” until 14:20")
    }

    @Test func theBriefingListsWhatWasDeclared() {
        #expect(LeaseWords.declaredBriefing([]) == nil)
        let text = LeaseWords.declaredBriefing([DeclaredResource(name: build, description: "Before builds.",
                                                                 holders: 2)])
        #expect(text?.contains("- build (2 at once): Before builds.") == true)
        #expect(text?.contains("whenever its description applies") == true)
    }
}
