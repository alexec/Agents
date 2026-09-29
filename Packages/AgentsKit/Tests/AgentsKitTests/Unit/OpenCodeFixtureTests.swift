import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// OpenCode 1.18.33's own replies, recorded on a scratch home (049 T003, `Fixtures/opencode/`),
/// read by the code that reads them in a real run.
@Suite("OpenCode's recorded replies")
struct OpenCodeFixtureTests {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/opencode")

    static func message(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: name)))
    }

    static func error(_ name: String) throws -> JSONRPCError {
        let error = try #require(try message(name)["error"])
        return try JSONDecoder().decode(JSONRPCError.self, from: JSONEncoder().encode(error))
    }

    @Test func itsHandshakeResumesTakesPicturesAndNamesItsSignInCommandForTheAppsCopy() throws {
        let result = try #require(try Self.message("initialize.json")["result"])
        let initialize = try JSONDecoder().decode(ACP.InitializeResult.self, from: JSONEncoder().encode(result))
        #expect(initialize.speaksOurVersion)
        #expect(initialize.supportsResume && initialize.supportsLoad)
        #expect(initialize.agentCapabilities?.promptCapabilities?.image == true)
        let method = try #require(initialize.authMethods?.first { $0.id == "opencode-login" })
        let named = method.naming(program: URL(filePath: "/Users/x/Application Support/Agents/tools/opencode/current/bin/opencode"))
        #expect(named.terminalCommand?.hasPrefix("'/Users/x/Application Support/Agents/tools/opencode/current/bin/opencode'") == true)
    }

    @Test func aModelOfAProviderNobodySignedInToNamesTheProvider() throws {
        #expect(DaemonCore.unsignedProvider(try Self.error("set-model-unknown-provider.json")) == "anthropic")
    }

    @Test func aRefusedKeyReadsAsASignInFailure() throws {
        let error = try Self.error("prompt-invalid-key.json")
        #expect(DaemonCore.isAuthenticationFailure(error))
        #expect(DaemonCore.unsignedProvider(error) == nil, "a refused key, not a missing sign-in")
    }

    @Test func aFreeModelsZeroCostIsNoCost() throws {
        let update = try #require(try Self.message("usage-zero-cost.json")["params"]?["update"])
        guard case .usage(let usage) = SessionUpdate.decode(update) else { Issue.record("not usage"); return }
        #expect((usage.used ?? 0) > 0)
        #expect(usage.cost == nil)
    }
}
