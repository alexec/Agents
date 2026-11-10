import Foundation

/// A pull request's page in the Work look (#4406, `specs/4328-work-look/pull-request.md`): the
/// merge box at the end of the timeline (the review, the checks and conflicts as rows, then Merge,
/// Approve and Rerun failed), Files changed in the header, and the state line. `Shared/UI/Work`
/// draws it for the Mac window and the Remote; the web page draws the same with #4408.
public extension WorkLook {
    /// How a merge box row stands: its glyph's colour. `pass` is green, `fail` red, `wait` amber,
    /// `info` grey.
    enum MergeSign: String, Sendable {
        case pass, fail, wait, info
    }

    /// What a merge box row is about; the view picks its glyph by it and its sign.
    enum MergeRowKind: String, Sendable {
        case review, draft, checks, conflicts, autoMerge
    }

    /// One row of the merge box: *Review required* · *No one approved yet · 2 unresolved threads*.
    struct MergeRow: Sendable, Hashable {
        public var kind: MergeRowKind
        public var sign: MergeSign
        public var title: String
        public var line: String?
    }

    /// The merge box of an open pull request (pull-request.md note 10 and its states).
    struct MergeBox: Sendable, Hashable {
        /// The box's border: green when it can merge, red when a check failed or it has
        /// conflicts, grey otherwise (`info`).
        public var border: MergeSign
        public var rows: [MergeRow]
        /// The checks list is open from the start: a check failed (decided in pull-request.md).
        public var checksOpen: Bool
        /// Merge ▾ is there: not on a draft, nor with conflicts, nor while auto-merge is on.
        public var merges: Bool
        /// The main button merges now (green), or waits for the checks (the accent colour).
        public var waits: Bool
        public var approves: Bool
        public var reruns: Bool
        /// *Resolve on GitHub*: the branch has conflicts.
        public var resolve: Bool
    }

    /// The merge box, from what the wire has; nil for an item that is not an open pull request.
    static func mergeBox(_ detail: DaemonAPI.ForgeItemDetail) -> MergeBox? {
        let item = detail.item
        guard item.node.kind == "pr", item.state == "open" else { return nil }
        let draft = item.draft == true
        let checks = checksRow(detail.checks, summary: item.checks)
        let conflicts = item.mergeable == "conflicting"
        let auto = item.autoMerge == true
        var rows: [MergeRow] = []
        if draft {
            rows.append(MergeRow(kind: .draft, sign: .info, title: "This is a draft",
                                 line: "It cannot merge until it is ready for review."))
        } else if let review = reviewRow(item.review, threads: detail.reviewThreads) {
            rows.append(review)
        }
        if let checks { rows.append(checks) }
        switch item.mergeable {
        case "conflicting": rows.append(MergeRow(kind: .conflicts, sign: .fail, title: "This branch has conflicts",
                                                 line: "Resolve them before it can merge."))
        case "mergeable": rows.append(MergeRow(kind: .conflicts, sign: .pass, title: "No conflicts with the base branch", line: nil))
        default: break
        }
        if auto, !draft {
            rows.append(MergeRow(kind: .autoMerge, sign: .info, title: "Auto-merge is on",
                                 line: "\(mergeTitle(detail.mergeMethods?.first)) when the checks pass"))
        }
        let failed = checks?.sign == .fail
        let waits = WorkList.mergeWaits(detail) || failed
        let reviewed = item.review == nil || item.review == "approved"
        let border: MergeSign = failed || conflicts ? .fail : (!draft && !waits && !auto && reviewed) ? .pass : .info
        return MergeBox(border: border, rows: rows, checksOpen: failed,
                        merges: !draft && !conflicts && !auto && detail.head != nil,
                        waits: waits, approves: !draft && detail.head != nil,
                        reruns: !WorkList.failedChecks(detail).isEmpty, resolve: conflicts)
    }

    /// The main button's words: the repo's first method, *Merge when checks pass* while they run.
    static func mergeMain(_ methods: [DaemonAPI.ForgeMergeMethod]?, waits: Bool) -> String {
        waits ? "Merge when checks pass" : mergeTitle(methods?.first)
    }

    private static func mergeTitle(_ method: DaemonAPI.ForgeMergeMethod?) -> String {
        method.map(WorkList.mergeTitle) ?? "Merge"
    }

