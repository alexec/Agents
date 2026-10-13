// Waits on one repo's events share its listings (#932): the number of `gh` runs stays flat as
// the waits grow. A counting stand-in for gh; nothing here calls GitHub.
@testable import CIWatcher
import Foundation
import Testing

actor GhCounter {
    var calls: [[String]] = []
    func add(_ args: [String]) { calls.append(args) }
}

func countingGitHub(sharedFor: Duration, _ counter: GhCounter) -> RealGitHub {
    RealGitHub(sharedFor: sharedFor) { args in
        await counter.add(args)
        try? await Task.sleep(for: .milliseconds(50))
        // `gh pr list` answers with a bare body; `gh api -i` with a response.
        let stdout = args.first == "pr" ? "[]" : "HTTP/2.0 200 OK\r\nEtag: \"e\"\r\n\r\n[]"
        return .init(code: 0, stdout: stdout, stderr: "", missing: false)
    }
}

@Suite struct SharedListingTests {
    @Test func tenWaitsPollingAtOnceRunGhOnce() async throws {
        let counter = GhCounter()
        let gh = countingGitHub(sharedFor: .seconds(25), counter)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try await gh.closedPRs(repo: "alexec/Agents", since: "2026-10-13T00:00:00Z") }
            }
            try await group.waitForAll()
        }
        #expect(await counter.calls.count == 1)
    }

    @Test func aPollInsideTheWindowRunsNoGh() async throws {
        let counter = GhCounter()
        let gh = countingGitHub(sharedFor: .seconds(25), counter)
        _ = try await gh.failedRuns(repo: "alexec/Agents", branch: nil, since: "2026-10-13T00:00:00Z")
        _ = try await gh.failedRuns(repo: "alexec/Agents", branch: nil, since: "2026-10-13T00:00:00Z")
        _ = try await gh.listPRs(repo: "alexec/Agents")
        _ = try await gh.listPRs(repo: "alexec/Agents")
        #expect(await counter.calls.count == 2)
    }

    @Test func aPollAfterTheWindowAsksAgainWithTheETag() async throws {
        let counter = GhCounter()
        let gh = countingGitHub(sharedFor: .zero, counter)
        _ = try await gh.closedPRs(repo: "alexec/Agents", since: "2026-10-13T00:00:00Z")
        _ = try await gh.closedPRs(repo: "alexec/Agents", since: "2026-10-13T00:00:00Z")
        let calls = await counter.calls
        #expect(calls.count == 2)
        #expect(calls.last?.contains("If-None-Match: \"e\"") == true)
    }
}
