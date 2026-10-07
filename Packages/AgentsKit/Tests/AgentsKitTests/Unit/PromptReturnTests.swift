import Testing

@testable import AgentsKitCore

/// The prompt's keys (#377): Return sends, Shift-Return sends, Option-Return breaks the line.
struct PromptReturnTests {
    @Test func returnSends() {
        #expect(PromptReturn(option: false, shift: false) == .send)
    }

    @Test func shiftReturnSends() {
        #expect(PromptReturn(option: false, shift: true) == .send)
    }

    @Test func optionReturnBreaksTheLine() {
        #expect(PromptReturn(option: true, shift: false) == .lineBreak)
        #expect(PromptReturn(option: true, shift: true) == .lineBreak)
    }
}
