@testable import AgentsKitCore
import Testing

/// The icon's mood (#1317): a waiting question wins, then a working agent, then sleep.
@Suite("Icon mood")
struct IconMoodTests {
    @Test func nothingRunningIsAsleep() {
        #expect(IconMood(counts: []) == .asleep)
        #expect(IconMood(counts: [[.finished: 3, .waiting: 1, .stopped: 2]]) == .asleep)
    }

    @Test func aWorkingAgentIsHappy() {
        #expect(IconMood(counts: [[.finished: 1], [.running: 1]]) == .happy)
    }

    @Test func aWaitingQuestionWinsOverWork() {
        #expect(IconMood(counts: [[.running: 4], [.needsAttention: 1]]) == .quizzical)
        #expect(IconMood(counts: [[.blocked: 1]]) == .quizzical)
    }
}
