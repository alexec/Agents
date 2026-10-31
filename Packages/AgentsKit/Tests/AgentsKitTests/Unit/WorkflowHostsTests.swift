import Foundation
import Testing
@testable import AgentsKitCore

/// The computers a workflow page offers, under the names already on screen (#317).
@Suite("Choosing a workflow's hosts")
struct WorkflowHostsTests {
    private func host(_ id: String, _ name: String, machine: String?, relay: Bool? = nil) -> DaemonAPI.ControlMachine {
        DaemonAPI.ControlMachine(id: MachineRef(rawValue: id), name: name, platform: "macOS", version: "1",
                              state: "online", reach: "local", machineID: machine, relay: relay)
    }

    @Test func thisMacLeadsAndARelayOrAHostWithoutAnIdIsLeftOut() {
        let hosts = [
            host("box", "Zebra", machine: "zebra"),
            host("relay", "Relay", machine: "relay-id", relay: true),
            host("off", "Relay switched off", machine: "off-id", relay: false),
            host("mac", "Alex’s Mac", machine: "mac-id"),
            host("gone", "No id", machine: nil),
            host("blank", "Blank", machine: "  "),
            host("again", "Also this Mac", machine: "mac-id"),
        ]
        let choices = WorkflowHosts.choices(from: hosts, thisMachine: "mac-id")
        #expect(choices.map(\.name) == ["This Mac", "Zebra"])
        #expect(choices.map(\.machineID) == ["mac-id", "zebra"])
    }

    /// A relay switched off is still a relay (#1507): on this Mac's machine, it is not
    /// this Mac's host, and nothing reaches it for agents.
    @Test func aRelaySwitchedOffRunsNoAgents() {
        #expect(host("mac", "Mac", machine: "mac-id").runsAgents)
        #expect(!host("relay", "Relay", machine: "mac-id", relay: true).runsAgents)
        #expect(!host("relay", "Relay", machine: "mac-id", relay: false).runsAgents)
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

    /// Two machines under Runs on run it on each of them, as the host does, and a label that
    /// is no machine is shown apart, as Also needs (#2064).
    @Test func twoMachinesEachRunItAndOtherLabelsAreAlsoNeeded() {
        let mac = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", box = "1234567890abcdef1234567890abcdef"
        let parts = Workflow.runsOnParts([box, "review-bot", "mac-id", "linux"], known: ["mac-id"])
        #expect(parts.machines == [box, "mac-id"])
        #expect(parts.needs == ["review-bot", "linux"])
        #expect(Workflow.isMachineID(mac) && Workflow.isMachineID(box) && !Workflow.isMachineID("review-bot"))
        let both = Workflow(workflowID: "w", folder: URL(fileURLWithPath: "/p"), runsOn: [box, mac, "review-bot"])
        #expect(both.runs(on: mac.lowercased()) && both.runs(on: box))
        #expect(!both.runs(on: "fedcba9876543210fedcba9876543210") && !both.runs(on: nil))
    }
}
