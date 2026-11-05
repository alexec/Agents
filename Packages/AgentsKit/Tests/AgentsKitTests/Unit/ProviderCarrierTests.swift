@testable import AgentsKitCore
import Foundation
import Testing

/// The machine that carries a provider (#3496), as the web page's `machineProviders.ts` says it.
@Suite("Provider carrier")
struct ProviderCarrierTests {
    private func host(_ id: String, _ name: String, state: String = "online", owner: String? = "alex",
                      capabilities: [String]? = [Capability.providersCarry1]) -> DaemonAPI.ControlMachine {
        var h = DaemonAPI.ControlMachine(id: MachineRef(rawValue: id), name: name, platform: "macOS", version: "0.17",
                                         state: state, reach: "direct", machineID: nil)
        h.owner = owner
        h.capabilities = capabilities
        return h
    }

    @Test func choicesAreThePersonsOnlineMachinesThatCanTheirOwnFirst() {
        let hosts = [host("b", "box"), host("m", "mac"), host("a", "attic"), host("o", "off", state: "offline"),
                     host("s", "sam's", owner: "sam"), host("x", "old", capabilities: [])]
        #expect(ProviderCarrier.choices(hosts, person: "alex", own: MachineRef(rawValue: "m")).map(\.name)
            == ["mac", "attic", "box"])
        #expect(ProviderCarrier.choices(hosts, person: "alex", own: nil).map(\.name) == ["attic", "box", "mac"])
    }

    @Test func editStartsAtTheOneItHasAndMovingAsksForSecrets() {
        let hosts = [host("a", "attic"), host("b", "box")]
        let provider = DaemonAPI.ProviderSummary(id: ProviderID(rawValue: "do"), name: "DO", kind: "commands",
                                                 preset: "digitalocean-api", machine: MachineRef(rawValue: "b"),
                                                 machineName: "box")
        #expect(ProviderCarrier.start(provider, choices: hosts) == MachineRef(rawValue: "b"))
        #expect(ProviderCarrier.start(nil, choices: hosts) == MachineRef(rawValue: "a"))
        #expect(!ProviderCarrier.moves(provider, to: MachineRef(rawValue: "b")))
        #expect(ProviderCarrier.moves(provider, to: MachineRef(rawValue: "a")))
    }

    @Test func theCardSaysWhichMachineAndWhenItIsOffline() {
        var provider = DaemonAPI.ProviderSummary(id: ProviderID(rawValue: "do"), name: "DO", kind: "commands",
                                                 machine: MachineRef(rawValue: "b"), machineName: "box")
        #expect(ProviderCarrier.carriedBy(provider) == "Carried by box")
        #expect(ProviderCarrier.offline(provider) == nil)
        provider.machineOffline = true
        #expect(ProviderCarrier.offline(provider) == "box is offline: its machines can’t be started or stopped until it is back.")
        provider.machine = nil
        #expect(ProviderCarrier.carriedBy(provider) == nil)
        #expect(ProviderCarrier.secretsFoot("box") == "Tokens and keys go to box, which keeps them. The control plane keeps none.")
    }
}
