import Testing

@testable import AgentsKitCore

/// The prompt's keys (#377): Return sends; Shift-Return and Option-Return break the line (#1514).
struct PromptReturnTests {
    @Test func returnSends() {
        #expect(PromptReturn(option: false, shift: false) == .send)
    }

    @Test func shiftReturnBreaksTheLine() {
        #expect(PromptReturn(option: false, shift: true) == .lineBreak)
    }

    @Test func optionReturnBreaksTheLine() {
        #expect(PromptReturn(option: true, shift: false) == .lineBreak)
        #expect(PromptReturn(option: true, shift: true) == .lineBreak)
    }
}
