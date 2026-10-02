import Foundation
import Testing
@testable import AgentsKitCore

/// A device forgets its pairing when a window forgot it, or when the control plane has
/// not known it for minutes on end; never over one "unknown" (#81).
@Suite("Believing a refusal")
struct RefusalPatienceTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func forgottenIsFinalAtOnce() {
        var patience = RefusalPatience()
        let forgets = patience.forgets(after: .forgotten, at: start)
        #expect(forgets)
    }

    @Test func oneUnknownIsDialledAgain() {
        var patience = RefusalPatience(patience: 120)
        let verdicts = [0.0, 60, 121].map { patience.forgets(after: .unknown, at: start.addingTimeInterval($0)) }
        #expect(verdicts == [false, false, true])
    }

    @Test func aConnectionBetweenStartsTheWaitAgain() {
        var patience = RefusalPatience(patience: 120)
        let first = patience.forgets(after: .unknown, at: start)
        patience.connected()
        let later = [200.0, 300].map { patience.forgets(after: .unknown, at: start.addingTimeInterval($0)) }
        #expect(!first)
        #expect(later == [false, false])
    }

    @Test func unavailableAndTheRestAreOnlyFailedDials() {
        var patience = RefusalPatience(patience: 0)
        let reasons: [ControlAuth.Reason] = [.unavailable, .expired, .spent, .badProof, .badMessage, .wrongControlPlane]
        let verdicts = reasons.map { patience.forgets(after: $0, at: start) }
        #expect(!verdicts.contains(true))
    }

    @Test func anOlderBuildCannotReadUnavailableAndSoForgetsNothing() {
        // The line a newer control plane sends; a build without the case reads no message
        // from it, which it takes as a failed dial.
        let line = ControlAuth.Message.refused(.unavailable).line
        #expect(line.contains(#""unavailable""#))
        #expect(ControlAuth.Message(line: line.replacingOccurrences(of: "unavailable", with: "not-a-reason")) == nil)
    }
}
