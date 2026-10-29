import Foundation
import Testing
@testable import AgentsKitCore

/// What an agent told the person with `notify` (#2805): on the record as a line of its
/// own, drawn at every level, with what became of it; posted as a need that is no
/// Needs you row.
struct SentNoticeTests {
    @Test func aNoticeIsAnOutcomeOfItsOwn() throws {
        let notice = SentNotice(title: "The deploy finished", body: "All green.", outcome: .sent)
        let entry = TranscriptEntry(kind: .notified(notice))
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.kind == .notified(notice))

        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .toolCall(ToolCall(toolCallID: "1", title: "notify", name: AppTool.notify))),
            entry,
        ])
        #expect(items.count == 2)
        #expect(items.last == .entry(entry))
        #expect(items.last?.isOutcome == true)
    }

    @Test func itSaysWhatBecameOfIt() {
        let at = Date(timeIntervalSinceReferenceDate: 0)
        #expect(SentNotice(title: "t", outcome: .sent).outcomeText() == "Sent")
        #expect(SentNotice(title: "t", outcome: .shownHere).outcomeText() == "Shown here")
        #expect(SentNotice(title: "t", outcome: .muted).outcomeText() == "Muted: not sent")
        #expect(SentNotice(title: "t", outcome: .coolingDown, nextAt: at).outcomeText(timeStyle: { _ in "14:20" })
            == "Not sent: the next notice can go at 14:20")
    }

    @Test func aNoticeNeedReadsAsTheHostWritesIt() throws {
        let json = #"{"notice":"e0000000-0000-4000-8000-000000000006"}"#
        let id = try JSONDecoder().decode(NeedID.self, from: Data(json.utf8))
        #expect(id == .notice("e0000000-0000-4000-8000-000000000006"))
        #expect(id.token == "notice:e0000000-0000-4000-8000-000000000006")
        #expect(id.isNotice)
        #expect(try JSONDecoder().decode(Need.Kind.self, from: Data(#""notice""#.utf8)) == .notice)
    }

    @Test func aNoticeIsNoWidgetRow() {
        let snapshot = AttentionSnapshot(writtenAt: Date(timeIntervalSinceReferenceDate: 0), total: 0, sessions: [])
        let push = AttentionPush(need: .notice("n"), headline: Headline(h1: "f", h2: "s", h3: "The deploy finished"),
                                 withdrawn: false)
        #expect(snapshot.applying(push) == nil)
    }
}
