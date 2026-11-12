import Foundation
import Testing
@testable import AgentsKitCore

/// The parts every Work page draws (#4391, `specs/4328-work-look/parts.md`), as
/// `Web/test/work.test.mjs` has them on the web page (#4392).
@Suite("Work look")
struct WorkLookTests {
    typealias Node = DaemonAPI.LineageNode
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func glyphByKindAndState() {
        #expect(WorkLook.glyph(kind: "issue", state: "open") == .issueOpen)
        #expect(WorkLook.glyph(kind: "issue", state: "closed") == .issueDone)
        #expect(WorkLook.glyph(kind: "issue", state: "closed", stateReason: "not_planned") == .issueNotPlanned)
        #expect(WorkLook.glyph(kind: "pr", state: "open") == .prOpen)
        #expect(WorkLook.glyph(kind: "pr", state: "open", draft: true) == .prDraft)
        #expect(WorkLook.glyph(kind: "pr", state: "merged") == .prMerged)
        #expect(WorkLook.glyph(kind: "pr", state: "closed") == .prClosed)
        #expect(WorkLook.glyph(kind: "release", state: "open") == nil)
        #expect(WorkLook.glyph(kind: "issue", state: "") == nil)
    }

    @Test func everyGlyphSaysItsStateInWords() {
        let labels = Set(WorkLook.Glyph.allCases.map(\.accessibilityLabel))
        #expect(labels.count == WorkLook.Glyph.allCases.count)
        #expect(WorkLook.Glyph.prMerged.accessibilityLabel == "Merged pull request")
        #expect(WorkLook.Glyph.prMerged.tone == .purple)
        #expect(WorkLook.Glyph.prClosed.tone == .red)
    }

    @Test func ages() {
        #expect(WorkLook.ageWords(5) == "now")
        #expect(WorkLook.ageWords(-5) == "now")
        #expect(WorkLook.ageWords(20 * 60) == "20 min")
        #expect(WorkLook.ageWords(2 * 3600 + 59) == "2 h")
        #expect(WorkLook.ageWords(3 * 86_400) == "3 d")
        #expect(WorkLook.ageWords(65 * 86_400) == "2 mo")
        #expect(WorkLook.ageWords(800 * 86_400) == "2 y")
    }

    func row(state: String = "open", author: String? = "alexec", lineage: DaemonAPI.ReportNode? = nil,
             title: String = "Work look", status: String? = nil, draft: Bool = false) -> WorkList.Row {
        WorkList.Row(node: Node(kind: "issue", ref: "github:alexec/Agents#4328"), title: title, state: state,
                     repo: "github:alexec/Agents", author: author, updated: now.addingTimeInterval(-2 * 3600),
                     draft: draft, lineage: lineage, status: status)
    }

    func lineage(sessions: Int, usd: Decimal) -> DaemonAPI.ReportNode {
        DaemonAPI.ReportNode(node: Node(kind: "issue", ref: "github:alexec/Agents#4328"),
                             cost: .init(total: .init(cost: usd == 0 ? [:] : ["USD": usd])), sessions: sessions, lastAt: now)
    }

    @Test func rowLineWideAndOnAPhone() {
        #expect(WorkLook.rowLine(row(), compact: false, now: now) == "#4328 · updated 2 h ago by alexec")
        #expect(WorkLook.rowLine(row(), compact: true, now: now) == "#4328 · 2 h · alexec")
        let spent = row(lineage: lineage(sessions: 2, usd: Decimal(string: "0.42")!))
        #expect(WorkLook.rowLine(spent, compact: false, now: now) == "#4328 · updated 2 h ago by alexec · 2 sessions · $0.42")
        #expect(WorkLook.rowLine(spent, compact: true, now: now) == "#4328 · 2 h · alexec · $0.42")
        #expect(WorkLook.rowLine(row(author: nil), compact: false, now: now) == "#4328 · updated 2 h ago")
        // "No agent yet" goes: a row with no lineage ends after its author.
        #expect(!WorkLook.rowLine(row(), compact: false, now: now).contains(WorkList.noAgentYet))
    }

