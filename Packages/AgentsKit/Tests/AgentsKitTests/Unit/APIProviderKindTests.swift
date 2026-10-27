@testable import AgentsKitCore
import Foundation
import Testing

/// The API providers a phone adds (#1819), built as the web page builds them
/// (`Web/test/machineProviders.test.mjs`): the same presets, defaults and secret names.
@Suite("API provider kinds")
struct APIProviderKindTests {
    private func request(_ kind: APIProviderKind, _ name: String, _ values: [String: String],
                         editing: DaemonAPI.ProviderSummary? = nil) -> DaemonAPI.ProviderAdd? {
        try? kind.request(name: name, values: values, editing: editing).get()
    }

    @Test func theKindsAndTheirPresetsAreTheWebPagesOnes() {
        #expect(APIProviderKind.allCases.map(\.rawValue) == ["digitalOcean", "codespaces", "coder", "aws", "compute"])
        #expect(APIProviderKind.ofPreset("digitalocean-api") == .digitalOcean)
        #expect(APIProviderKind.ofPreset("doctl") == nil)
    }

    @Test func aDropletProviderGoesWithItsDefaultsAndTheTokenOnlyAsASecret() {
        let r = request(.digitalOcean, "", ["token": " dop_v1_x "])
        #expect(r?.name == "DigitalOcean Droplets")
        #expect(r?.commands == .object(["preset": .string("digitalocean-api"), "tag": .string("agents"), "user": .string("root")]))
        #expect(r?.secrets == ["DIGITALOCEAN_API_TOKEN": "dop_v1_x"])
    }

    @Test func whatIsMissingIsSaid() {
        func missing(_ kind: APIProviderKind, _ values: [String: String]) -> String? {
            if case .failure(let m) = kind.request(name: "N", values: values) { return m.sentence }
            return nil
        }
        #expect(missing(.digitalOcean, [:]) == "Give the API token.")
        #expect(missing(.coder, ["token": "t"]) == "Give the deployment’s address.")
        #expect(missing(.aws, ["accessKey": "k", "secretKey": "s"]) == "Give the region.")
        #expect(missing(.compute, ["serviceKey": "{}"]) == "Give the project and the zone.")
    }

    @Test func awsAndComputeBuildTheirPresetsAndKeepAKeyAsItIs() {
        let aws = request(.aws, "A", ["accessKey": "AK", "secretKey": " s ", "region": "eu-west-1"])
        #expect(aws?.commands == .object(["preset": .string("aws-ec2-api"), "region": .string("eu-west-1"),
                                          "tag": .string("agents"), "user": .string("ec2-user")]))
        #expect(aws?.secrets == ["AWS_ACCESS_KEY_ID": "AK", "AWS_SECRET_ACCESS_KEY": " s "])
        let compute = request(.compute, "G", ["serviceKey": "{}", "project": "p", "zone": "z", "sshKey": "ssh-ed25519 K"])
        #expect(compute?.commands == .object(["preset": .string("gcp-compute-api"), "project": .string("p"), "zone": .string("z"),
                                              "label": .string("agents"), "user": .string("agents"),
                                              "sshKeys": .array([.string("ssh-ed25519 K")])]))
    }

    @Test func anEditSendsTheNameAndOnlyTheSecretsGiven() {
        let editing = DaemonAPI.ProviderSummary(id: ProviderID(rawValue: "do"), name: "DO", kind: "commands")
        let r = request(.digitalOcean, "Droplets", [:], editing: editing)
        #expect(r?.id == ProviderID(rawValue: "do"))
        #expect(r?.commands == nil)
        #expect(r?.secrets == [:])
    }

    @Test func aWorkspaceNoHostCanBeLinkedToSaysWhereToMakeItOne() {
        func host(_ id: String, relay: Bool? = nil) -> DaemonAPI.ControlMachine {
            DaemonAPI.ControlMachine(id: MachineRef(rawValue: id), name: id, platform: "linux", version: "1",
                                  state: "online", reach: "local", machineID: id, relay: relay)
        }
        let workspace = DaemonAPI.MachineInfo(id: "w", name: "dev", state: "stopped")
        #expect(MachineProviderWords.noHostLine(workspace, hosts: [host("relay", relay: true)]) == MachineProviderWords.notAHostYet)
        #expect(MachineProviderWords.noHostLine(workspace, hosts: [host("free")]) == nil)
        var linked = workspace
        linked.host = MachineRef(rawValue: "free")
        #expect(MachineProviderWords.noHostLine(linked, hosts: []) == nil)
    }
}
