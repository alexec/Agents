import AgentsKitCore
import Testing

/// Up and Down in the Prompts list (#1870), as the page's `movedTo` does.
struct SessionPromptsMoveTests {
    @Test func theNewestIsChosenFirst() {
        #expect(SessionPrompts.moved(from: nil, count: 3, down: true) == 2)
        #expect(SessionPrompts.moved(from: nil, count: 3, down: false) == 2)
    }

    @Test func upAndDownStopAtTheEnds() {
        #expect(SessionPrompts.moved(from: 2, count: 3, down: false) == 1)
        #expect(SessionPrompts.moved(from: 0, count: 3, down: false) == 0)
        #expect(SessionPrompts.moved(from: 1, count: 3, down: true) == 2)
        #expect(SessionPrompts.moved(from: 2, count: 3, down: true) == 2)
    }

    @Test func noRowsMeansNoneChosen() {
        #expect(SessionPrompts.moved(from: nil, count: 0, down: true) == nil)
        #expect(SessionPrompts.moved(from: 4, count: 0, down: false) == nil)
    }
}
