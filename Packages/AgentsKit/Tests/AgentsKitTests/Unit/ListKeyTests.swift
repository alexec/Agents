import Foundation
import Testing
@testable import AgentsKitCore

/// The session list's single keys (#4796): which keys, where j, k and e go, and the request l
/// puts in Later.
@MainActor
@Suite("The list's single keys")
struct ListKeyTests {
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()
    private var ids: [UUID] { [first, second, third] }

    @Test func keysAreTheLettersWithNoModifier() {
        #expect(ListKey(typed: "j", modified: false) == .next)
        #expect(ListKey(typed: "k", modified: false) == .previous)
        #expect(ListKey(typed: "e", modified: false) == .archive)
        #expect(ListKey(typed: "l", modified: false) == .later)
        #expect(ListKey(typed: "r", modified: false) == .rename)
        #expect(ListKey(typed: "e", modified: true) == nil)
        #expect(ListKey(typed: "E", modified: false) == nil)
        #expect(ListKey(typed: "x", modified: false) == nil)
        #expect(ListKey(typed: "je", modified: false) == nil)
        #expect(ListKey.characters == "jkelr")
        #expect(ListKey.archive.glyph == "E")
        #expect(ListKey.laterWord == "Later in 1 Hour")
    }

    @Test func jAndKStopAtTheEnds() {
        #expect(ListKey.step(from: first, in: ids, forward: true) == second)
        #expect(ListKey.step(from: third, in: ids, forward: true) == nil)
        #expect(ListKey.step(from: second, in: ids, forward: false) == first)
        #expect(ListKey.step(from: first, in: ids, forward: false) == nil)
        #expect(ListKey.step(from: nil, in: ids, forward: true) == first)
        #expect(ListKey.step(from: UUID(), in: ids, forward: false) == third)
        #expect(ListKey.step(from: nil, in: [], forward: true) == nil)
    }

    @Test func archiveOpensTheNextOrTheOneBefore() {
        #expect(ListKey.after(archiving: first, in: ids) == second)
        #expect(ListKey.after(archiving: third, in: ids) == second)
        #expect(ListKey.after(archiving: first, in: [first]) == nil)
        #expect(ListKey.after(archiving: UUID(), in: ids) == nil)
    }

    @Test func laterTakesTheOldestRequestNotInLater() {
        let model = AgentsModel()
        let folder = URL(filePath: "/tmp/work/api")
        let asker = UUID()
        func request(_ title: String, at: TimeInterval, deferred: Bool = false) -> NeedRequest {
            var made = NeedRequest(id: UUID(), kind: .decide, source: "question", title: title, folder: folder,
                                   askedBy: asker, askedAt: Date(timeIntervalSince1970: at))
            if deferred { made.deferred = .init(atMac: true, at: Date(timeIntervalSince1970: at)) }
            return made
        }
        let inLater = request("Which branch?", at: 5, deferred: true)
        let first = request("Which port?", at: 10)
        let second = request("Which name?", at: 20)
        model.replaceRequests([second, inLater, first])
        #expect(model.laterRequest(askedBy: asker)?.id == first.id)
        #expect(model.laterRequest(askedBy: UUID()) == nil)
    }
}
