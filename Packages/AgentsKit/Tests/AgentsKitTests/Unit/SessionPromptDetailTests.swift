import Foundation
import Testing
@testable import AgentsKitCore

/// The grey line under a row of the Prompts list (#1658), as the page writes it
/// (`promptLine` in `Web/src/model/sessionPrompts.ts`).
@Suite("Session prompt detail")
struct SessionPromptDetailTests {
    private let zone = TimeZone(identifier: "Europe/London")!
    /// 20 Oct 2026, 15:30 in London (BST).
    private let now = Date(timeIntervalSince1970: 1_792_506_600)

    private func prompt(at: Date, cost: Cost? = nil, seconds: Int? = nil) -> SessionPrompt {
        SessionPrompt(id: UUID(), number: 1, text: "Make it faster", at: at, cost: cost,
                      seconds: seconds, ending: nil)
    }

    @Test func costLengthAndTime() {
        let row = prompt(at: now.addingTimeInterval(-85 * 60), cost: Cost(amount: Decimal(string: "0.14")!, currency: "USD"), seconds: 200)
        #expect(row.detail(now: now, timeZone: zone) == "\(Decimal(string: "0.14")!.formatted(.currency(code: "USD").precision(.fractionLength(2)))) · 3m · 14:05")
    }

    @Test func leavesOutWhatIsNotKnown() {
        // A turn still going has no length; a runtime that priced nothing has no cost.
        let at = now.addingTimeInterval(-85 * 60)
        #expect(prompt(at: at).detail(now: now, timeZone: zone) == "14:05")
        #expect(prompt(at: at, seconds: 45).detail(now: now, timeZone: zone) == "45s · 14:05")
    }

    @Test func theDayWhenNotToday() {
        let day: TimeInterval = 86_400
        // Yesterday and earlier this year: the day; another year: the year too.
        #expect(ActivityWords.sent(now.addingTimeInterval(-day), now: now, timeZone: zone) == "19 Oct 15:30")
        #expect(ActivityWords.sent(now.addingTimeInterval(-17 * day), now: now, timeZone: zone) == "3 Oct 15:30")
        #expect(ActivityWords.sent(now.addingTimeInterval(-365 * day), now: now, timeZone: zone) == "20 Oct 2025 15:30")
        // Just after midnight is still today, in the reader's own zone.
        #expect(ActivityWords.sent(now.addingTimeInterval(-15.5 * 3600 + 60), now: now, timeZone: zone) == "00:01")
    }
}
