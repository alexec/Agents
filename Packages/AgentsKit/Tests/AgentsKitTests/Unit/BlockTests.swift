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

    /// #152: waking on any, the first wait to close clears it; all is as before.
    @Test func wakingOnAnyResumesWhenTheFirstWaitHasClosed() {
        let some = [Self.wait(ended: true), Self.wait(ended: false), Self.wait(ended: false)]
        #expect(Block(waits: some, wakeOn: .any).shouldResume(now: Self.now))
        #expect(!Block(waits: some, wakeOn: .all).shouldResume(now: Self.now))
        #expect(!Block(waits: some).shouldResume(now: Self.now))
        #expect(!Block(waits: [Self.wait(ended: false)], wakeOn: .any).shouldResume(now: Self.now))
        #expect(!Block(wakeOn: .any).shouldResume(now: Self.now), "any of nobody is still nobody")
    }

    /// A block written before #152 has no wake_on, and reads as all.
    @Test func aBlockWithoutWakeOnDecodesAsAll() throws {
        let old = #"{"waits":[]}"#.data(using: .utf8)!
        let block = try JSONDecoder().decode(Block.self, from: old)
        #expect(block.wakeOn == nil)
        #expect(Block(wakeOn: .any) != Block())
    }

    /// The row and the card say which, once there is more than one to choose from.
    @Test func theWakeLineSaysAnyOrAll() {
        let two = [Self.wait(ended: false), Self.wait(ended: false)]
        #expect(Block(waits: two, wakeOn: .any).wakeLine() == "Carries on when any of these finishes")
        #expect(Block(waits: two).wakeLine() == "Carries on when all of these have finished")
        #expect(Block(waits: [Self.wait(ended: false)], wakeOn: .any).wakeLine() == nil)
    }

    /// Waking on any, the prompt lists what finished and what is still running, and
    /// says how to wait on the rest.
    @Test func theAnyPromptListsFinishedAndStillRunning() {
        let done = Wait(agentID: UUID(), nameAtReport: "Lane A",
                        ending: WaitEnding(at: Self.now, how: .finished(outcome: .done, message: "Merged.")))
        let b = Wait(agentID: UUID(), nameAtReport: "Lane B")
        let c = Wait(agentID: UUID(), nameAtReport: "Lane C")
        let text = Block(waits: [b, done, c], wakeOn: .any)
            .resumePrompt(message: "the lanes", name: \.nameAtReport, why: .waits)
        #expect(text.hasPrefix("The block you reported has cleared: you asked to carry on when any of"))
        #expect(text.contains("Finished:\n- \u{201C}Lane A\u{201D} (id \(done.agentID.uuidString)): finished: complete — Merged."))
        #expect(text.contains("Still running:\n- \u{201C}Lane B\u{201D} (id \(b.agentID.uuidString)): still working\n- \u{201C}Lane C\u{201D}"))
        #expect(text.contains("To wait on the rest, end your turn blocked again"))
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
