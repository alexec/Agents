import Foundation
import AgentsKitCore

/// The viewer's pull requests as events (042 R8).
///
/// Worked out from 038's refresh and nothing else: each good list is compared with the
/// last one seen, and every change is raised, each followed by `pull_request.changed`
/// saying which. No new polling of GitHub, except one question about a pull request
/// that has left the open list — merged, or closed without merging — which the search
/// 038 runs cannot answer. 038's own triggers keep deciding their own fires; this only
/// says what happened, and hands back where, so their fires can point at it.
extension DaemonCore {
    /// Raise what changed since the last good list, and say where each landed, keyed
    /// by `"<number> <event name>"`.
    @discardableResult
    func raisePullRequestEvents(in list: PullRequestList) async -> [String: EventPosition] {
        loadEventsIfNeeded()
        let key = list.folder.path
        let now = now()
        let seenBefore = eventState.pullRequestsSeen[key]
        var positions: [String: EventPosition] = [:]
        var stillOpen: [SeenPullRequest] = list.pullRequests.map(Self.seen)
        // The first list for a project only says where things stand: nothing is invented
        // for what happened before anybody was looking (FR-014).
        guard let seenBefore else {
            eventState.pullRequestsSeen[key] = stillOpen
            eventStore.saveState(eventState)
            return positions
        }
        let before = Dictionary(uniqueKeysWithValues: seenBefore.map { ($0.number, $0) })

        func say(_ name: String, _ pull: SeenPullRequest, _ sentence: String) {
            let details = ["number": String(pull.number), "title": pull.title]
            let event = raise(EventDraft(name: name, at: now, scope: .project(folder: list.folder),
                                         sentence: sentence, details: details))
            positions["\(pull.number) \(name)"] = event.position
            raise(EventDraft(name: "pull_request.changed", at: now, scope: .project(folder: list.folder),
                             sentence: sentence,
                             details: details.merging(["what": String(name.dropFirst("pull_request.".count))]) { $1 }))
        }

        for pull in list.pullRequests.map(Self.seen) {
            let label = "#\(pull.number) \(pull.title)"
            guard let old = before[pull.number] else {
                say("pull_request.opened", pull, "\(label) was opened.")
                continue
            }
            if pull.checks == "failing", old.checks != "failing" {
                say("pull_request.checks_failed", pull, "Checks failed on \(label).")
            }
            if pull.checks == "passing", old.checks != "passing" {
                say("pull_request.checks_passed", pull, "Checks passed on \(label).")
            }
            if pull.review == "approved", old.review != "approved" {
                say("pull_request.approved", pull, "\(label) was approved.")
            }
            if pull.review == "changesRequested", old.review != "changesRequested" {
                say("pull_request.changes_requested", pull, "Changes were requested on \(label).")
            }
            if pull.conflicts == "conflicting", old.conflicts != "conflicting" {
                say("pull_request.conflicts", pull, "\(label) conflicts with its base.")
            }
            if let latest = pull.lastCommentAt, latest > (old.lastCommentAt ?? .distantPast) {
                say("pull_request.review_comments", pull, "\(label) has new review comments.")
            }
        }

        // Gone from the open list: merged, or closed. Asked once each; one that cannot
        // be asked is kept as last seen and asked again next time.
        let openNow = Set(list.pullRequests.map(\.number))
        for gone in seenBefore where !openNow.contains(gone.number) {
            let label = "#\(gone.number) \(gone.title)"
            switch await pullRequestEnding(gone.number, in: list.repository) {
            case .merged?: say("pull_request.merged", gone, "\(label) was merged.")
            case .closed?: say("pull_request.closed", gone, "\(label) was closed without merging.")
            case nil: stillOpen.append(gone)
            }
        }
        eventState.pullRequestsSeen[key] = stillOpen
        eventStore.saveState(eventState)
        return positions
    }

    enum PullRequestEnding { case merged, closed }

    /// Whether a pull request that has left the open list was merged or closed, or nil
    /// when GitHub could not be asked or says it is still open.
    func pullRequestEnding(_ number: Int, in repository: GitHubRepository) async -> PullRequestEnding? {
        guard let body = try? await gitHubCLI.api(method: "GET",
                                                  path: "repos/\(repository.owner)/\(repository.name)/pulls/\(number)",
                                                  host: repository.host),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if json["merged"] as? Bool == true || json["merged_at"] is String { return .merged }
        if (json["state"] as? String)?.lowercased() == "closed" { return .closed }
        return nil
    }

    /// A pull request as the next refresh will be compared against.
    static func seen(_ pull: PullRequest) -> SeenPullRequest {
        let checks: String
        switch pull.checks {
        case .passing: checks = "passing"
        case .failing: checks = "failing"
        case .running: checks = "running"
        case .none: checks = "none"
        }
        return SeenPullRequest(number: pull.number, title: pull.title, checks: checks,
                               review: pull.review.rawValue, conflicts: pull.conflicts.rawValue,
                               lastCommentAt: pull.countableComments.map(\.createdAt).max())
    }

    /// The event a 038 trigger's change was raised as, for that pull request.
    static func eventName(for trigger: WorkflowTrigger) -> String? {
        EventCatalogue.kinds(forAlias: trigger.name).first?.name
    }
}
