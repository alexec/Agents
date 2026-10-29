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

    /// Where it went (#2860) is said on its line, and is no line of its own.
    @Test func whereItWentIsSaidOnItsLine() throws {
        let line = TranscriptEntry(kind: .notified(SentNotice(title: "The deploy finished", outcome: .sent)))
        let delivery = TranscriptEntry(kind: .noticeDelivered(NoticeDelivery(notice: line.id, to: .iPhone)))
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(delivery))
        #expect(decoded.kind == delivery.kind)

        let items = TranscriptEntry.display([line, delivery])
        #expect(items.count == 1)
        guard case .entry(let drawn) = items.first, case .notified(let notice) = drawn.kind else {
            Issue.record("not the notice's line")
            return
        }
        #expect(drawn.id == line.id)
        #expect(notice.outcomeText() == "Sent to iPhone")
        #expect(SentNotice(title: "t", outcome: .sent, to: .computer).outcomeText() == "Sent to the computer")
        // One whose line is on an earlier page is left out.
        #expect(TranscriptEntry.display([delivery]).isEmpty)
    }

    /// A tap on a notice's banner goes to its line (#2860): its token names the entry.
    @Test func aNoticeTokenNamesItsLine() {
        let id = UUID()
        #expect(NeedID.noticeEntry(fromToken: NeedID.notice(id.uuidString).token) == id)
        #expect(NeedID.noticeEntry(fromToken: "permission:\(id.uuidString)") == nil)
        #expect(NeedID.noticeEntry(fromToken: nil) == nil)
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
