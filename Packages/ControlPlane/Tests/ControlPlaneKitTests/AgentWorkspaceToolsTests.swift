import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

// Agents use workspaces (#691 US6): what an agent's host asks on channel 0 for it, answered
// as a client's request, naming hosts and providers as the agent saw them, and never a secret.

@Suite("Agents' workspace tools on the control plane (#691 US6)")
struct AgentWorkspaceToolsTests {
    func agentCall(_ h: ProviderHarness, _ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await h.methods.hostSaid(h.other, method: DaemonAPI.Method.hostWorkspaces,
                                     params: try JSONValue.encoding(DaemonAPI.HostWorkspaceCall(agent: "Claude (fix-login)",
                                                                                                 method: method, params: params)))
    }

    @Test func anAgentSeesWorkspacesAndTheirHostsAndNoSecret() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let answer = try await agentCall(h, DaemonAPI.Method.workspacesForAgent)
        let listed = try answer.decode(DaemonAPI.AgentWorkspaces.self)
        let provider = try #require(listed.providers.first)
        #expect(provider.name == "DigitalOcean")
        #expect(provider.workspaces.first { $0.id == "agents-devbox" }?.host == "devbox")
        let text = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("DIGITALOCEAN_TOKEN"))
    }

    @Test func anAgentStartsAHostByItsName() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let row = try await agentCall(h, DaemonAPI.Method.hostsStart, ["host": "devbox"]).decode(DaemonAPI.ControlHost.self)
        #expect(row.id == h.devbox)
        #expect(row.state == "starting")
        await #expect(throws: JSONRPCError.self) { _ = try await agentCall(h, DaemonAPI.Method.hostsStart, ["host": "nowhere"]) }
    }

    @Test func anAgentMakesAtAProviderByItsName() async throws {
        let h = try await ProviderHarness()
        try await h.add()
        let made = try await agentCall(h, DaemonAPI.Method.providersCreate, ["id": "DigitalOcean", "name": "branch-build"])
            .decode(DaemonAPI.ProviderCreated.self)
        #expect(made.workspace.name == "branch-build")
    }

    @Test func anAgentCantAskAnythingElse() async throws {
        let h = try await ProviderHarness()
        try await h.add()
        for method in [DaemonAPI.Method.providersAdd, DaemonAPI.Method.providersRemove, DaemonAPI.Method.hostsRemove,
                       DaemonAPI.Method.providersList] {
            await #expect(throws: JSONRPCError.self) { _ = try await agentCall(h, method) }
        }
    }
}