    @Test func rowLineSaysTheOpenedAndClosedAges() {
        var open = row()
        open.created = now.addingTimeInterval(-3 * 86_400)
        #expect(WorkLook.rowLine(open, compact: false, now: now) == "#4328 · opened 3 d ago by alexec")
        #expect(WorkLook.rowLine(open, compact: true, now: now) == "#4328 · 3 d · alexec")
        var closed = row(state: "closed")
        closed.closed = now.addingTimeInterval(-5 * 86_400)
        #expect(WorkLook.rowLine(closed, compact: false, now: now) == "#4328 · closed 5 d ago")
        closed.stateReason = "not_planned"
        #expect(WorkLook.rowLine(closed, compact: false, now: now) == "#4328 · closed 5 d ago · not planned")
        #expect(WorkLook.rowLine(closed, compact: true, now: now) == "#4328 · 5 d · alexec · not planned")
        // A forge that gives no close time says the last update's, with its author.
        #expect(WorkLook.rowLine(row(state: "closed"), compact: false, now: now) == "#4328 · updated 2 h ago by alexec")
    }

    @Test func rowTakesTheNewFieldsFromItsItem() {
        let item = DaemonAPI.ForgeItem(node: Node(kind: "issue", ref: "github:alexec/Agents#7"), title: "Fix", state: "closed",
                                       author: "sam", updatedAt: now, authorAvatar: "https://avatars/sam",
                                       stateReason: "not_planned", createdAt: now.addingTimeInterval(-60), closedAt: now)
        let r = WorkList.Row(item, on: .mac)
        #expect(r.stateReason == "not_planned")
        #expect(r.avatar == "https://avatars/sam")
        #expect(r.created == now.addingTimeInterval(-60))
        #expect(r.closed == now)
    }

