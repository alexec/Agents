#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKitCore

/// #3542: a host that holds its person's lock takes a provider draft's writer only as the
/// sheet's client signed its start. The client signs the control plane's start as it is, and
/// only when it starts that draft's writer and nothing more.
@Suite("Provider draft sign")
struct ProviderDraftSignTests {
    let draft = UUID()

    /// The start as the control plane writes it (drafts.go, Start).
    func start(purpose: UUID? = nil, mcpServers: String = "[]", sandbox: String = "on") -> String {
        let id = (purpose ?? draft).uuidString
        return #"{"runtimeID":"claude","cwd":"file:///","prompt":"Write the map.","attachments":[],"#
            + #""startOptions":{"values":{},"extraArguments":[]},"additionalDirectories":[],"mcpServers":\#(mcpServers),"#
            + #""labels":[],"requestID":"\#(UUID().uuidString)","sandbox":"\#(sandbox)","purpose":{"providerDraft":{"id":"\#(id)"}}}"#
    }

    @Test func signsTheWritersStartAsItIs() throws {
        let key = LockSigningKey.ephemeral()
        let params = start()
        let sign = DaemonAPI.ProviderDraftSign(machine: MachineRef(rawValue: "thismac1"), method: DaemonAPI.Method.agentsStart, params: params)
        let lock = try sign.signed(for: draft, runtimeID: "claude", by: key)
        #expect(lock.to == "thismac1")
        #expect(LockChannel.verify(key.publicKey, LockChannel.requestData(to: "thismac1", at: lock.at, method: sign.method, params: params), lock.sig))
    }

    @Test func refusesAnythingMoreThanTheWriter() {
        let key = LockSigningKey.ephemeral()
        let machine = MachineRef(rawValue: "thismac1")
        let starts: [String: DaemonAPI.ProviderDraftSign] = [
            "another draft": .init(machine: machine, method: DaemonAPI.Method.agentsStart, params: start(purpose: UUID())),
            "an MCP server": .init(machine: machine, method: DaemonAPI.Method.agentsStart,
                                   params: start(mcpServers: #"[{"name":"x","command":"sh","args":[],"env":[]}]"#)),
            "no sandbox": .init(machine: machine, method: DaemonAPI.Method.agentsStart, params: start(sandbox: "off")),
            "a prompt": .init(machine: machine, method: DaemonAPI.Method.agentsPrompt, params: start()),
        ]
        for (name, sign) in starts {
            #expect(throws: DaemonAPI.ProviderDraftSign.NotAWritersStart.self, "\(name)") {
                try sign.signed(for: draft, runtimeID: "claude", by: key)
            }
        }
        #expect(throws: DaemonAPI.ProviderDraftSign.NotAWritersStart.self) {
            try DaemonAPI.ProviderDraftSign(machine: machine, method: DaemonAPI.Method.agentsStart, params: start())
                .signed(for: draft, runtimeID: "codex", by: key)
        }
    }
}
#endif
