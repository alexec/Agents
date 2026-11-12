import Foundation
import Testing
@testable import AgentsKitCore

/// A machine's capacity on its page (#4582): the load, the level and why, and the starts that wait.
@Suite("Capacity words")
struct CapacityWordsTests {
    private func usage(_ level: DaemonAPI.CapacityLevel?, load: Double? = 2.4, load5: Double? = 2.1,
                       pressure: DaemonAPI.MemoryPressure? = .normal, swap: Double? = 3) -> DaemonAPI.MachineUsage {
        DaemonAPI.MachineUsage(cpuPercent: 82, cpuCount: 10, memoryUsed: 14, memoryTotal: 16, loadPerCore: load,
                               loadPerCore5: load5, memoryPressure: pressure, swapUsedPercent: swap, capacity: level)
    }

    @Test func theSummarySaysTheLoadAndTheLevelOnlyWhenItIsNotOK() {
        #expect(CapacityWords.load(2.44) == "Load 2.4 per core")
        #expect(CapacityWords.level(.ok) == nil)
        #expect(CapacityWords.level(nil) == nil)
        #expect(CapacityWords.level(.near) == "Near capacity")
        #expect(CapacityWords.level(.full) == "At capacity")
    }

    @Test func theWarningNamesWhatPutItThere() {
        #expect(CapacityWords.warning(usage(.ok), name: "This Mac") == nil)
        #expect(CapacityWords.warning(usage(nil), name: "This Mac") == nil)
        #expect(CapacityWords.warning(usage(.near, load: 1.8), name: "This Mac")
            == "This Mac is near capacity: load 1.8 per core.")
        #expect(CapacityWords.warning(usage(.near, load: 0.4, pressure: .warn), name: "studio")
            == "studio is near capacity: memory pressure warn.")
        #expect(CapacityWords.warning(usage(.full, load: 3.1), name: "This Mac")
            == "This Mac is at capacity: load 3.1 per core.")
        #expect(CapacityWords.warning(usage(.full, load: 1.0, pressure: .critical), name: "This Mac")
            == "This Mac is at capacity: memory pressure critical.")
        #expect(CapacityWords.warning(usage(.full, load: 1.0, swap: 62), name: "This Mac")
            == "This Mac is at capacity: swap 62% used.")
        // Coming down, under every line until the second look: the load.
        #expect(CapacityWords.warning(usage(.near, load: 1.2), name: "This Mac")
            == "This Mac is near capacity: load 1.2 per core.")
    }

    @Test func theTooltipSaysEverySignal() {
        #expect(CapacityWords.detail(usage(.ok))
            == "Load 2.4 per core over 1 minute, 2.1 over 5 · Memory pressure normal · Swap 3% used")
        #expect(CapacityWords.detail(usage(.ok, load5: nil, pressure: nil, swap: nil)) == "Load 2.4 per core over 1 minute")
        #expect(CapacityWords.detail(usage(nil, load: nil)) == nil)
    }

    @Test func queuedStartsAreCounted() {
        #expect(CapacityWords.queued(0) == nil)
        #expect(CapacityWords.queued(1) == "1 start queued")
        #expect(CapacityWords.queued(2) == "2 starts queued")
    }
}