    @Test func issueStateLine() {
        let created = now.addingTimeInterval(-3 * 86_400)
        let closed = now.addingTimeInterval(-86_400)
        #expect(WorkLook.issueStateWords(author: "sam", state: "closed", updated: now, comments: 4, narrow: false,
                                         created: created, closed: closed, now: now)
            == "sam opened this 3 d ago · closed 1 d ago · 4 comments")
        #expect(WorkLook.issueStateWords(author: "sam", state: "open", updated: now, comments: 1, narrow: true,
                                         created: created, now: now) == "sam · 3 d · 1 comment")
        #expect(WorkLook.issueStateWords(author: "sam", state: "open", updated: now.addingTimeInterval(-7200), comments: 0,
                                         narrow: false, now: now) == "sam opened this · updated 2 h ago")
    }

    @Test func pullStateLineWithItsTimes() {
        let at = now.addingTimeInterval(-7200)
        #expect(WorkLook.pullStateWords(author: "sam", state: "open", updated: now, comments: 0, narrow: false, created: at, now: now)
            == "sam opened this pull request 2 h ago")
        #expect(WorkLook.pullStateWords(author: "sam", state: "merged", updated: now, comments: 2, narrow: false, closed: at, now: now)
            == "sam’s pull request was merged 2 h ago · 2 comments")
        #expect(WorkLook.pullStateWords(author: "sam", state: "merged", updated: now, comments: 0, narrow: true, closed: at, now: now)
            == "sam · 2 h")
    }

    @Test func eventWords() {
        typealias Event = DaemonAPI.ForgeEvent
        #expect(WorkLook.eventWords(Event(kind: "labeled", actor: "sam", at: now, label: .init(name: "bug"))) == "sam added the label bug")
        #expect(WorkLook.eventWords(Event(kind: "unlabeled", actor: "sam", at: now, label: .init(name: "bug"))) == "sam removed the label bug")
        #expect(WorkLook.eventWords(Event(kind: "assigned", actor: "sam", at: now, assignee: "sam")) == "sam self-assigned this")
        #expect(WorkLook.eventWords(Event(kind: "assigned", actor: "sam", at: now, assignee: "kim")) == "sam assigned kim")
        #expect(WorkLook.eventWords(Event(kind: "closed", actor: "sam", at: now,
                                          source: Node(kind: "pr", ref: "github:alexec/Agents#9"))) == "sam closed this in #9")
        #expect(WorkLook.eventWords(Event(kind: "reopened", at: now)) == "Someone reopened this")
        #expect(WorkLook.eventWords(Event(kind: "referenced", actor: "sam", at: now,
                                          source: Node(kind: "issue", ref: "github:alexec/Agents#3"))) == "sam mentioned this in #3")
        // A kind this client does not know, or one with nothing to say, draws nothing.
        #expect(WorkLook.eventWords(Event(kind: "milestoned", actor: "sam", at: now)) == nil)
        #expect(WorkLook.eventWords(Event(kind: "labeled", actor: "sam", at: now)) == nil)
    }

    @Test func timelineInterleavesCommentsAndEvents() {
        let c1 = DaemonAPI.ForgeComment(author: "a", body: "one", at: now.addingTimeInterval(-300))
        let c2 = DaemonAPI.ForgeComment(author: "b", body: "two", at: now.addingTimeInterval(-100))
        let early = DaemonAPI.ForgeEvent(kind: "labeled", actor: "a", at: now.addingTimeInterval(-400), label: .init(name: "bug"))
        let mid = DaemonAPI.ForgeEvent(kind: "assigned", actor: "a", at: now.addingTimeInterval(-200), assignee: "b")
        let odd = DaemonAPI.ForgeEvent(kind: "pinned", actor: "a", at: now.addingTimeInterval(-150))
        #expect(WorkLook.timeline(comments: [c1, c2], events: [early, mid, odd], older: false)
            == [.event(early), .comment(c1), .event(mid), .comment(c2)])
        // While older comments are to read, an event before the first comment read waits with them.
        #expect(WorkLook.timeline(comments: [c1, c2], events: [early, mid], older: true) == [.comment(c1), .event(mid), .comment(c2)])
        #expect(WorkLook.timeline(comments: [c1], events: nil, older: false) == [.comment(c1)])
        #expect(WorkLook.eventsSayClose([DaemonAPI.ForgeEvent(kind: "closed", at: now)]))
        #expect(!WorkLook.eventsSayClose(nil))
    }

    @Test func listTotal() {
        #expect(WorkLook.listTotal([128], filter: .init()) == 128)
        // Two machines read the same repos: their counts overlap.
        #expect(WorkLook.listTotal([128, 128], filter: .init()) == nil)
        #expect(WorkLook.listTotal([nil], filter: .init()) == nil)
        var f = WorkList.Filter()
        f.board = "https://github.com/orgs/acme/projects/1"
        #expect(WorkLook.listTotal([12], filter: f) == 12)
        f.label = "bug"
        #expect(WorkLook.listTotal([12], filter: f) == nil)
        #expect(WorkLook.endWords(.issue, shown: 50, more: true, total: 128) == "128 issues")
        #expect(WorkLook.endWords(.issue, shown: 50, more: true) == "50+ issues")
        #expect(WorkLook.loadingMore(shown: 50, total: 128) == "Loading more… · 50 of 128 shown")
    }

    @Test func rowLineSaysTheTrackersStatus() {
        #expect(WorkLook.rowLine(row(status: "In Progress"), compact: true, now: now) == "#4328 · In Progress · 2 h · alexec")
    }

    @Test func lineageOnAPhoneIsTheCostElseTheSessions() {
        #expect(WorkLook.lineageWords(lineage(sessions: 1, usd: 0), compact: true) == "1 session")
        #expect(WorkLook.lineageWords(lineage(sessions: 0, usd: 0), compact: false) == nil)
        #expect(WorkLook.lineageWords(nil, compact: false) == nil)
    }

    @Test func rowCarriesCommentsChecksAndReview() {
        let item = DaemonAPI.ForgeItem(node: Node(kind: "pr", ref: "github:alexec/Agents#7"), title: "Fix", state: "open",
                                       updatedAt: now, comments: 3, checks: "failing", review: "approved")
        let r = WorkList.Row(item, on: .mac)
        #expect(r.comments == 3)
        #expect(WorkLook.checks(r.checks) == .failing)
        #expect(WorkLook.checks("none") == nil)
        #expect(WorkLook.reviewWord(r.review) == "Approved")
        #expect(WorkLook.reviewWord(nil) == nil)
        #expect(WorkLook.commentsWords(0) == nil)
        #expect(WorkLook.commentsWords(3) == "3")
    }

    @Test func chipTextKeepsItsContrastInBothModes() throws {
        for color in ["#0e1f8a", "#ffffff", "#fbca04", "#d73a4a", "#000000", "#1D76DB", "#0E8A16", "#a2eeef"] {
            for dark in [false, true] {
                let chip = try #require(WorkLook.chip(color, dark: dark))
                #expect(chip.text.contrast(chip.fill) >= WorkLook.chipContrast, "\(color) dark: \(dark)")
            }
        }
        #expect(WorkLook.chip(nil, dark: false) == nil)
        #expect(WorkLook.chip("nope", dark: false) == nil)
    }

    @Test func chipFillIsTheColourAtLowOpacity() throws {
        // A dark label does not make a dark block: its fill stays near the ground.
        let chip = try #require(WorkLook.chip("#000000", dark: false))
        #expect(chip.fill.luminance > 0.6)
        // A colour that reads already keeps its own text.
        let blue = try #require(WorkLook.chip("#0e1f8a", dark: false))
        #expect(blue.text == WorkLook.RGB(0x0E1F8A))
    }

    @Test func contrastIsWCAGs() {
        #expect(abs(WorkLook.RGB(0x000000).contrast(WorkLook.RGB(0xFFFFFF)) - 21) < 0.01)
        #expect(WorkLook.RGB(0x777777).contrast(WorkLook.RGB(0x777777)) == 1)
    }

    @Test func scopedLabels() {
        #expect(WorkLook.scoped("feature:work") == ("feature:", "work"))
        #expect(WorkLook.scoped("bug") == (nil, "bug"))
        #expect(WorkLook.scoped(":odd") == (nil, ":odd"))
        #expect(WorkLook.scoped("odd:") == (nil, "odd:"))
    }

    @Test func atMostThreeChipsOnAWideRow() {
        let labels = ["a", "b", "c", "d", "e"].map { DaemonAPI.ForgeLabel(name: $0) }
        let wide = WorkLook.shownLabels(labels, limit: WorkLook.rowChips)
        #expect(wide.shown.map(\.name) == ["a", "b", "c"])
        #expect(wide.more == 2)
        #expect(WorkLook.shownLabels(labels, limit: nil).more == 0)
        #expect(WorkLook.shownLabels(Array(labels.prefix(3)), limit: 3).more == 0)
    }

    @Test func filterMenus() {
        #expect(WorkLook.menuTitle("Label", value: nil) == "Label")
        #expect(WorkLook.menuTitle("Label", value: "") == "Label")
        #expect(WorkLook.menuTitle("Label", value: "bug") == "Label: bug")
        #expect(WorkLook.searchPrompt(.pr) == "Filter pull requests")
        #expect(!WorkLook.narrows(WorkList.Filter(state: .closed)))
        #expect(!WorkLook.narrows(WorkList.Filter(text: "  ")))
        #expect(WorkLook.narrows(WorkList.Filter(label: "bug")))
        let cleared = WorkLook.cleared(WorkList.Filter(state: .all, repo: "r", text: "x"))
        #expect(cleared == WorkList.Filter(state: .all))
    }

    @Test func avatarsWithNoImage() {
        #expect(WorkLook.initial("alexec") == "A")
        #expect(WorkLook.initial("@bot") == "B")
        #expect(WorkLook.initial("") == "?")
        #expect(WorkLook.avatarHue("alexec") == WorkLook.avatarHue("Alexec"))
        #expect(WorkLook.avatarHue("alexec") != WorkLook.avatarHue("github-actions"))
        #expect((0 ..< 1).contains(WorkLook.avatarHue("anyone")))
    }

    @Test func commented() {
        #expect(WorkLook.commentedWords(now.addingTimeInterval(-20 * 60), now: now) == "commented 20 min ago")
        #expect(WorkLook.commentedWords(now, now: now) == "commented now")
    }

    @Test func emptyStates() {
        #expect(WorkLook.emptyTitle(.issue, state: .open, filtered: false) == "No open issues")
        #expect(WorkLook.emptyTitle(.pr, state: .merged, filtered: false) == "No merged pull requests")
        #expect(WorkLook.emptyTitle(.issue, state: .all, filtered: false) == "No issues")
        #expect(WorkLook.emptyTitle(.issue, state: .open, filtered: true) == "No issues match")
        #expect(WorkLook.emptyTitle(.release, state: .open, filtered: false) == "No releases yet")
        #expect(WorkLook.emptyLine(.issue, repos: ["github:alexec/Agents"]) == "Issues on alexec/Agents show here.")
        #expect(WorkLook.emptyLine(.pr, repos: []) == "Pull requests from your folders’ repos show here.")
    }

    @Test func aDraftSaysSoAfterItsNumber() {
        #expect(WorkLook.rowLine(row(draft: true), compact: false, now: now) == "#4328 · Draft · updated 2 h ago by alexec")
        #expect(WorkLook.rowLine(row(draft: true), compact: true, now: now) == "#4328 · Draft · 2 h · alexec")
        #expect(WorkLook.rowLine(row(state: "closed", draft: true), compact: true, now: now) == "#4328 · 2 h · alexec")
    }

    @Test func theFiltersThatAreSet() {
        #expect(WorkLook.setFilters(WorkList.Filter(state: .closed)) == nil)
        #expect(WorkLook.setFilters(WorkList.Filter(label: "bug", assignee: "alexec")) == "Label: bug · Assignee: alexec")
        #expect(WorkLook.setFilters(WorkList.Filter(project: "p1", text: " ui "), project: "Agents") == "“ui” · Project: Agents")
        #expect(WorkLook.setFilters(WorkList.Filter(repo: "github:alexec/Agents")) == "Repo: alexec/Agents")
    }

    @Test func pagingAndTheEndOfTheList() {
        #expect(WorkLook.loadingMore(shown: 50) == "Loading more… · 50 shown")
        #expect(WorkLook.endWords(.issue, shown: 128, more: false) == "128 issues")
        #expect(WorkLook.endWords(.issue, shown: 50, more: true) == "50+ issues")
        #expect(WorkLook.endWords(.issue, shown: 1, more: false) == "1 issue")
        #expect(WorkLook.endWords(.pr, shown: 1, more: false) == "1 pull request")
        #expect(WorkLook.endWords(.pr, shown: 1, more: true) == "1+ pull requests")
        #expect(WorkLook.couldNotRead(.pr) == "Could not read pull requests")
    }

    @Test func aCredentialErrorOffersConnectors() {
        #expect(WorkLook.credentialProblem("GitHub said 401 Bad credentials"))
        #expect(WorkLook.credentialProblem("Linear is not connected, or its token ended: connect Linear in Connectors"))
        #expect(!WorkLook.credentialProblem("GitHub said 502 Bad Gateway"))
    }
}
