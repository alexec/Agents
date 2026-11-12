@testable import AgentsKitCore
import Foundation
import Testing

/// The message tones and toast times of docs/reference/design-system.md, "Messages" (#4737).
@Suite("Message tones")
struct MessageToneTests {
    @Test func eachToneHasItsOwnSymbol() {
        let symbols = MessageTone.allCases.map(\.symbol)
        #expect(Set(symbols).count == MessageTone.allCases.count)
        #expect(MessageTone.failure.symbol == "xmark.octagon.fill")
    }

    @Test func aSuccessGoesAfterFourSecondsAnUndoAfterEightAndAFailureStays() {
        #expect(ToastTime.seconds(tone: .success, undo: false) == 4)
        #expect(ToastTime.seconds(tone: .success, undo: true) == 8)
        #expect(ToastTime.seconds(tone: .neutral, undo: false) == 4)
        #expect(ToastTime.seconds(tone: .failure, undo: false) == nil)
        #expect(ToastTime.seconds(tone: .failure, undo: true) == nil)
    }

    @Test func archiveUndoIsOfferedForAnUndoToastsTime() {
        #expect(ArchiveUndo.seconds == ToastTime.undo)
    }
}
