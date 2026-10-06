import Testing
@testable import AgentsKitCore

/// The computers a workflow page offers, under the names already on screen (#317).
@Suite("Choosing a workflow's hosts")
struct WorkflowHostsTests {
    private func host(_ id: String, _ name: String, machine: String?, relay: Bool? = nil) -> DaemonAPI.ControlHost {
        DaemonAPI.ControlHost(id: HostID(rawValue: id), name: name, platform: "macOS", version: "1",
                              state: "online", reach: "local", machineID: machine, relay: relay)
    }

    @Test func thisMacLeadsAndARelayOrAHostWithoutAnIdIsLeftOut() {
        let hosts = [
            host("box", "Zebra", machine: "zebra"),
            host("relay", "Relay", machine: "relay-id", relay: true),
            host("mac", "Alex’s Mac", machine: "mac-id"),
            host("gone", "No id", machine: nil),
            host("blank", "Blank", machine: "  "),
            host("again", "Also this Mac", machine: "mac-id"),
        ]
        let choices = WorkflowHosts.choices(from: hosts, thisMachine: "mac-id")
        #expect(choices.map(\.name) == ["This Mac", "Zebra"])
        #expect(choices.map(\.machineID) == ["mac-id", "zebra"])
    }

    @Test func aPhoneCallsTheMacHostThisMacAndSortsTheRestByName() {
        let hosts = [
            host("box", "zebra", machine: "z"),
            host("other", "Alpha", machine: "a"),
            host("mac", "Office", machine: "mac-id"),
        ]
        let choices = WorkflowHosts.choices(from: hosts, thisMachine: nil)
        #expect(choices.map(\.name) == ["This Mac", "Alpha", "zebra"])
        #expect(choices.map(\.machineID) == ["mac-id", "a", "z"])
    }

    @Test func cleanedDropsBlanksAndRepeatedIdsAndKeepsOrder() {
        #expect(WorkflowHosts.cleaned([" this ", "", "other", "this", "  other  "]) == ["this", "other"])
        #expect(WorkflowHosts.cleaned([]) == [])
    }
}
