import AgentsKitCore
import Testing

@Suite struct EventsWordsTests {
    @Test func noneWaitingHasNoLine() {
        #expect(EventsWords.waitingLine(0) == nil)
    }

    @Test func countsSessions() {
        #expect(EventsWords.waitingLine(1) == "1 session waiting")
        #expect(EventsWords.waitingLine(4) == "4 sessions waiting")
    }
}