    /// The review row: *Approved*, *Changes requested* or *Review required*; nil when the forge
    /// asks no review.
    static func reviewRow(_ review: String?, threads: Int?) -> MergeRow? {
        let unresolved = threads.flatMap { $0 > 0 ? ($0 == 1 ? "1 unresolved thread" : "\($0) unresolved threads") : nil }
        switch review {
        case "approved":
            return MergeRow(kind: .review, sign: .pass, title: "Approved", line: unresolved)
        case "changes_requested":
            return MergeRow(kind: .review, sign: .fail, title: "Changes requested",
                            line: ["A reviewer asked for changes", unresolved].compactMap { $0 }.joined(separator: " · "))
        case "review_required":
            return MergeRow(kind: .review, sign: .wait, title: "Review required",
                            line: ["No one approved yet", unresolved].compactMap { $0 }.joined(separator: " · "))
        default:
            return nil
        }
    }

    /// The checks row: *All checks passed* · *14 passed, 1 skipped*, *Checks are running* · *9
    /// passed, 4 running*, or *1 check failed*. With no list, the summary word alone; nil with none.
    static func checksRow(_ checks: [DaemonAPI.ForgeCheck]?, summary: String?) -> MergeRow? {
        let checks = checks ?? []
        let n = { (state: String) in checks.filter { $0.state == state }.count }
        let (failing, running, passing, skipped) = (n("failing"), n("running"), n("passing"), n("skipped"))
        let state: String
        if !checks.isEmpty {
            state = failing > 0 ? "failing" : running > 0 ? "running" : "passing"
        } else if let summary, ["failing", "running", "passing"].contains(summary) {
            state = summary
        } else {
            return nil
        }
        let counts = [(failing, "failed"), (passing, "passed"), (running, "running"), (skipped, "skipped")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let line = counts.isEmpty ? nil : counts.joined(separator: ", ")
        switch state {
        case "failing":
            let title = failing == 0 ? "Some checks failed" : failing == 1 ? "1 check failed" : "\(failing) checks failed"
            return MergeRow(kind: .checks, sign: .fail, title: title, line: line)
        case "running":
            return MergeRow(kind: .checks, sign: .wait, title: "Checks are running", line: line)
        default:
            return MergeRow(kind: .checks, sign: .pass, title: "All checks passed", line: line)
        }
    }

    /// The checks in the box's list: the failed first, then the running, then the rest, each in
    /// the forge's order.
    static func checksInOrder(_ checks: [DaemonAPI.ForgeCheck]) -> [DaemonAPI.ForgeCheck] {
        let rank = ["failing": 0, "running": 1, "passing": 2, "skipped": 3]
        return checks.enumerated().sorted { a, b in
            let (ra, rb) = (rank[a.element.state] ?? 4, rank[b.element.state] ?? 4)
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    /// The header's *Files changed 6*; *Files changed* when the forge gives no count.
    static func filesChanged(_ n: Int?) -> String { n.map { "Files changed \($0)" } ?? "Files changed" }

    /// The side panel's Branch, until the wire has the branches (#4406, missing fields): *6 files*.
    static func branchWords(_ filesChanged: Int?) -> String? {
        filesChanged.map { $0 == 1 ? "1 file" : "\($0) files" }
    }

    /// A pull request's state line after its pill. Wide: *sam opened this pull request · updated
    /// 2 h ago · 4 comments*; merged: *merged · updated 10 min ago*; on a phone: *sam · 2 h · 4
    /// comments*. The opened and merged times and the branches come with #4373 and the forge fields.
    static func pullStateWords(author: String?, state: String, updated: Date?, comments: Int, narrow: Bool,
                               now: Date = Date()) -> String {
        let age = updated.map { ageWords(now.timeIntervalSince($0)) }
        var parts: [String] = []
        if narrow {
            parts += [author, age].compactMap { $0 }
        } else {
            switch state {
            case "merged": parts.append(author.map { "\($0)’s pull request was merged" } ?? "Merged")
            case "closed": parts.append(author.map { "\($0)’s pull request was closed with unmerged commits" } ?? "Closed with unmerged commits")
            default: if let author { parts.append("\(author) opened this pull request") }
            }
            if let age { parts.append(age == "now" ? "updated now" : "updated \(age) ago") }
        }
        if comments > 0 { parts.append(comments == 1 ? "1 comment" : "\(comments) comments") }
        return parts.joined(separator: " · ")
    }

    /// The Reviewers section, until the wire has each reviewer (#4406, missing fields): the
    /// review's state, or *No one* when none is asked.
    static func reviewersWords(_ review: String?) -> String { reviewWord(review) ?? "No one" }

    /// In the merge box's place on a merged pull request.
    static let mergedStrip = "Merged."
    /// In place of the buttons when no machine of the person's writes to the forge.
    static func noWriter(_ ref: String) -> String { "No machine of yours can write to \(WorkList.forgeName(ref))." }
    /// Under a draft's merge box: the forge has the button.
    static func readyOnForge(_ ref: String) -> String { "Ready for review is on \(WorkList.forgeName(ref))." }
    static func resolveOnForge(_ ref: String) -> String { "Resolve on \(WorkList.forgeName(ref))" }
}
