import Foundation
import Testing
@testable import AgentsKitCore

/// A runtime's machines in one line on Your setup (#3744). The web page's machinesSummary is
/// tested with the same cases.
@Suite("A runtime's machines in one line")
struct RuntimeMachinesSummaryTests {
    private let path = RuntimeAvailability.available(path: "/p", supportsResume: true)

    private func status(_ availability: RuntimeAvailability, signIn: RuntimeStatus.SignIn? = nil,
                        outdated: Bool = false) -> RuntimeStatus {
        var status = RuntimeStatus(runtime: Runtime(id: "codex", name: "Codex", executable: "codex-acp", arguments: []),
                                   availability: availability, outdated: outdated)
        status.signIn = signIn
        return status
    }

    private func line(_ machines: [(String, RuntimeStatus?, Bool)]) -> String {
        RuntimeMachinesSummary(machines.map { (machine: $0.0, status: $0.1, online: $0.2) }).words { $0 }
    }

    @Test func onEveryMachineSaysHowMany() {
        #expect(line([("This Mac", status(path), true), ("devbox", status(path, signIn: .init(signedIn: true)), true),
                      ("relay", status(path, signIn: .init(signedIn: false, relayed: true)), true)])
                == "On all 3 machines")
    }

    @Test func oneMachineIsNamed() {
        #expect(line([("This Mac", status(path), true)]) == "On This Mac")
    }

    @Test func theOthersAreNamedByWhatStopsThem() {
        #expect(line([("This Mac", status(path), true), ("build-box", status(.missing(lookedIn: [])), true)])
                == "On This Mac · Not on build-box")
        #expect(line([("This Mac", status(path), true),
                      ("a", status(path, signIn: .init(signedIn: false)), true),
                      ("b", status(.needsSignIn(authMethods: [], fixCommand: nil)), true),
                      ("c", status(.failed(reason: "x")), true),
                      ("d", status(.installing(progress: nil)), true),
                      ("e", nil, false),
                      ("f", nil, true)])
                == "On This Mac · Not signed in on a, b · Can’t be used on c · Installing on d · Offline: e · Not known yet on f")
    }

    @Test func anUpdateIsSaidAfterwards() {
        #expect(line([("This Mac", status(path, outdated: true), true), ("devbox", status(path), true)])
                == "On all 2 machines · An update is out on This Mac")
    }

    @Test func inUseIsInstalledSomewhere() {
        let missing = status(.missing(lookedIn: []))
        #expect(!RuntimeMachinesSummary([(machine: "m", status: missing, online: true),
                                         (machine: "s", status: nil, online: false)]).inUse)
        #expect(RuntimeMachinesSummary([(machine: "m", status: missing, online: true),
                                        (machine: "s", status: status(.needsSignIn(authMethods: [], fixCommand: nil)),
                                         online: true)]).inUse)
    }

    @Test func theAmountHasNoTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = AllowanceReading(window: "seven_day", used: 0.38, resetsAt: now.addingTimeInterval(86400), at: now)
        #expect(PoolWords.amount(reading, now: now) == "62% left this week")
        #expect(PoolWords.amount(AllowanceReading(window: "seven_day", at: now), now: now) == nil)
        #expect(PoolWords.reading(AllowanceReading(window: "seven_day", at: now), now: now)?.hasPrefix("This week · as of") == true)
    }
}
