import Foundation
import Testing
@testable import AgentsKitCore

/// The Get started card's rules (#982): ticked from facts, gone for good once gone.
@Suite("Get started")
struct GetStartedTests {
    private let setUp = GetStarted.Facts(paired: true, runtimeReady: true, hasFolder: true, ranAgent: true)

    @Test func aPersonAlreadySetUpNeverSeesTheCard() {
        #expect(GetStarted.card(kept: nil, facts: setUp) == .gone)
    }

    @Test func aNewcomerSeesItUntilEveryStepIsDone() {
        let fresh = GetStarted.Facts(paired: true)
        #expect(GetStarted.card(kept: nil, facts: fresh) == .showing)
        // Set up but no device yet: the optional step keeps it until dismissed.
        #expect(GetStarted.card(kept: .showing, facts: setUp) == .showing)
        var all = setUp
        all.pairedDevice = true
        #expect(GetStarted.card(kept: .showing, facts: all) == .gone)
    }

    @Test func goneStaysGone() {
        #expect(GetStarted.card(kept: .gone, facts: GetStarted.Facts()) == .gone)
    }

    @Test func theDeviceStepIsTheOnlyOptionalOne() {
        #expect(GetStarted.Step.allCases.filter(\.isOptional) == [.device])
        #expect(setUp.isSetUp && !setUp.isAllDone)
        #expect(setUp.doneCount == 4)
    }

    @Test func aTurnHasRunOnlyOnceOneHasEnded() {
        let start = Date(timeIntervalSince1970: 1000)
        let cwd = URL(filePath: "/tmp/folder")
        let fresh = Agent(runtimeID: "claude", cwd: cwd, state: .starting, createdAt: start, lastActivityAt: start)
        let running = Agent(runtimeID: "claude", cwd: cwd, state: .running, createdAt: start, lastActivityAt: start + 5)
        let queued = Agent(runtimeID: "claude", cwd: cwd, state: .queued, createdAt: start, lastActivityAt: start + 5)
        let finished = Agent(runtimeID: "claude", cwd: cwd, state: .finished, createdAt: start, lastActivityAt: start + 60)
        #expect(!GetStarted.hasRunATurn(fresh))
        #expect(!GetStarted.hasRunATurn(running))
        #expect(!GetStarted.hasRunATurn(queued))
        #expect(GetStarted.hasRunATurn(finished))
    }

    @Test func aDeviceIsAnythingPairedButAMacWindow() {
        func client(_ kind: ClientRecord.Kind, forgotten: Bool? = nil) -> ClientRecord {
            ClientRecord(id: UUID(), name: "x", kind: kind, publicKey: Data(), paired: Date(), forgotten: forgotten)
        }
        #expect(!GetStarted.isDeviceOrBrowser(client(.mac)))
        #expect(GetStarted.isDeviceOrBrowser(client(.iPhone)))
        #expect(GetStarted.isDeviceOrBrowser(client(.browser)))
        #expect(!GetStarted.isDeviceOrBrowser(client(.iPad, forgotten: true)))
    }
}
