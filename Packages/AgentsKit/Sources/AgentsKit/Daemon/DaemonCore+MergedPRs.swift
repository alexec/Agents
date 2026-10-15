import Foundation
import AgentsKitCore

/// The pull requests merged from the branches the app makes (#985), for the recap and
/// records on the Time page. Asked of the person's own `gh` once an hour, in each project
/// that is a git repository; a project whose remote is not GitHub, or a Mac with no `gh`,
/// says nothing, and the page shows a dash.
extension DaemonCore {
    public static let mergedPRsInterval: Duration = .seconds(3600)
    /// How many days an hourly ask goes back: a pull request merged on a day the Mac was
    /// asleep is still counted on its own day.
    static let mergedPRsDaysAsked = 7

    /// Start asking, a minute after the daemon starts, when its projects are known.
    public func startCountingMergedPRs(every interval: Duration = DaemonCore.mergedPRsInterval) {
        mergedPRsTicker?.cancel()
        mergedPRsTicker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.countMergedPRs()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Ask every project's `gh`, and write what they said for the days asked about. The
    /// first answer goes back as far as the Time page keeps days.
    func countMergedPRs() async {
        let days = timeLedger.hasPRsMerged ? Self.mergedPRsDaysAsked : UsageHistory.daysKept
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now())
        let stamps = (0..<days).map {
            UsageChart.dayStamp(calendar.date(byAdding: .day, value: -$0, to: today)!, calendar: calendar)
        }
        var pulls: [GitHubCLI.MergedPullRequest] = []
        var answered = false
        for folder in branchFolders.sorted(by: { $0.path < $1.path }) {
            guard let found = try? await gitHubCLI.mergedPullRequests(in: folder, since: stamps.last!) else { continue }
            pulls += found
            answered = true
        }
        guard answered else { return }
        timeLedger.setPRsMerged(GitHubCLI.mergedByDay(pulls, calendar: calendar), on: stamps)
        keepQuietly("the time history") { try timeLedger.flush() }
    }
}
