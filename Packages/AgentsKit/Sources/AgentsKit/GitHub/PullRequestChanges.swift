import Foundation
import AgentsKitCore

/// What has changed on a pull request that a workflow has not yet fired on (038 R6).
///
/// Each change has a key, and a trigger fires when the key it would fire on is not the
/// one it last fired on. That turns "once for each distinct change, not once per
/// refresh" (FR-013) into a comparison of two strings: the same failing check run keeps
/// its id, and a re-run or a new commit that fails again does not.
public enum PullRequestChanges {
    /// One change a workflow could fire on.
    public struct Change: Hashable, Sendable {
        public var trigger: WorkflowTrigger
        public var key: String
        /// What the prompt says changed (FR-018).
        public var checks: [FailedCheck] = []
        public var comments: [ReviewItem] = []
        public var conflictsWith: String?
    }

    /// Where `firedKeys` keeps the last key a workflow's trigger fired on.
    public static func slot(workflowID: String, trigger: WorkflowTrigger) -> String {
        "\(workflowID)/\(trigger.name)"
    }

    /// The change this trigger would fire on now, fired before or not. Nil when there
    /// is nothing to fire on.
    public static func current(_ trigger: WorkflowTrigger, on pull: PullRequest,
                               record: PullRequestRecord?, workflowID: String) -> Change? {
        switch trigger {
        case .pullRequestChecksFailed:
            guard case .failing(let failed) = pull.checks, !failed.isEmpty else { return nil }
            let ids = failed.map(\.id).sorted().joined(separator: ",")
            return Change(trigger: trigger, key: "checks:\(pull.headOid):\(ids)", checks: failed)

        case .pullRequestReviewComments:
            let items = newComments(on: pull, record: record, workflowID: workflowID)
            guard let newest = items.map(\.id).max() else { return nil }
            return Change(trigger: trigger, key: "comments:\(newest)", comments: items)

        case .pullRequestConflicts:
            // Not yet worked out by GitHub is not a conflict (R6); it is looked at again
            // on the next refresh.
            guard pull.conflicts == .conflicting else { return nil }
            return Change(trigger: trigger, key: "conflict:\(pull.baseOid)", conflictsWith: pull.baseBranch)

        default:
            return nil
        }
    }

    /// The changes each of a workflow's pull-request triggers has not fired on yet.
    public static func unfired(_ triggers: [WorkflowTrigger], on pull: PullRequest,
                               record: PullRequestRecord?, workflowID: String) -> [Change] {
        triggers.filter(\.isPullRequest).compactMap { trigger in
            guard let change = current(trigger, on: pull, record: record, workflowID: workflowID)
            else { return nil }
            let fired = record?.firedKeys[slot(workflowID: workflowID, trigger: trigger)]
            return fired == change.key ? nil : change
        }
    }

    /// The reviewers' words a workflow has not fired on yet (FR-011, FR-011a).
    ///
    /// Only words that count were decoded at all. Of those: newer than the last one this
    /// workflow fired on; or, the first time it sees this pull request, newer than the
    /// viewer's own latest action on it, so an old settled review does not come back up
    /// (R6). Babysitting's own replies are the viewer's, and never count either.
    public static func newComments(on pull: PullRequest, record: PullRequestRecord?,
                                   workflowID: String) -> [ReviewItem] {
        let posted = Set(record?.postedCommentIDs ?? [])
        let items = pull.countableComments.filter { !posted.contains($0.id) }
        if let watermark = record?.commentWatermark[workflowID] {
            return items.filter { $0.id > watermark }
        }
        guard let since = pull.viewerLastActionAt else { return items }
        return items.filter { $0.createdAt > since }
    }
}
