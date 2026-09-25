import Foundation
import Testing
@testable import AgentsKitCore

/// When a block is resumed, and what the agent reads when it is (039).
@Suite("A block, and when it clears")
struct BlockTests {
    private static let now = Date(timeIntervalSince1970: 10_000)

    private static func wait(ended: Bool) -> Wait {
        Wait(agentID: UUID(), nameAtReport: "helper",
             ending: ended ? WaitEnding(at: now, how: .finished(outcome: .done, message: "ok")) : nil)
    }

    /// Named nobody and gave no time: only the person can move it.
    @Test func aBlockOnNothingIsNeverResumedByTheApp() {
        #expect(!Block().shouldResume(now: Self.now))
        #expect(!Block().shouldResume(now: .distantFuture))
    }

    @Test func itResumesOnlyWhenEveryWaitHasClosed() {
        #expect(Block(waits: [Self.wait(ended: true), Self.wait(ended: true)]).shouldResume(now: Self.now))
        #expect(!Block(waits: [Self.wait(ended: true), Self.wait(ended: false)]).shouldResume(now: Self.now))
    }

    /// Whichever comes first: the time, even with waits still open.
    @Test func theTimeResumesItWithWaitsStillOpen() {
        let block = Block(waits: [Self.wait(ended: false)], checkAgainAt: Self.now)
        #expect(block.shouldResume(now: Self.now))
        #expect(!block.shouldResume(now: Self.now.addingTimeInterval(-1)))
    }

    /// Once cleared, never again — the whole of SC-002 on the model's side.
    @Test func aClearedBlockNeverResumes() {
        let block = Block(waits: [Self.wait(ended: true)], checkAgainAt: Self.now,
                          clearedAt: Self.now, clearedBy: .waits)
        #expect(!block.shouldResume(now: .distantFuture))
    }

    @Test func theRangeIsAMinuteToADay() {
        #expect(Block.checkAgainMinutes == 1...1440)
    }

    /// FR-013: each agent it waited on, how it ended, and what it said; and what the
    /// agent itself said it was waiting on.
    @Test func theResumePromptNamesEachAgentAndWhatItSaid() {
        let a = Wait(agentID: UUID(), nameAtReport: "Fix login",
                     ending: WaitEnding(at: Self.now, how: .finished(outcome: .done, message: "Fixed.")))
        let b = Wait(agentID: UUID(), nameAtReport: "Docs",
                     ending: WaitEnding(at: Self.now, how: .finished(outcome: .stuck, message: "No folder.")))
        let text = Block(waits: [a, b]).resumePrompt(message: "the two helpers", name: \.nameAtReport,
                                                     why: .waits)
        #expect(text.contains("every agent you were waiting on has finished"))
        #expect(text.contains("\u{201C}Fix login\u{201D} (id \(a.agentID.uuidString)): finished: complete — Fixed."))
        #expect(text.contains("\u{201C}Docs\u{201D} (id \(b.agentID.uuidString)): finished: stuck — No folder."))
        #expect(text.contains("You said you were waiting on: the two helpers"))
    }

    /// FR-014: the time came, and says so, with what is still open.
    @Test func theTimePromptSaysTheTimeCame() {
        let open = Wait(agentID: UUID(), nameAtReport: "CI watcher")
        let text = Block(waits: [open]).resumePrompt(message: "CI on fix-login", name: \.nameAtReport,
                                                     why: .time)
        #expect(text.hasPrefix("The time you asked to check again has come."))
        #expect(text.contains("still working"))
        #expect(text.contains("CI on fix-login"))
    }

    @Test func stoppedAndArchivedWaitsAreSaidPlainly() {
        #expect(WaitEnding(at: Self.now, how: .stopped(.cancelled)).summary == EndedReason.cancelled.summary?.lowercased())
        #expect(WaitEnding(at: Self.now, how: .archived).summary == "archived")
        #expect(WaitEnding(at: Self.now, how: .finished(outcome: nil, message: nil)).summary
            == "finished without saying how it went")
        #expect(Block.waitLine(name: "Docs", ending: nil) == "Docs — still working")
    }
}
