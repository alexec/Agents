import Foundation
import AgentsKitCore

/// The person's own `gh`, run by the daemon, which the skills catalogue reads GitHub
/// through when it is signed in, for the higher hourly limit.
///
/// Their sign-in is `gh`'s: a token for each host in the keychain, which the daemon never
/// holds. The app stores no token and asks for none.
public struct GitHubCLI: Sendable {
    /// Where `gh` is, or nil when it isn't installed. A test puts a fake one here.
    let executable: @Sendable () -> URL?

    public init(executable: @escaping @Sendable () -> URL? = GitHubCLI.onPath) {
        self.executable = executable
    }

    /// `gh` on the person's PATH.
    public static let onPath: @Sendable () -> URL? = {
        for directory in LoginShellPath.directories() {
            let candidate = URL(filePath: directory).appending(path: "gh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Why a call gave nothing usable: `gh` is missing, or said this.
    public struct Failure: Error, Sendable {
        public var said: String
    }

    /// A REST call.
    public func api(method: String, path: String, host: String) async throws -> Data {
        guard let gh = executable() else { throw Failure(said: "gh is not installed") }
        let call = GitProcess(
            executable: gh, arguments: ["api", "--hostname", host, "-X", method, path],
            environment: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"])
        // As long as the URLSession path beside it waits, give or take (#207).
        call.deadline = .seconds(20)
        let outcome = try await call.run()
        if outcome.truncated { throw Failure(said: "gh answered with more than \(call.outputLimit) bytes") }
        if outcome.succeeded { return outcome.data }
        throw Failure(said: outcome.errors.split(separator: "\n").first.map(String.init) ?? "gh failed")
    }
}

extension GitHubCLI {
    /// A pull request `gh pr list --state merged` named (#985).
    public struct MergedPullRequest: Decodable, Sendable, Hashable {
        public var url: String
        public var mergedAt: Date
        public var headRefName: String
    }

    /// The pull requests of the repository `folder` is in that merged on or after `day`
    /// (`yyyy-MM-dd`), at most `limit` of them.
    public func mergedPullRequests(in folder: URL, since day: String, limit: Int = 1_000) async throws
        -> [MergedPullRequest] {
        guard let gh = executable() else { throw Failure(said: "gh is not installed") }
        let call = GitProcess(
            executable: gh,
            arguments: ["pr", "list", "--state", "merged", "--search", "merged:>=\(day)",
                        "--json", "url,mergedAt,headRefName", "--limit", String(limit)],
            in: folder,
            environment: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"])
        call.deadline = .seconds(30)
        let outcome = try await call.run()
        guard outcome.succeeded, !outcome.truncated else {
            throw Failure(said: outcome.errors.split(separator: "\n").first.map(String.init) ?? "gh failed")
        }
        return try Self.mergedPullRequests(from: outcome.data)
    }

    static func mergedPullRequests(from data: Data) throws -> [MergedPullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([MergedPullRequest].self, from: data)
    }

    /// How many of `pulls` came from the app's branches, by the host's day each merged.
    /// The same pull request named by two checkouts of one repository counts once.
    public static func mergedByDay(_ pulls: [MergedPullRequest], calendar: Calendar = .current) -> [String: Int] {
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        for pull in pulls where pull.headRefName.hasPrefix(WorktreeName.branchPrefix) {
            guard seen.insert(pull.url).inserted else { continue }
            counts[UsageChart.dayStamp(pull.mergedAt, calendar: calendar), default: 0] += 1
        }
        return counts
    }
}
