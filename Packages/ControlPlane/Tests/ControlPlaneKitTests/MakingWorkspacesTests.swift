import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

// Make a new workspace, and delete one (#691 US5): the form's choices, a first-boot install
// that joins and is linked, the ssh path when the provider can't run it, and Delete Workspace
// taking the host with it.

extension ProviderHarness {
    func create(_ name: String, options: JSONValue = ["size": "big"]) async throws -> DaemonAPI.ProviderCreated {
        let provider = try #require(try await call(DaemonAPI.Method.providersList)["providers"]?.decode([DaemonAPI.ProviderSummary].self).first?.id)
        return try await call(DaemonAPI.Method.providersCreate,
                              try JSONValue.encoding(DaemonAPI.ProviderCreate(id: provider, name: name, options: options)))
            .decode(DaemonAPI.ProviderCreated.self)
    }
}

@Suite("Making workspaces (#691 US5)")
struct MakingWorkspacesTests {
    @Test func theFormComesFromTheProvidersOptions() async throws {
        let h = try await ProviderHarness()
        let id = try await h.add()
        let options = try await h.call(DaemonAPI.Method.providersOptions, try JSONValue.encoding(DaemonAPI.ProviderRequest(id: id)))
            .decode(DaemonAPI.ProviderOptions.self)
        #expect(options.schema["properties"]?["size"]?["title"] == "Size")
    }

    @Test func aWorkspaceThatInstallsOnFirstBootJoinsAndIsLinked() async throws {
        let h = try await ProviderHarness()
        try await h.add()
        let made = try await h.create("build-2")
        #expect(made.joining)
        #expect(made.workspace.id == "ws-build-2")
        // The install line, for the host's own name: a code, never logged.
        let firstBoot = try #require(await h.provider.firstBoots.first)
        #expect(firstBoot.hasSuffix("sh -s -- 'agents-control:2:h:secret' 'build-2'"))

        // It joins, as its first boot's install.sh does.
        let joined = HostID(rawValue: "build002")
        try await h.methods.enroll(HostRecord(id: joined, name: "build-2"))
        await h.router.know(joined)
        for _ in 0..<300 {
            if try await h.row(joined).workspace?.workspace == "ws-build-2" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await h.row(joined).workspace?.workspace == "ws-build-2")
    }

    @Test func oneThatCantRunTheFirstBootIsLeftToAddOverSSH() async throws {
        let h = try await ProviderHarness()
        try await h.add()
        await h.provider.set(firstBootRuns: false)
        let made = try await h.create("build-3")
        #expect(!made.joining)
        #expect(made.workspace.ssh == "root@10.0.0.9")
    }

    @Test func aNameAHostHasOrNoHostCouldHaveMakesNothing() async throws {
        let h = try await ProviderHarness()
        try await h.add()
        await #expect(throws: JSONRPCError.self) { try await h.create("devbox") }
        await #expect(throws: JSONRPCError.self) { try await h.create("two words") }
        #expect(await h.provider.firstBoots.isEmpty)
    }

    @Test func deleteWorkspaceTakesTheWorkspaceAndTheHost() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        _ = try await h.call(DaemonAPI.Method.hostsDeleteWorkspace, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        #expect(await h.provider.deleted == ["agents-devbox"])
        let rows = try await h.call(DaemonAPI.Method.hostsList).decode([DaemonAPI.ControlHost].self)
        #expect(!rows.contains { $0.id == h.devbox })
    }

    @Test func anUnlinkedHostHasNoWorkspaceToDelete() async throws {
        let h = try await ProviderHarness()
        try await h.add()
        await #expect(throws: JSONRPCError.self) {
            _ = try await h.call(DaemonAPI.Method.hostsDeleteWorkspace, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        }
        #expect(await h.provider.deleted.isEmpty)
    }

    @Test func aMapsArgumentsTakeTheNameAndTheChoices() throws {
        let map = try ToolMapping.map([
            "list": ["tool": "list_droplets", "items": "droplets", "id": "id", "name": "name", "state": "status"],
            "start": ["tool": "power_on", "arguments": ["droplet": "{id}"]],
            "stop": ["tool": "power_off", "arguments": ["droplet": "{id}"]],
            "create": ["tool": "create_droplet", "arguments": ["name": "{name}", "size": "{size}", "user_data": "{firstBoot}",
                                                              "tags": ["agents"]]],
            "delete": ["tool": "delete_droplet", "arguments": ["droplet": "{id}"]],
        ])
        #expect(map.capabilities == ["create", "delete"])
        let args = map.arguments(map.create!, values: ["name": "b-2", "size": "big", "options": ["size": "big"]])
        // No first boot given: left out, not sent empty.
        #expect(args == ["name": "b-2", "size": "big", "tags": ["agents"]])
        #expect(map.missing(from: ["list_droplets", "power_on", "power_off", "create_droplet"]) == "delete_droplet")
    }
}
