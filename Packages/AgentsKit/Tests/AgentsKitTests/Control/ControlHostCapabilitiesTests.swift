import AgentsKitCore
import Foundation
import Testing

/// A host's capabilities on its machines/list row (#1748).
@Suite("A host's capabilities")
struct ControlHostCapabilitiesTests {
    private func row(_ extra: String) throws -> DaemonAPI.ControlMachine {
        let json = #"{"id":"box","name":"Box","platform":"linux","version":"0.7.0","state":"online","reach":"dialOut""#
            + extra + "}"
        return try JSONDecoder().decode(DaemonAPI.ControlMachine.self, from: Data(json.utf8))
    }

    @Test func aHostHasWhatItsListNames() throws {
        let host = try row(#","capabilities":["agents/1"],"missing":["host.wire/1"]"#)
        #expect(host.has(Capability.agents1))
        #expect(!host.has(Capability.chatBranch1))
        #expect(host.missing == [Capability.hostWire1])
    }

    /// A host older than capabilities says no list, and is taken to have them all.
    @Test func aHostThatSaidNoListHasEverything() throws {
        let host = try row("")
        #expect(host.capabilities == nil)
        #expect(host.has(Capability.chatBranch1))
    }

    /// A host that needs an update is connected and answers, gated by its list (#1771).
    @Test func aHostThatNeedsAnUpdateAnswers() throws {
        let host = try row(#","capabilities":["agents/1"],"missing":["host.wire/1"]"#)
        var old = host
        old.state = "needsUpdate"
        #expect(host.answers)
        #expect(old.answers)
        for state in ["offline", "connecting", "failed", "stopped"] {
            old.state = state
            #expect(!old.answers)
        }
        #expect(!DaemonAPI.ControlMachine.answers(nil))
    }

    @Test func theStatusSaysWhatItRequires() throws {
        let json = #"{"name":"t","version":"0.7.0","machineID":"M","capabilities":["machines/1"],"required":{"host":["host.wire/1"],"client":["client.wire/1"]}}"#
        let status = try JSONDecoder().decode(DaemonAPI.ControlStatus.self, from: Data(json.utf8))
        #expect(status.required?.client == [Capability.clientWire1])
        #expect(status.capabilities == [Capability.machines1])
    }
}
